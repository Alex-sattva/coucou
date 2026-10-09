import AVFoundation

/// Mochi's spoken answers after a spoken request ("Hey Mochi", the mic button, ⌥). Uses the Mac's
/// own speech voice: on-device, nothing leaves the Mac. Only one line at a time; a new line or the
/// microphone opening again cuts the old one off.
@MainActor
final class MochiSpeech {
    static let shared = MochiSpeech()

    private let synth = AVSpeechSynthesizer()

    private init() {}

    func say(_ text: String) {
        guard AppState.shared.spokenRepliesEnabled else { return }
        // Never talk into an open microphone: the line would end up in the user's words.
        guard !VoiceInput.shared.isActive else { return }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        stop()
        let utterance = AVSpeechUtterance(string: line)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")   // the bar's copy is English
        synth.speak(utterance)
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }
}
