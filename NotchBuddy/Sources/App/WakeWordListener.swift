import AppKit
import AVFoundation
import Combine
import Foundation
import Speech

/// Listens for "Hey Mochi" while Settings → "Listen for Hey Mochi" is on. Recognition is forced
/// on-device: no audio leaves the Mac. This is the one place Coucou keeps the microphone open
/// with nothing on screen, so it runs only while the switch is on, and pauses while the ⌥ voice
/// input has the microphone and while the Mac sleeps.
/// On a match it closes its own microphone first, then hands over to `AssistantModel`'s
/// hands-free voice (the same `VoiceInput` as ⌥), which sends the words after a pause.
@MainActor
final class WakeWordListener {
    static let shared = WakeWordListener()

    /// On-device recognition tasks are restarted on this cycle so one never grows without end.
    private static let cycle: Duration = .seconds(50)
    /// Wait after a failure or after the voice input lets go before reopening the microphone.
    private static let reopenDelay: Duration = .milliseconds(800)

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var cycleTask: Task<Void, Never>?
    private var reopenTask: Task<Void, Never>?
    private var configObserver: NSObjectProtocol?
    private var generation = 0
    private var asleep = false
    // Diagnostics for the current recognition task (counts only, never the words).
    private var resultsThisTask = 0
    private var mostWordsThisTask = 0
    private var loggedNameWords: Set<String> = []
    private var subscriptions: Set<AnyCancellable> = []

    private init() {}

    /// Called once at launch. Follows the setting and the voice input from then on.
    func start() {
        guard subscriptions.isEmpty else { return }
        AppState.shared.$wakeWordEnabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reconcile() } }
            .store(in: &subscriptions)
        VoiceInput.shared.$phase
            .map { $0 == .idle }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reconcile() } }
            .store(in: &subscriptions)
        let ws = NSWorkspace.shared.notificationCenter
        ws.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.asleep = true; self?.reconcile() } }
            .store(in: &subscriptions)
        ws.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.asleep = false; self?.reconcile() } }
            .store(in: &subscriptions)
        reconcile()
    }

    private var shouldListen: Bool {
        AppState.shared.wakeWordEnabled && !asleep && !VoiceInput.shared.isActive
    }

    /// Microphone open exactly when `shouldListen`; reopening waits a moment so the voice input's
    /// engine is fully gone first.
    private func reconcile() {
        reopenTask?.cancel()
        reopenTask = nil
        guard shouldListen else { stop(); return }
        guard engine == nil else { return }
        reopenTask = Task { [weak self] in
            try? await Task.sleep(for: Self.reopenDelay)
            guard !Task.isCancelled, let self, self.shouldListen, self.engine == nil else { return }
            await self.open()
        }
    }

    private func open() async {
        guard await VoiceInput.requestAccessIfNeeded() else {
            appendAppLog("nb.log", "wake word: microphone or speech access is off")
            return
        }
        guard shouldListen, engine == nil else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            appendAppLog("nb.log", "wake word: on-device English recognition unavailable")
            return
        }
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        let request = Self.makeRequest()
        let box = RequestBox(request)
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.makeTap(box))
        engine.prepare()
        do { try engine.start() } catch {
            engine.inputNode.removeTap(onBus: 0)
            appendAppLog("nb.log", "wake word: could not start the microphone: \(error.localizedDescription)")
            return
        }
        self.engine = engine
        self.recognizer = recognizer
        self.box = box
        appendAppLog("nb.log", "wake word: listening (\(Int(format.sampleRate)) Hz, \(format.channelCount) ch)")
        beginTask(request: request)
        let engineId = ObjectIdentifier(engine)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { _ in
            // A device change stops the engine: close and reopen on the new device.
            Task { @MainActor in
                let me = WakeWordListener.shared
                guard me.engine.map(ObjectIdentifier.init) == engineId else { return }
                me.stop()
                me.reconcile()
            }
        }
    }

    /// The tap writes into whichever request the box holds, so a new recognition task can start
    /// without touching the audio engine.
    private var box: RequestBox?

    /// Each recognition task gets its own `generation`: callbacks from a task that was replaced or
    /// cancelled (which report an error) are ignored instead of restarting again.
    private func beginTask(request: SFSpeechAudioBufferRecognitionRequest) {
        guard let recognizer else { return }
        generation += 1
        let gen = generation
        resultsThisTask = 0
        mostWordsThisTask = 0
        loggedNameWords = []
        self.request = request
        box?.request = request
        task = recognizer.recognitionTask(with: request, resultHandler: Self.makeHandler(generation: gen))
        cycleTask?.cancel()
        cycleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.cycle)
            guard !Task.isCancelled else { return }
            self?.restartTask(generation: gen)
        }
    }

    /// A fresh recognition task on the same open microphone (cycle end, or the recogniser ended).
    private func restartTask(generation gen: Int) {
        guard gen == generation, engine != nil else { return }
        logCycle("task end")
        task?.cancel()
        request?.endAudio()
        beginTask(request: Self.makeRequest())
    }

    private func received(text: String?, ended: Bool, error: String?, generation gen: Int) {
        guard gen == generation else { return }
        if let text {
            resultsThisTask += 1
            mostWordsThisTask = max(mostWordsThisTask, text.split(whereSeparator: \.isWhitespace).count)
        }
        if let error { appendAppLog("nb.log", "wake word: recogniser error \(error)") }
        // Temporary diagnostics: only the one word after a greeting, never the rest.
        if let text {
            for word in WakePhrase.wordsAfterGreeting(text) where !loggedNameWords.contains(word) {
                loggedNameWords.insert(word)
                appendAppLog("nb.log", "wake word: greeting followed by \u{201C}\(word)\u{201D}")
            }
        }
        if let text, WakePhrase.matches(text) {
            appendAppLog("nb.log", "wake word: matched")
            stop()
            SoundEngine.shared.play("peek")
            AssistantModel.shared.startHandsFreeVoice()
            // No folder to work in: the voice input never started (the bar shows why), so its
            // phase never changes and nothing else would reopen the microphone.
            if !VoiceInput.shared.isActive { reconcile() }
            return
        }
        // The recogniser ended on its own (final result or error): start a new task after a short
        // wait, so a recogniser that fails at once can never spin.
        if ended {
            cycleTask?.cancel()
            cycleTask = Task { [weak self] in
                try? await Task.sleep(for: Self.reopenDelay)
                guard !Task.isCancelled else { return }
                self?.restartTask(generation: gen)
            }
        }
    }

    /// One line per recognition task: how loud the input got and how much the recogniser heard.
    /// A peak near 0 means the microphone delivers silence (permission, wrong input device).
    private func logCycle(_ reason: String) {
        let peak = box?.takePeak() ?? 0
        appendAppLog("nb.log", "wake word: \(reason), peak level \(String(format: "%.3f", peak)), "
                     + "\(resultsThisTask) results, at most \(mostWordsThisTask) words")
    }

    /// Microphone off, task and request gone. Safe to call twice.
    private func stop() {
        generation += 1
        cycleTask?.cancel()
        cycleTask = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let engine {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        box = nil
    }

    // MARK: - Nonisolated helpers (audio thread and recogniser queue)

    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _request: SFSpeechAudioBufferRecognitionRequest
        private var peak: Float = 0
        init(_ request: SFSpeechAudioBufferRecognitionRequest) { _request = request }

        /// Loudest sample of the first channel since the last `takePeak` (audio thread).
        func note(_ buffer: AVAudioPCMBuffer) {
            guard let samples = buffer.floatChannelData?[0] else { return }
            var m: Float = 0
            for i in 0..<Int(buffer.frameLength) { m = max(m, abs(samples[i])) }
            lock.lock(); peak = max(peak, m); lock.unlock()
        }

        func takePeak() -> Float {
            lock.lock(); defer { peak = 0; lock.unlock() }
            return peak
        }
        var request: SFSpeechAudioBufferRecognitionRequest {
            get { lock.lock(); defer { lock.unlock() }; return _request }
            set { lock.lock(); _request = newValue; lock.unlock() }
        }
    }

    private nonisolated static func makeRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.contextualStrings = ["Hey Mochi", "Mochi"]
        return request
    }

    private nonisolated static func makeTap(_ box: RequestBox) -> AVAudioNodeTapBlock {
        { buffer, _ in
            box.note(buffer)
            box.request.append(buffer)
        }
    }

    private nonisolated static func makeHandler(generation: Int)
        -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let ended = (result?.isFinal ?? false) || error != nil
            let errorText = error.map { e -> String in
                let ns = e as NSError
                return "\(ns.domain) \(ns.code)"
            }
            Task { @MainActor in
                WakeWordListener.shared.received(text: text, ended: ended, error: errorText,
                                                 generation: generation)
            }
        }
    }
}
