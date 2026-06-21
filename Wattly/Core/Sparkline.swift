import CoreGraphics

/// Pure sparkline geometry — the deterministic core of issue 03, mirroring the
/// prototype `spark()` (`interactive/project/Wattly Interactive.dc.html:549-564`).
///
/// Coordinates live in a fixed **120×28 viewBox** space; the view scales them to
/// the actual Canvas size (independent x/y stretch = `preserveAspectRatio="none"`).
/// No SwiftUI import on purpose: this stays a value-only function so the geometry
/// is unit-testable without a render host (issue 18).
enum Sparkline {
    /// viewBox width, height, and vertical padding — the prototype's `w`, `ht`, `pad`.
    static let width: CGFloat = 120
    static let height: CGFloat = 28
    static let pad: CGFloat = 3

    struct Geometry: Equatable {
        /// The polyline through the samples (left→right).
        var line: [CGPoint]
        /// `line` closed down to the baseline: `(0, height) … line … (width, height)`.
        var area: [CGPoint]
    }

    /// Geometry for a series, or `nil` when there is nothing to draw (`< 2` samples),
    /// matching `spark()`'s empty-string return for `h.length < 2`.
    ///
    /// Autoscale is min..max over the window; a flat series (`mx - mn < 1e-6`) gets
    /// `mx = mn + 1` so the divisor never collapses. Unlike `spark()` the points are
    /// raw (no `.toFixed(1)` string rounding) — Canvas wants floats.
    static func geometry(_ values: [Double]) -> Geometry? {
        let n = values.count
        guard n >= 2 else { return nil }

        let mn = values.min()!
        var mx = values.max()!
        if mx - mn < 1e-6 { mx = mn + 1 }

        let span = mx - mn
        let usable = height - 2 * pad
        let line: [CGPoint] = values.enumerated().map { i, v in
            let x = CGFloat(i) / CGFloat(n - 1) * width
            let norm = (v - mn) / span
            let y = pad + (1 - CGFloat(norm)) * usable
            return CGPoint(x: x, y: y)
        }

        var area = line
        area.insert(CGPoint(x: 0, y: height), at: 0)
        area.append(CGPoint(x: width, y: height))

        return Geometry(line: line, area: area)
    }
}
