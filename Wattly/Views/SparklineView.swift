import SwiftUI

/// The 26px sparkline band (prototype `.wa-spark`, `:15`). Draws the polyline +
/// optional area fill from `values` over the last-60s window, pixel-matched to the
/// prototype `spark()`. Geometry lives in `Sparkline` (pure); this view only maps
/// the 120×28 viewBox into the actual Canvas size and strokes it.
///
/// Render-stop on panel close is automatic: `MenuBarExtra(.window)` unmounts the
/// popover content, so this view leaves the tree and its Canvas never redraws
/// (issue 03 §In-5). There is no per-frame timer — redraws are driven only by the
/// `@Observable` poll tick while the view is on screen.
struct SparklineView: View {
    let values: [Double]
    var stroke: Color
    var fill: Color? = nil

    var body: some View {
        Canvas(opaque: false) { ctx, size in
            guard let geo = Sparkline.geometry(values) else { return }

            let sx = size.width / Sparkline.width
            let sy = size.height / Sparkline.height
            func map(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * sx, y: p.y * sy) }

            if let fill {
                var area = Path()
                area.addLines(geo.area.map(map))
                area.closeSubpath()
                ctx.fill(area, with: .color(fill))
            }

            var line = Path()
            line.addLines(geo.line.map(map))
            ctx.stroke(line, with: .color(stroke),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .frame(height: 26)
    }
}
