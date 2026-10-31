import Foundation

/// The caller may cancel synchronously from any thread, including while native work is running.
final class CleanupCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var deadline: ContinuousClock.Instant?

    init(deadline: ContinuousClock.Instant? = nil) {
        self.deadline = deadline
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// Finalization may reduce an in-flight operation's remaining budget.
    /// A later caller can never extend an existing deadline.
    func shortenDeadline(to value: ContinuousClock.Instant) {
        lock.withLock {
            if deadline.map({ value < $0 }) ?? true { deadline = value }
        }
    }

    var isCancelled: Bool {
        lock.withLock { cancelled || deadline.map { ContinuousClock.now >= $0 } == true }
    }
}

