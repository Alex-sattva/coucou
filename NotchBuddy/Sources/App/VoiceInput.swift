import AVFoundation
import Foundation
import Speech

/// On-device speech to text for the assistant bar. The microphone is open only between `start()`
/// and the end of `finish()` / `cancel()`; every exit path goes through `stopCapture()` /
/// `teardown()`, so an idle app has no engine, no tap and no recognition task.
/// Recognition is forced on-device: no audio ever leaves the Mac.
@MainActor
final class VoiceInput: ObservableObject {
    static let shared = VoiceInput()

    static let deniedCopy = "Microphone or speech access is off — turn it on in System Settings → Privacy."
    static let unavailableCopy = "Voice isn't available on this Mac for your language."

    enum Phase: Equatable {
        case idle
        /// Asking for access (first use only) and opening the microphone.
        case starting
        case listening
        /// Microphone closed, waiting a moment for the recogniser's last words.
        case finishing
    }

    @Published private(set) var phase: Phase = .idle
    /// Live text: partial results while listening, the final text after `finish()`.
    @Published private(set) var transcript = ""
    @Published private(set) var error: String?

    var isListening: Bool { phase == .listening }
    var isActive: Bool { phase != .idle }

    /// How long `finish()` waits for the recogniser's final result before using what it has.
    private static let finalWait: Duration = .milliseconds(1200)

    private var generation = 0
    private var startTask: Task<Void, Never>?
    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var configObserver: NSObjectProtocol?
    private var finalWaiter: CheckedContinuation<Void, Never>?

    private init() {}

    // MARK: - Start

    /// Opens the microphone. Asks for permission only the first time. A denied permission or an
    /// unavailable on-device recogniser sets `error` once and stops: nothing retries.
    func start() {
        guard phase == .idle else { return }
        generation += 1
        let gen = generation
        error = nil
        transcript = ""
        phase = .starting
        startTask = Task { [weak self] in
            let allowed = await Self.requestAccessIfNeeded()
            guard let self, !Task.isCancelled, self.generation == gen else { return }
            self.startTask = nil
            guard allowed else { self.fail(Self.deniedCopy); return }
            self.beginCapture(generation: gen)
        }
    }

    private func beginCapture(generation gen: Int) {
        guard let recognizer = SFSpeechRecognizer(locale: .current),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            fail(Self.unavailableCopy); return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            // No input device (or no access the system did not report): same notice, no retry.
            fail(Self.deniedCopy); return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format,
                         block: Self.makeTap(RequestBox(request)))
        self.engine = engine
        self.request = request
        self.recognizer = recognizer
        engine.prepare()
        do {
            try engine.start()
        } catch {
            fail(Self.unavailableCopy); return
        }
        task = recognizer.recognitionTask(with: request, resultHandler: Self.makeHandler(owner: self, generation: gen))
        // A device change stops the engine under us: close everything instead of hanging.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { _ in
            Task { @MainActor in
                let voice = VoiceInput.shared
                if voice.generation == gen, voice.phase == .listening { voice.endQuietly() }
            }
        }
        phase = .listening
    }

    // MARK: - Stop

    /// Release: closes the microphone, waits briefly for the last words and returns the text
    /// (trimmed, possibly empty). The caller decides whether to send it.
    func finish() async -> String {
        guard phase != .idle else { return "" }
        if phase == .starting { cancel(); return "" }
        guard phase == .listening else { return "" }
        let gen = generation
        phase = .finishing
        stopCapture()
        // The request is ended: the recogniser now flushes its final result.
        if task != nil {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                finalWaiter = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: Self.finalWait)
                    self?.resumeFinalWaiter()
                }
            }
        }
        guard generation == gen else { return "" }   // cancelled while waiting
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        teardown()
        phase = .idle
        return text
    }

    /// Esc, panel closed, mic button off without sending: stop everything and drop the text.
    func cancel() {
        guard phase != .idle else { return }
        generation += 1
        startTask?.cancel()
        startTask = nil
        teardown()
        transcript = ""
        phase = .idle
        resumeFinalWaiter()
    }

    /// The recogniser or the audio device ended the session on its own: keep the text, close audio.
    private func endQuietly() {
        generation += 1
        teardown()
        phase = .idle
        resumeFinalWaiter()
    }

    private func fail(_ message: String) {
        generation += 1
        startTask = nil
        teardown()
        phase = .idle
        error = message
        resumeFinalWaiter()
    }

    // MARK: - Teardown (every exit path ends here)

    /// Microphone off: engine stopped, tap removed, request told the audio is over.
    private func stopCapture() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let engine {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        request?.endAudio()
    }

    /// Everything off: capture, recognition task, request, recogniser.
    private func teardown() {
        stopCapture()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
    }

    private func resumeFinalWaiter() {
        guard let waiter = finalWaiter else { return }
        finalWaiter = nil
        waiter.resume()
    }

    // MARK: - Recognition results (main actor)

    private func received(text: String?, isFinal: Bool, failed: Bool, generation gen: Int) {
        guard gen == generation else { return }
        if let text { transcript = text }
        guard isFinal || failed else { return }
        switch phase {
        case .finishing: resumeFinalWaiter()
        case .listening: endQuietly()      // the recogniser stopped by itself (e.g. long silence)
        default: break
        }
    }

    // MARK: - Nonisolated helpers
    //
    // The audio tap runs on a real-time audio thread and the recogniser calls back on its own queue.
    // Closures written inside a @MainActor method would be main-actor isolated and trap there, so
    // they are built here, outside the actor, and only hand plain values back to it.

    private final class RequestBox: @unchecked Sendable {
        let request: SFSpeechAudioBufferRecognitionRequest
        init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    }

    private nonisolated static func makeTap(_ box: RequestBox) -> AVAudioNodeTapBlock {
        { buffer, _ in box.request.append(buffer) }
    }

    private nonisolated static func makeHandler(owner: VoiceInput, generation: Int)
        -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                owner.received(text: text, isFinal: isFinal, failed: failed, generation: generation)
            }
        }
    }

    /// Speech first, then microphone. Each is requested only while the system has not been asked yet.
    nonisolated static func requestAccessIfNeeded() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: break
        case .notDetermined:
            let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
            }
            guard status == .authorized else { return false }
        default: return false
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
