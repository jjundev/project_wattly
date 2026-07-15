import SwiftUI

/// The interactive fan-curve editor — replaces the four RPM sliders. A `Canvas` draws the grid,
/// the piecewise-linear curve + area fill, the per-anchor handles, and the live-CPU marker; a
/// `DragGesture` moves the nearest anchor's RPM. All plot math lives in the pure (tested)
/// `FanCurveGeometry`; this view only renders it and wires the gesture. VoiceOver + keyboard
/// adjustment of each anchor is layered on in the accessibility overlay (added separately).
struct FanCurveEditor: View {
    @Binding var curve: FanCurve
    var currentCPU: Double?
    @Environment(\.tokens) private var t

    @State private var dragIndex: Int?

    private static let viewHeight: CGFloat = 150

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            canvas(size)
                .contentShape(Rectangle())
                .gesture(drag(in: size))
        }
        .frame(height: Self.viewHeight)
    }

    // MARK: Drawing

    private func canvas(_ size: CGSize) -> some View {
        Canvas { ctx, _ in
            let rect = FanCurveGeometry.plotRect(in: size)

            // horizontal grid + y labels (0…8k every 2k)
            for rpm in stride(from: 0.0, through: FanCurveGeometry.rpmMax, by: 2000) {
                let y = FanCurveGeometry.y(forRPM: rpm, in: size)
                var g = Path(); g.move(to: CGPoint(x: rect.minX, y: y)); g.addLine(to: CGPoint(x: rect.maxX, y: y))
                ctx.stroke(g, with: .color(t.line), lineWidth: 1)
                ctx.draw(Text("\(Int(rpm / 1000))k").font(WattlyFont.at(9.5, weight: .medium)).foregroundColor(t.faint),
                         at: CGPoint(x: rect.minX - 6, y: y), anchor: .trailing)
            }

            // vertical gridline at every anchor; label only every 10°
            for c in FanCurveGeometry.anchorsCelsius {
                let x = FanCurveGeometry.x(forCelsius: c, in: size)
                let isMajor = c.truncatingRemainder(dividingBy: 10) == 0
                var g = Path(); g.move(to: CGPoint(x: x, y: rect.minY)); g.addLine(to: CGPoint(x: x, y: rect.maxY))
                ctx.stroke(g, with: .color(t.line.opacity(isMajor ? 1 : 0.55)), lineWidth: 1)
                if isMajor {
                    ctx.draw(Text("\(Int(c))°").font(WattlyFont.at(9.5, weight: .medium)).foregroundColor(t.faint),
                             at: CGPoint(x: x, y: rect.maxY + 12), anchor: .center)
                }
            }

            let pts = FanCurveGeometry.handlePoints(curve.rpms, in: size)
            guard pts.count == FanCurveGeometry.anchorsCelsius.count else { return }

            // area fill under the curve
            var area = Path()
            area.move(to: CGPoint(x: pts[0].x, y: rect.maxY))
            for p in pts { area.addLine(to: p) }
            area.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: rect.maxY))
            area.closeSubpath()
            ctx.fill(area, with: .color(Tokens.accent.opacity(0.14)))

            // the curve polyline
            var line = Path(); line.addLines(pts)
            ctx.stroke(line, with: .color(Tokens.accent), style: StrokeStyle(lineWidth: 2, lineJoin: .round))

            // live-CPU marker (dashed vertical + dot on the curve + label)
            if let cpu = currentCPU, cpu >= FanCurveGeometry.celsiusMin, cpu <= FanCurveGeometry.celsiusMax {
                let x = FanCurveGeometry.x(forCelsius: cpu, in: size)
                let yv = FanCurveGeometry.y(forRPM: curve.evaluate(inputCelsius: cpu), in: size)
                var m = Path(); m.move(to: CGPoint(x: x, y: rect.minY)); m.addLine(to: CGPoint(x: x, y: rect.maxY))
                ctx.stroke(m, with: .color(Tokens.statusOrange), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                ctx.fill(Path(ellipseIn: CGRect(x: x - 3, y: yv - 3, width: 6, height: 6)), with: .color(Tokens.statusOrange))
                ctx.draw(Text("\(Int(cpu.rounded()))°C").font(WattlyFont.at(9.5, weight: .bold)).foregroundColor(Tokens.statusOrange),
                         at: CGPoint(x: x + 5, y: rect.minY + 2), anchor: .topLeading)
            }

            // handle dots (filled when the anchor is being dragged)
            for (i, p) in pts.enumerated() {
                let box = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
                ctx.fill(Path(ellipseIn: box), with: .color(i == dragIndex ? Tokens.accent : t.rowBg))
                ctx.stroke(Path(ellipseIn: box), with: .color(Tokens.accent), lineWidth: 2.5)
            }
        }
    }

    // MARK: Editing

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let i = dragIndex ?? FanCurveGeometry.nearestAnchorIndex(toX: value.startLocation.x, in: size)
                dragIndex = i
                setRPM(FanCurveGeometry.rpm(forY: value.location.y, in: size), at: i)
            }
            .onEnded { _ in dragIndex = nil }
    }

    private func setRPM(_ rpm: Double, at index: Int) {
        guard curve.rpms.indices.contains(index) else { return }
        var next = curve
        next.rpms[index] = rpm
        curve = next
    }
}

#Preview {
    struct Harness: View {
        @State var curve = FanCurve(rpms: [1000,1200,1500,1900,2400,3000,3600,4200,4800,5500,6200,6800,7400])
        var body: some View {
            FanCurveEditor(curve: $curve, currentCPU: 62)
                .padding()
                .environment(\.tokens, .dark)
                .frame(width: 320)
        }
    }
    return Harness()
}
