import Foundation

struct HistorySample: Sendable, Equatable {
    var at: ContinuousClock.Instant
    var value: Double
}

/// Per-card sparkline series. Retention *contract* (L9 / PRD line 75): keep the
/// last 60 s relative to the newest sample, with a hard safety cap of 256 entries.
///
/// This type owns only the retention contract. Sparkline rendering and the
/// interval-independent edge tests live in issue 03.
struct HistoryBuffer: Sendable {
    static let window: Duration = .seconds(60)
    static let cap = 256

    private(set) var samples: [HistorySample] = []

    mutating func append(_ value: Double, at instant: ContinuousClock.Instant) {
        samples.append(HistorySample(at: instant, value: value))
        prune(now: instant)
    }

    private mutating func prune(now: ContinuousClock.Instant) {
        // Drop anything older than the 60 s window relative to the newest sample.
        samples.removeAll { $0.at.duration(to: now) > Self.window }
        // Hard cap: keep the newest `cap` entries.
        if samples.count > Self.cap {
            samples.removeFirst(samples.count - Self.cap)
        }
    }

    var values: [Double] { samples.map(\.value) }
}
