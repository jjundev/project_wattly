import Foundation

/// Pipeline value type for tracking Wattly's own EMA-smoothed power draw in watts.
/// Measures elapsed nanojoules from `SelfEnergySampling` and computes smoothed watts via `SelfPower` and `PowerSmoothing`.
struct SelfPowerTracker: Sendable {
    /// Wattly's own EMA-smoothed power draw in watts, or nil until the first valid interval.
    private(set) var currentWatts: Double?
    private var prevNanojoules: UInt64?
    private var prevInstant: ContinuousClock.Instant?

    init() {}

    /// Diffs the energy counter from the given source against previous sample, smoothing with EMA.
    /// Returns the updated watts (or nil / previous value if an anomaly or baseline occurs).
    @discardableResult
    mutating func sample(using energySource: any SelfEnergySampling, at instant: ContinuousClock.Instant) -> Double? {
        guard let curr = energySource.energyNanojoules() else { return currentWatts }
        defer {
            prevNanojoules = curr
            prevInstant = instant
        }
        guard let prevNJ = prevNanojoules, let prevI = prevInstant else { return currentWatts }
        let dt = seconds(from: prevI, to: instant)
        guard let raw = SelfPower.watts(prevNanojoules: prevNJ, currNanojoules: curr, dt: dt) else { return currentWatts }
        currentWatts = PowerSmoothing.emaStep(previous: currentWatts, raw: raw, dt: dt)
        return currentWatts
    }

    mutating func reset() {
        currentWatts = nil
        prevNanojoules = nil
        prevInstant = nil
    }
}
