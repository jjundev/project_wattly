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
