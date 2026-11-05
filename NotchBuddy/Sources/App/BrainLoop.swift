import Foundation

#if !APPSTORE

// Foundation only (compiled by scripts/test-model-client.sh with a scripted fake model).
// The brain's loop, without the app around it: ask the model, run the tools it names, feed the
// results back, repeat until a turn names no tool, `report` was called, or the steps run out.

/// What running one tool gave back. `note` is set when the call was a valid `report`.
struct BrainToolResult: Sendable {
    var text: String
    var isError: Bool = false
    var note: MochiNote? = nil
}

struct BrainLoopOutcome: Equatable, Sendable {
    /// The model ended its turn (or reported) rather than running out of steps.
    var finished: Bool
    /// The last text the model wrote.
    var finalText: String
    var report: MochiNote?
    /// A tool call that could not be read ended the loop with a plain "try again" report.
    var gaveUp: Bool = false
    var steps: Int
}

@MainActor
enum BrainLoop {
    static let giveUpLine = "I couldn\u{2019}t work that out \u{2014} try saying it another way."

    /// Runs one user turn over `history` (already holding that user message). Model errors throw;
    /// the caller decides what to keep. `onGiveUp` is told when the loop ends on an unreadable tool call.
    static func run(client: ModelClient, system: String, tools: [BrainTool], history: inout [BrainMessage],
                    maxSteps: Int, execute: (BrainToolCall) async -> BrainToolResult,
                    onGiveUp: (MochiNote) -> Void) async throws -> BrainLoopOutcome {
        var outcome = BrainLoopOutcome(finished: false, finalText: "", report: nil, steps: 0)
        while outcome.steps < maxSteps {
            try Task.checkCancellation()
            outcome.steps += 1
            let turn = try await client.complete(system: system, messages: history, tools: tools)
            if turn.unparsable {
                // Weak local models: stop here with a plain line instead of retrying blindly.
                history.append(.assistant(BrainTurn(text: turn.text, toolCalls: [])))
                let note = MochiNote(line: giveUpLine, actions: [])
                onGiveUp(note)
                outcome.report = note
                outcome.gaveUp = true
                outcome.finished = true
                return outcome
            }
            history.append(.assistant(turn))
            if !turn.text.isEmpty { outcome.finalText = turn.text }
            if turn.toolCalls.isEmpty { outcome.finished = true; return outcome }
            var reported = false
            for call in turn.toolCalls {
                let result = await execute(call)
                history.append(.tool(id: call.id, result.text, isError: result.isError))
                if let note = result.note { outcome.report = note; reported = true }
            }
            // The report is the last word: no further model call.
            if reported { outcome.finished = true; return outcome }
        }
        return outcome
    }
}
#else
#endif
