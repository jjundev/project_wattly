import SwiftUI

/// The adopted Wattly Pulse W waveform. Its raised left endpoint and marker express
/// a live measurement rather than the generic “power” lightning-bolt metaphor.
struct PulseWGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * (1 - x), y: rect.minY + rect.height * y)
        }

        p.move(to: point(0.07, 0.56))
        p.addLine(to: point(0.20, 0.56))
        p.addCurve(to: point(0.38, 0.80),
                   control1: point(0.26, 0.56), control2: point(0.30, 0.80))
        p.addCurve(to: point(0.52, 0.47),
                   control1: point(0.43, 0.80), control2: point(0.46, 0.47))
        p.addCurve(to: point(0.67, 0.80),
                   control1: point(0.57, 0.47), control2: point(0.62, 0.80))
        p.addCurve(to: point(0.86, 0.41),
                   control1: point(0.73, 0.80), control2: point(0.79, 0.53))
        return p
    }
}

/// The full Pulse W logo, including its electric-blue live-measurement marker.
/// A separate view keeps the waveform usable as a monochrome status-bar template.
struct PulseWMark: View {
    var lineWidth: CGFloat
    var markerColor: Color = Tokens.accent

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height) * 0.20
            ZStack(alignment: .topLeading) {
                PulseWGlyph()
                    .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                Circle()
                    .fill(markerColor)
                    .frame(width: diameter, height: diameter)
                    .position(x: proxy.size.width * 0.11, y: proxy.size.height * 0.17)
            }
        }
    }
}

// MARK: - Dynamic MenuBar Icon Vector Marks

// 1. Cooling Turbine Mark
struct TurbineMark: View {
    let frame: Int
    var markerColor: Color = Tokens.accent

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let strokeW = max(1.6, s * 0.09)
            let angle = (Double(frame) / 24.0) * 360.0

            ZStack {
                // Outer ring
                Circle()
                    .stroke(style: StrokeStyle(lineWidth: max(1.6, strokeW * 0.9)))
                    .opacity(0.70)
                    .frame(width: s * 0.92, height: s * 0.92)
                    .position(center)

                // Rotating blades and hub
                ZStack {
                    ForEach([0.0, 90.0, 180.0, 270.0], id: \.self) { a in
                        Path { p in
                            p.move(to: CGPoint(x: center.x, y: center.y - s * 0.12))
                            p.addCurve(
                                to: CGPoint(x: center.x + s * 0.28, y: center.y - s * 0.05),
                                control1: CGPoint(x: center.x + s * 0.23, y: center.y - s * 0.33),
                                control2: CGPoint(x: center.x + s * 0.40, y: center.y - s * 0.20)
                            )
                            p.closeSubpath()
                        }
                        .fill(markerColor)
                        .opacity(0.95)
                        .rotationEffect(.degrees(a), anchor: .center)
                    }

                    // Center donut hub (outer r=0.125s, inner r=0.05s)
                    Path { p in
                        p.addEllipse(in: CGRect(
                            x: center.x - s * 0.125,
                            y: center.y - s * 0.125,
                            width: s * 0.25,
                            height: s * 0.25
                        ))
                        p.addEllipse(in: CGRect(
                            x: center.x - s * 0.05,
                            y: center.y - s * 0.05,
                            width: s * 0.10,
                            height: s * 0.10
                        ))
                    }
                    .fill(markerColor, style: FillStyle(eoFill: true))
                }
                .rotationEffect(.degrees(angle), anchor: .center)
            }
        }
    }
}

// 2. Flowing Pulse W Waveform Mark
struct PulseWaveMark: View {
    let frame: Int
    var markerColor: Color = Tokens.accent

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            let strokeW = max(1.5, s * 0.08)
            let centerY = s * 0.52
            let phase = Double(frame) / 24.0

            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: s * 0.08, y: centerY))
                    p.addLine(to: CGPoint(x: s * 0.92, y: centerY))
                }
                .stroke(style: StrokeStyle(lineWidth: strokeW * 0.5, dash: [2, 2]))
                .opacity(0.25)

                Path { p in
                    let steps = 24
                    for i in 0...steps {
                        let progress = Double(i) / Double(steps)
                        let x = progress * s
                        let envelope = sin(progress * .pi)
                        let wave = sin(progress * .pi * 2.5 - phase * .pi * 2.0)
                        let y = centerY - (wave * envelope * (s * 0.32))
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                        else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round))

                Circle()
                    .fill(markerColor)
                    .frame(width: strokeW * 2.2, height: strokeW * 2.2)
                    .position(
                        x: s * 0.5 + sin(phase * .pi * 2.0) * s * 0.35,
                        y: centerY - cos(phase * .pi * 2.0) * s * 0.24
                    )
            }
        }
    }
}

// 3. VU Power Meter Mark
struct VUMeterMark: View {
    let frame: Int
    var markerColor: Color = Tokens.accent

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            let c = CGPoint(x: s / 2, y: s / 2)
            let strokeW = max(1.5, s * 0.08)
            let clampedFrame = min(max(frame, 0), 23)
            let angle = -40.0 + (Double(clampedFrame) / 23.0) * 80.0
            let pivot = CGPoint(x: c.x, y: s * 0.78)

            ZStack {
                // Meter scale arc
                Path { p in
                    p.addArc(
                        center: pivot,
                        radius: s * 0.50,
                        startAngle: .degrees(-135),
                        endAngle: .degrees(-45),
                        clockwise: false
                    )
                }
                .stroke(style: StrokeStyle(lineWidth: strokeW * 0.8, lineCap: .round))
                .opacity(0.35)

                // Scale ticks
                ForEach([-36.0, -18.0, 0.0, 18.0, 36.0], id: \.self) { a in
                    let rad = (a - 90.0) * .pi / 180.0
                    let x1 = pivot.x + cos(rad) * s * 0.44
                    let y1 = pivot.y + sin(rad) * s * 0.44
                    let x2 = pivot.x + cos(rad) * s * 0.52
                    let y2 = pivot.y + sin(rad) * s * 0.52
                    Path { p in
                        p.move(to: CGPoint(x: x1, y: y1))
                        p.addLine(to: CGPoint(x: x2, y: y2))
                    }
                    .stroke(style: StrokeStyle(lineWidth: strokeW * 0.7, lineCap: .round))
                    .opacity(0.60)
                }

                // Swinging needle
                Path { p in
                    p.move(to: pivot)
                    p.addLine(to: CGPoint(x: pivot.x, y: pivot.y - s * 0.50))
                }
                .stroke(style: StrokeStyle(lineWidth: strokeW * 1.15, lineCap: .round))
                .fill(markerColor)
                .rotationEffect(.degrees(angle), anchor: .init(x: 0.5, y: 0.78))

                // Pivot base dot
                Circle()
                    .fill(markerColor)
                    .frame(width: s * 0.22, height: s * 0.22)
                    .position(pivot)
            }
        }
    }
}

// 4. Isometric Rotating 3D Cube Mark
struct Cube3DMark: View {
    let frame: Int
    var markerColor: Color = Tokens.accent

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            let c = CGPoint(x: s / 2, y: s / 2)
            let r = s * 0.32
            let strokeW = max(1.2, s * 0.075)
            let angle = Double(frame) / 24.0 * .pi * 2.0
            let pitch = 0.45

            let vertices: [(Double, Double, Double)] = [
                (-1, -1, -1), (1, -1, -1), (1, 1, -1), (-1, 1, -1),
                (-1, -1, 1),  (1, -1, 1),  (1, 1, 1),  (-1, 1, 1)
            ]

            let projected: [CGPoint] = vertices.map { x, y, z in
                let x1 = x * cos(angle) + z * sin(angle)
                let z1 = -x * sin(angle) + z * cos(angle)
                let y2 = y * cos(pitch) - z1 * sin(pitch)
                return CGPoint(x: c.x + x1 * r * 0.8, y: c.y + y2 * r * 0.8)
            }

            let edges = [
                (0,1),(1,2),(2,3),(3,0),
                (4,5),(5,6),(6,7),(7,4),
                (0,4),(1,5),(2,6),(3,7)
            ]

            ZStack {
                Path { p in
                    for (i, j) in edges {
                        p.move(to: projected[i])
                        p.addLine(to: projected[j])
                    }
                }
                .stroke(style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round))

                ForEach(0..<projected.count, id: \.self) { idx in
                    Circle()
                        .fill(markerColor)
                        .frame(width: strokeW * 1.4, height: strokeW * 1.4)
                        .position(projected[idx])
                }
            }
        }
    }
}

// 5. Thermal Convection Rising Bubble Mark
struct ThermalBubbleMark: View {
    let frame: Int
    var markerColor: Color = Tokens.accent

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            let strokeW = max(1.3, s * 0.065)
            let phase = Double(frame) / 24.0

            let bubbles: [(x: CGFloat, speed: Double, offset: Double, r: CGFloat)] = [
                (0.32, 1.0, 0.0, 0.12),
                (0.68, 1.3, 0.35, 0.10),
                (0.48, 0.8, 0.65, 0.14),
                (0.22, 1.1, 0.85, 0.08)
            ]

            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: s * 0.15, y: s * 0.85))
                    p.addLine(to: CGPoint(x: s * 0.15, y: s * 0.22))
                    p.addCurve(to: CGPoint(x: s * 0.85, y: s * 0.22),
                               control1: CGPoint(x: s * 0.15, y: s * 0.12),
                               control2: CGPoint(x: s * 0.85, y: s * 0.12))
                    p.addLine(to: CGPoint(x: s * 0.85, y: s * 0.85))
                    p.closeSubpath()
                }
                .stroke(style: StrokeStyle(lineWidth: strokeW * 0.8, lineCap: .round))
                .opacity(0.35)

                ForEach(0..<bubbles.count, id: \.self) { idx in
                    let b = bubbles[idx]
                    let progress = (phase * b.speed + b.offset).truncatingRemainder(dividingBy: 1.0)
                    let by = s * 0.82 - progress * (s * 0.62)
                    let bx = s * b.x + sin(progress * .pi * 2.0) * (s * 0.04)
                    let opacity = sin(progress * .pi)

                    Circle()
                        .fill(markerColor)
                        .frame(width: s * b.r * 2.0, height: s * b.r * 2.0)
                        .opacity(opacity * 0.95)
                        .position(x: bx, y: by)
                }
            }
        }
    }
}

// 6. Logic Equalizer Mark
struct EqualizerMark: View {
    let frame: Int
    var markerColor: Color = Tokens.accent

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            let barWidth = max(2.0, s * 0.14)
            let gap = max(1.5, s * 0.08)
            let totalW = barWidth * 4 + gap * 3
            let startX = (s - totalW) / 2
            let maxH = s * 0.72
            let baseY = s * 0.86
            let phase = Double(frame) / 24.0

            let freqs = [3.0, 5.0, 2.0, 4.0]
            let offsets = [0.0, 0.4, 0.8, 0.2]

            ZStack {
                // Baseline track
                Path { p in
                    p.move(to: CGPoint(x: startX - gap * 0.5, y: baseY + 1.5))
                    p.addLine(to: CGPoint(x: startX + totalW + gap * 0.5, y: baseY + 1.5))
                }
                .stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                .opacity(0.30)

                // 4 Bouncing Bars
                ForEach(0..<4, id: \.self) { i in
                    let x = startX + CGFloat(i) * (barWidth + gap)
                    let wave = abs(sin((phase * freqs[i] + offsets[i]) * .pi * 2.0))
                    let hFactor = max(0.20, min(1.0, 0.25 + wave * 0.75))
                    let h = max(barWidth, maxH * hFactor)
                    let y = baseY - h

                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(markerColor)
                        .frame(width: barWidth, height: h)
                        .position(x: x + barWidth / 2, y: y + h / 2)
                }
            }
        }
    }
}

// Unified Dynamic MenuBar Icon Dispatcher
struct DynamicMenuBarIconMark: View {
    let style: MenuBarIconStyle
    let frame: Int
    var markerColor: Color = Tokens.accent

    init(style: MenuBarIconStyle, frame: Int, markerColor: Color = Tokens.accent) {
        self.style = style
        self.frame = frame
        self.markerColor = markerColor
    }

    var body: some View {
        switch style {
        case .turbine: TurbineMark(frame: frame, markerColor: markerColor)
        case .pulseWave: PulseWaveMark(frame: frame, markerColor: markerColor)
        case .vuMeter: VUMeterMark(frame: frame, markerColor: markerColor)
        case .cube3D: Cube3DMark(frame: frame, markerColor: markerColor)
        case .thermalBubble: ThermalBubbleMark(frame: frame, markerColor: markerColor)
        case .equalizer: EqualizerMark(frame: frame, markerColor: markerColor)
        }
    }
}

/// Header status dot: 6px, pulsing opacity 1↔0.35 over 2.4s
/// (`@keyframes wapulse`, prototype lines 16–17). Honors Reduce Motion.
struct StatusDot: View {
    let color: Color
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(dim ? 0.35 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: dim)
            .onAppear { if !reduceMotion { dim = true } }
    }
}

/// Drag handle shown in edit mode (prototype line 80 — 2×3 dots, `c.faint`).
/// Visual only here; the actual drag-reorder is issue 12.
struct GripGlyph: View {
    @Environment(\.tokens) private var t

    var body: some View {
        VStack(spacing: 3.5) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 3.5) {
                    Circle().frame(width: 2.4, height: 2.4)
                    Circle().frame(width: 2.4, height: 2.4)
                }
            }
        }
        .foregroundStyle(t.faint)
    }
}
