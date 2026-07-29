import Foundation

/// Stateful display policy for a battery runtime estimate. It deliberately owns neither I/O
/// nor SwiftUI: `SystemMonitor` supplies its normalized sample at each scheduled poll.
/// A repeated candidate is projected from its first observation, while any new telemetry,
/// source change, charging transition, or long gap becomes a new baseline.
struct BatteryRuntimeProjection {
    private enum Source: Equatable {
        case registry
        case estimated
    }

    private struct Candidate {
        var minutes: Int
        var source: Source
    }

    private struct Anchor {
        var minutes: Int
        var source: Source
        var at: ContinuousClock.Instant
    }

    private static let maximumProjectionGap: Double = 30
    private var anchor: Anchor?
    private var lastObservation: ContinuousClock.Instant?

    mutating func ingest(_ sample: BatterySample, at now: ContinuousClock.Instant) -> Int? {
        guard let candidate = candidate(for: sample) else {
            reset()
            return nil
        }

        guard let anchor,
              let lastObservation,
              anchor.minutes == candidate.minutes,
              anchor.source == candidate.source,
              seconds(from: lastObservation, to: now) <= Self.maximumProjectionGap
        else {
            self.anchor = Anchor(minutes: candidate.minutes, source: candidate.source, at: now)
            self.lastObservation = now
            return candidate.minutes
        }

        self.lastObservation = now
        let minutes = Int(ceil(Double(anchor.minutes) - seconds(from: anchor.at, to: now) / 60))
        guard (1...1_440).contains(minutes) else {
            reset()
            return nil
        }
        return minutes
    }

    mutating func reset() {
        anchor = nil
        self.lastObservation = nil
    }

    private func candidate(for sample: BatterySample) -> Candidate? {
        guard !sample.charging else { return nil }
        if let minutes = validatedTimeRemainingMinutes(sample.timeRemainingMinutes) {
            return Candidate(minutes: minutes, source: .registry)
        }
        if let average = sample.average1mW,
           let minutes = estimatedTimeRemainingMinutes(remainingWattHours: sample.remainingWh, netW: average) {
            return Candidate(minutes: minutes, source: .estimated)
        }
        if let minutes = estimatedTimeRemainingMinutes(remainingWattHours: sample.remainingWh, netW: sample.netW) {
            return Candidate(minutes: minutes, source: .estimated)
        }
        return nil
    }

    private func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: end)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }
}
