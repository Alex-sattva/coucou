import Foundation

/// Reads a pipe to end-of-file on a background queue while the child runs, so the child can
/// never block on a full pipe buffer, and hands back everything once it has exited.
final class PipeBuffer: @unchecked Sendable {
    private let done = DispatchGroup()
    private var data = Data()

    func attach(_ pipe: Pipe) {
        done.enter()
        let handle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [self] in
            // Returns at EOF: when the child (the only writer left) exits.
            data = handle.readDataToEndOfFile()
            done.leave()
        }
    }

    /// Waits for the reader to reach end-of-file and returns all output. Call after the child
    /// has exited (from the termination handler), never on the main thread.
    func finish(_ pipe: Pipe) -> Data {
        done.wait()
        return data
    }
}
