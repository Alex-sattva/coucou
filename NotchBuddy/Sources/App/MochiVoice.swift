import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Turns an agent's final report into one short line in Mochi's voice, with Apple's on-device
/// model (macOS 26, Apple Intelligence on). Free, offline, nothing leaves the Mac. Returns nil
/// when the model is unavailable or refuses; callers fall back to `AssistantReply.firstSentence`.
enum MochiVoice {
    /// The on-device context is about 4k tokens; the start of a report says what happened.
    static let maxInputChars = 6000

    static let instructions = """
        You are Mochi, a small friendly companion who lives in the MacBook notch and watches the \
        user's coding agents. You get the final message an agent wrote. Tell the user, like a \
        friend speaking out loud, what happened in ONE short sentence of at most 16 words. \
        If the agent needs something from the user or asks a question, say that. \
        Plain everyday words. No markdown, no code, no file paths, no lists, no quotes.
        """

    static func line(for reply: String, agent: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            let session = LanguageModelSession(instructions: instructions)
            let prompt = "\(agent) finished. Its message:\n\n\(String(reply.prefix(maxInputChars)))"
            guard let response = try? await session.respond(to: prompt) else { return nil }
            let text = response.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
            guard !text.isEmpty else { return nil }
            return text   // never cut; the card wraps it
        }
        #endif
        return nil
    }
}
