import CoreGraphics

/// Pure geometry for the fan-curve editor — the deterministic core, mirroring `Sparkline`:
/// value-only (no SwiftUI), so it is unit-testable without a render host. Maps the fixed
/// temperature anchors × the editable RPMs into a `Canvas` of a given size, and inverts a
/// drag's y back into a stepped, clamped RPM.
enum FanCurveGeometry {
    /// The temperature domain = the model's fixed anchors (40…100 °C, 5° steps).
    static let anchorsCelsius = FanCurve.anchorsCelsius
    static var celsiusMin: Double { anchorsCelsius.first ?? 40 }
    static var celsiusMax: Double { anchorsCelsius.last ?? 100 }

    /// The editable RPM axis. `rpmMax` is the plot ceiling (the old slider's `0…8000`); the
    /// model's own rawValue validation still permits up to 20000, so a stored curve above 8000
    /// just pins to the top of the plot.
    static let rpmMin: Double = 0
    static let rpmMax: Double = 8000
    static let rpmStep: Double = 100
    static let zeroFanEnterCelsius = FanControlPolicy.zeroRPMEnterCelsius
    static let zeroFanExitCelsius = FanControlPolicy.zeroRPMExitCelsius

    /// The literal-zero plateau that intersects the policy's 48…55°C hysteresis window.
    /// A stopped fan can survive a curve edit, so a plateau beginning at 50°C can still hold that
    /// stopped state; do not require the plateau itself to begin at the 48°C entry boundary.
    static func zeroRPMHoldRange(for curve: FanCurve) -> ClosedRange<Double>? {
        guard curve.rpms.count == anchorsCelsius.count,
              curve.rpms.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }

        var runStart: Int?
        for index in curve.rpms.indices {
            if curve.rpms[index] == 0 {
                runStart = runStart ?? index
                continue
            }
            guard let start = runStart else { continue }
            if let range = zeroRPMHoldRange(startAnchor: start, endAnchor: index - 1) { return range }
            runStart = nil
        }
        guard let start = runStart else { return nil }
        return zeroRPMHoldRange(startAnchor: start, endAnchor: curve.rpms.count - 1)
    }

    private static func zeroRPMHoldRange(startAnchor: Int, endAnchor: Int) -> ClosedRange<Double>? {
        // A single zero-valued anchor has no temperature interval; only a plateau can hold state.
        guard endAnchor > startAnchor else { return nil }
        let lower = max(anchorsCelsius[startAnchor], zeroFanEnterCelsius)
        let upper = min(anchorsCelsius[endAnchor], zeroFanExitCelsius)
        return lower < upper ? lower...upper : nil
    }

    static func zeroRPMHoldBand(for curve: FanCurve, in size: CGSize) -> CGRect? {
        guard let range = zeroRPMHoldRange(for: curve) else { return nil }
        let plot = plotRect(in: size)
        let start = min(max(x(forCelsius: range.lowerBound, in: size), plot.minX), plot.maxX)
        let end = min(max(x(forCelsius: range.upperBound, in: size), plot.minX), plot.maxX)
        return CGRect(x: min(start, end), y: plot.minY,
                      width: abs(end - start), height: plot.height)
    }

    /// Plot insets inside the Canvas — room for the y labels (left) and x labels (bottom).
    static let padLeft: CGFloat = 34
    static let padRight: CGFloat = 12
    static let padTop: CGFloat = 12
    static let padBottom: CGFloat = 24   // matches the prototype's PAD.b

    static func plotRect(in size: CGSize) -> CGRect {
        CGRect(x: padLeft, y: padTop,
               width: max(0, size.width - padLeft - padRight),
               height: max(0, size.height - padTop - padBottom))
    }

    static func x(forCelsius c: Double, in size: CGSize) -> CGFloat {
        let r = plotRect(in: size)
        let span = celsiusMax - celsiusMin
        guard span > 0 else { return r.minX }
        return r.minX + CGFloat((c - celsiusMin) / span) * r.width
    }

    static func y(forRPM rpm: Double, in size: CGSize) -> CGFloat {
        let r = plotRect(in: size)
        let span = rpmMax - rpmMin
        guard span > 0 else { return r.maxY }
        return r.maxY - CGFloat((rpm - rpmMin) / span) * r.height
    }

    /// Inverse of `y(forRPM:)`, clamped to `rpmMin…rpmMax` and rounded to `rpmStep`.
    static func rpm(forY yPix: CGFloat, in size: CGSize) -> Double {
        let r = plotRect(in: size)
        guard r.height > 0 else { return rpmMin }
        let frac = Double((r.maxY - yPix) / r.height)
        let raw = rpmMin + frac * (rpmMax - rpmMin)
        let stepped = (raw / rpmStep).rounded() * rpmStep
        return min(max(stepped, rpmMin), rpmMax)
    }

    static func handlePoints(_ rpms: [Double], in size: CGSize) -> [CGPoint] {
        zip(anchorsCelsius, rpms).map { c, rpm in
            CGPoint(x: x(forCelsius: c, in: size), y: y(forRPM: rpm, in: size))
        }
    }

    /// Index of the anchor whose column is nearest `xPix` — the anchor a drag at `xPix` edits.
    static func nearestAnchorIndex(toX xPix: CGFloat, in size: CGSize) -> Int {
        anchorsCelsius.indices.min(by: {
            abs(x(forCelsius: anchorsCelsius[$0], in: size) - xPix)
                < abs(x(forCelsius: anchorsCelsius[$1], in: size) - xPix)
        }) ?? 0
    }
}
