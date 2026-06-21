import Foundation

/// Injected monotonic time source. Production uses `ContinuousClock`; tests use
/// `ManualClock` to make history retention and cold-start deterministic (L7).
///
/// Without this seam, issue 18's "timestamp-based 60 s history" and adaptive
/// polling tests would be impossible — you cannot control wall-clock time.
protocol MonotonicClock: Sendable {
    func now() -> ContinuousClock.Instant
}

struct LiveClock: MonotonicClock {
    private let clock = ContinuousClock()
    func now() -> ContinuousClock.Instant { clock.now }
}

/// Test clock: starts at a captured instant and only advances when told to.
final class ManualClock: MonotonicClock, @unchecked Sendable {
    private let base = ContinuousClock().now
    private var offset: Duration = .zero
    private let lock = NSLock()

    func advance(by duration: Duration) {
        lock.lock(); offset += duration; lock.unlock()
    }

    func now() -> ContinuousClock.Instant {
        lock.lock(); defer { lock.unlock() }
        return base.advanced(by: offset)
    }
}
