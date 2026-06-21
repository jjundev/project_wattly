import Testing
import Foundation
@testable import Wattly

/// Retention contract: 60 s window + 256 hard cap, independent of poll interval.
struct HistoryTests {
    @Test func dropsSamplesOlderThanSixtySeconds() {
        var buf = HistoryBuffer()
        let base = ContinuousClock().now
        buf.append(1, at: base)
        buf.append(2, at: base.advanced(by: .seconds(30)))
        buf.append(3, at: base.advanced(by: .seconds(61)))   // base sample is now >60 s old
        #expect(buf.values == [2, 3])
    }

    @Test func capsAtTwoHundredFiftySix() {
        var buf = HistoryBuffer()
        let base = ContinuousClock().now
        for i in 0..<300 {                                    // all within the 60 s window
            buf.append(Double(i), at: base.advanced(by: .milliseconds(i)))
        }
        #expect(buf.samples.count == 256)
        #expect(buf.values.last == 299)
    }

    /// Issue 03 step D: whatever the poll interval, the retained window is always
    /// the last 60 s and never exceeds the 256 cap. Retention is time-based, so
    /// 1/2/5 s spacing all keep a full 60 s span (just with fewer samples).
    @Test(arguments: [Duration.seconds(1), .seconds(2), .seconds(5)])
    func sixtySecondSpanIsIntervalIndependent(step: Duration) {
        var buf = HistoryBuffer()
        let base = ContinuousClock().now
        var t = base
        while t <= base.advanced(by: .seconds(60)) {          // a 60 s span at `step`
            buf.append(0, at: t)
            t = t.advanced(by: step)
        }
        let span = buf.samples.first!.at.duration(to: buf.samples.last!.at)
        #expect(span == .seconds(60))                          // always the full window
        #expect(buf.samples.count <= HistoryBuffer.cap)        // never over the cap
        #expect(buf.samples.count >= 2)                        // and enough to draw
    }
}
