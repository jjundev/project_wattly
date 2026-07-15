import Testing
import CoreGraphics
@testable import Wattly

struct FanCurveGeometryTests {
    // A fixed render size → plotRect = (34, 12, 266, 154): minX 34, maxX 300, minY 12, maxY 166.
    private let size = CGSize(width: 312, height: 190)
    private let ramp: [Double] =
        [800, 900, 1000, 1200, 1500, 1900, 2400, 3000, 3600, 4200, 4800, 5500, 6200, 6800, 7400]

    @Test func plotRectInsetsTheCanvas() {
        let r = FanCurveGeometry.plotRect(in: size)
        #expect(r.minX == 34);  #expect(r.maxX == 300)
        #expect(r.minY == 12);  #expect(r.maxY == 166)
    }

    @Test func handlePointsSpanPlotWidthMonotonically() {
        let pts = FanCurveGeometry.handlePoints(ramp, in: size)
        #expect(pts.count == 15)
        #expect(pts.first!.x == 34)     // first anchor at plot left
        #expect(pts.last!.x == 300)     // last anchor at plot right
        #expect(zip(pts, pts.dropFirst()).allSatisfy { $0.x < $1.x })  // strictly increasing x
    }

    @Test func yMapsRPMAxisToPlotHeightInverted() {
        #expect(FanCurveGeometry.y(forRPM: 8000, in: size) == 12)   // max rpm → plot top
        #expect(FanCurveGeometry.y(forRPM: 0, in: size) == 166)     // min rpm → plot bottom
    }

    @Test func rpmForYRoundTripsOnStepBoundary() {
        let y = FanCurveGeometry.y(forRPM: 3000, in: size)
        #expect(FanCurveGeometry.rpm(forY: y, in: size) == 3000)
    }

    @Test func rpmForYClampsOutsidePlot() {
        #expect(FanCurveGeometry.rpm(forY: -50, in: size) == 8000)   // above the top → max
        #expect(FanCurveGeometry.rpm(forY: 999, in: size) == 0)      // below the bottom → min
    }

    @Test func rpmForYRoundsToStep() {
        // Any y inside the plot must resolve to a whole multiple of the 100-RPM step.
        for y in stride(from: CGFloat(12), through: 166, by: 7) {
            #expect(FanCurveGeometry.rpm(forY: y, in: size).truncatingRemainder(dividingBy: 100) == 0)
        }
    }

    @Test func nearestAnchorIndexPicksClosestColumn() {
        let x70 = FanCurveGeometry.x(forCelsius: 70, in: size)
        #expect(FanCurveGeometry.nearestAnchorIndex(toX: x70, in: size) == 8)  // 70 °C is anchor 8 (30,35,…,70)
        #expect(FanCurveGeometry.nearestAnchorIndex(toX: -100, in: size) == 0) // far left → first
        #expect(FanCurveGeometry.nearestAnchorIndex(toX: 9999, in: size) == 14)// far right → last
    }
}
