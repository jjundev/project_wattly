import Foundation

/// Internal telemetry pipeline for battery metrics.
/// Handles transient suppression on adapter disconnect, 1-minute EMA averaging for slowly changing charge trends,
/// and battery runtime projection between registry updates.
struct BatteryTelemetryPipeline: Sendable {
    /// 1-minute EMA average of battery net watts. Reset on adapter regime changes.
    private(set) var oneMinuteAverage: Double?
    private var oneMinuteInstant: ContinuousClock.Instant?
    private var runtimeProjection = BatteryRuntimeProjection()

    /// Previous AC-adapter connection state.
    private(set) var lastExternalConnected: Bool?
    /// Whether the adapter connection state changed in the most recent `ingest`.
    private(set) var hasConnectionChanged: Bool = false

    /// Last non-nil registry time observed while an adapter was connected.
    private var lastConnectedTimeRemainingMinutes: Int?
    /// The connected-era value to suppress until a different discharge estimate is published.
    private var staleTimeRemainingAfterDisconnect: Int?

    init() {}

    /// Ingests a raw battery sample at the given instant, applies transient suppression,
    /// regime-change resets, 1-minute EMA, and runtime projection, returning the processed sample.
    mutating func ingest(
        _ raw: BatterySample,
        at instant: ContinuousClock.Instant,
        targetPercentage: Int = 100
    ) -> BatterySample {
        var sample = suppressingStaleTimeAfterDisconnect(raw)
        sample.targetPercentage = targetPercentage

        if let last = lastExternalConnected, last != sample.externalConnected {
            hasConnectionChanged = true
            oneMinuteAverage = nil
            oneMinuteInstant = nil
            runtimeProjection.reset()
        } else {
            hasConnectionChanged = false
        }
        lastExternalConnected = sample.externalConnected

        let averageDt = oneMinuteInstant.map { seconds(from: $0, to: instant) } ?? 0
        oneMinuteAverage = PowerSmoothing.emaStep(
            previous: oneMinuteAverage, raw: sample.netW, dt: averageDt, tau: 60)
        oneMinuteInstant = instant

        var presented = sample
        presented.average1mW = oneMinuteAverage
        presented.projectedTimeRemainingMinutes = runtimeProjection.ingest(presented, at: instant)
        return presented
    }

    /// Resets all pipeline state across full monitor resets.
    mutating func reset() {
        oneMinuteAverage = nil
        oneMinuteInstant = nil
        runtimeProjection.reset()
        lastExternalConnected = nil
        hasConnectionChanged = false
        lastConnectedTimeRemainingMinutes = nil
        staleTimeRemainingAfterDisconnect = nil
    }

    private mutating func suppressingStaleTimeAfterDisconnect(_ raw: BatterySample) -> BatterySample {
        var sample = raw
        let rawTime = raw.timeRemainingMinutes

        if raw.externalConnected {
            lastConnectedTimeRemainingMinutes = rawTime
            staleTimeRemainingAfterDisconnect = nil
        } else if lastExternalConnected == true {
            staleTimeRemainingAfterDisconnect = lastConnectedTimeRemainingMinutes
        } else if let stale = staleTimeRemainingAfterDisconnect,
                  let rawTime,
                  rawTime != stale {
            staleTimeRemainingAfterDisconnect = nil
        }

        if rawTime == staleTimeRemainingAfterDisconnect {
            sample.timeRemainingMinutes = nil
        }
        return sample
    }
}
