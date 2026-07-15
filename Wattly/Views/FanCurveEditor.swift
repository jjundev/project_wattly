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
    @FocusState private var focusedAnchor: Int?

    private static let viewHeight: CGFloat = 150

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                canvas(size)
                anchorControls(size)
            }
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

            // live-CPU marker (dashed vertical + dot on the curve + label). Clamp the x to the
            // plot's temperature range so the marker stays visible when the CPU idles below the
            // first anchor (40°C) or spikes above the last (100°C) — it pins to the edge instead
            // of vanishing. The label still shows the true reading.
            if let cpu = currentCPU {
                let markerC = min(max(cpu, FanCurveGeometry.celsiusMin), FanCurveGeometry.celsiusMax)
                let x = FanCurveGeometry.x(forCelsius: markerC, in: size)
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
                ctx.fill(Path(ellipseIn: box), with: .color(i == dragIndex || i == focusedAnchor ? Tokens.accent : t.rowBg))
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

    // MARK: Accessibility + keyboard

    /// One invisible focusable control per anchor, positioned on its handle. Gives VoiceOver an
    /// adjustable action (up/down = ±`rpmStep`) and hardware arrow keys the same effect when the
    /// handle is focused — restoring the parity the sliders had (issue 15). Pointer drags still
    /// go to the container gesture; these clear views carry no gesture of their own.
    private func anchorControls(_ size: CGSize) -> some View {
        let pts = FanCurveGeometry.handlePoints(curve.rpms, in: size)
        return ForEach(Array(FanCurveGeometry.anchorsCelsius.enumerated()), id: \.offset) { i, c in
            Color.clear
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .position(pts.indices.contains(i) ? pts[i] : .zero)
                .focusable()
                .focused($focusedAnchor, equals: i)
                .accessibilityElement()
                .accessibilityLabel(Accessibility.fanAnchorLabel(celsius: c))
                .accessibilityValue(Accessibility.fanAnchorValue(rpm: curve.rpms.indices.contains(i) ? curve.rpms[i] : 0))
                .accessibilityAdjustableAction { direction in
                    nudge(direction == .increment ? FanCurveGeometry.rpmStep : -FanCurveGeometry.rpmStep, at: i)
                }
                .onKeyPress(.upArrow)   { nudge(FanCurveGeometry.rpmStep, at: i); return .handled }
                .onKeyPress(.downArrow) { nudge(-FanCurveGeometry.rpmStep, at: i); return .handled }
        }
    }

    private func nudge(_ delta: Double, at index: Int) {
        guard curve.rpms.indices.contains(index) else { return }
        let clamped = min(max(curve.rpms[index] + delta, FanCurveGeometry.rpmMin), FanCurveGeometry.rpmMax)
        setRPM(clamped, at: index)
    }
}

#Preview {
    struct Harness: View {
        @State var curve = FanCurve(rpms: [800,900,1000,1200,1500,1900,2400,3000,3600,4200,4800,5500,6200,6800,7400])
        var body: some View {
            FanCurveEditor(curve: $curve, currentCPU: 62)
                .padding()
                .environment(\.tokens, .dark)
                .frame(width: 320)
        }
    }
    return Harness()
}
