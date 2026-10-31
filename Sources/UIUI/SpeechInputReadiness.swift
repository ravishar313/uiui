import Foundation

/// One capture's first usable PCM buffer, including silence. Waiting never owns
/// the serial audio queue, and cancellation cannot publish a later ready state.
final class SpeechInputReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?

    func receivedAudio() { resolve(.success(())) }
    func cancel() { resolve(.failure(CancellationError())) }
    func fail(_ message: String) { resolve(.failure(SpeechCaptureFailure.message(message))) }

    func wait(timeout: Duration = .seconds(3)) async throws {
        try await withTaskCancellationHandler {
            let timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                self?.resolve(.failure(SpeechCaptureFailure.message(
                    "The system microphone isn't delivering audio. Check its connection and try again.")))
            }
            defer { timeoutTask.cancel() }
            try await withCheckedThrowingContinuation { continuation in
                let completed = lock.withLock { () -> Result<Void, Error>? in
                    if let result { return result }
                    waiter = continuation
                    return nil
                }
                if let completed { continuation.resume(with: completed) }
            }
        } onCancel: { self.cancel() }
    }

    private func resolve(_ result: Result<Void, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard self.result == nil else { return nil }
            self.result = result
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume(with: result)
    }
}
