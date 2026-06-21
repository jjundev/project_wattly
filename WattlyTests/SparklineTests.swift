import Testing
import CoreGraphics
@testable import Wattly

/// Geometry contract for the sparkline, mirroring the prototype `spark()`
/// (120×28 viewBox, pad 3, min..max autoscale, flat-series guard, area baseline).
struct SparklineTests {
    @Test func nilBelowTwoSamples() {
        #expect(Sparkline.geometry([]) == nil)
        #expect(Sparkline.geometry([5]) == nil)
    }

    @Test func knownThreePointsMapExactly() {
        // values 0,10,5 → span 10, usable 22, pad 3.
        let geo = Sparkline.geometry([0, 10, 5])
        #expect(geo?.line == [
            CGPoint(x: 0, y: 25),    // norm 0   → 3 + 22
            CGPoint(x: 60, y: 3),    // norm 1   → 3 + 0
            CGPoint(x: 120, y: 14),  // norm 0.5 → 3 + 11
        ])
    }

    @Test func areaClosesToBaseline() {
        let geo = Sparkline.geometry([0, 10, 5])
        #expect(geo?.area.first == CGPoint(x: 0, y: 28))
        #expect(geo?.area.last == CGPoint(x: 120, y: 28))
        // The middle of the area is exactly the line.
        #expect(geo?.area.dropFirst().dropLast() == geo?.line[...])
    }

    @Test func flatSeriesGuardAvoidsDivideByZero() {
        let geo = Sparkline.geometry([5, 5])
        // mx = mn + 1 → every sample normalises to 0 → bottom of the padded band.
        #expect(geo?.line == [CGPoint(x: 0, y: 25), CGPoint(x: 120, y: 25)])
        for p in geo?.line ?? [] {
            #expect(!p.y.isNaN && p.y.isFinite)
        }
    }
}
