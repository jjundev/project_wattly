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

struct FluxLoopOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = min(rect.width, rect.height) * 0.10
        let track = rect.insetBy(dx: inset, dy: inset)
        return Path(roundedRect: track, cornerRadius: track.height * 0.36)
    }
}

struct FluxLoopCore: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        path.move(to: point(0.27, 0.31))
        path.addLine(to: point(0.41, 0.71))
        path.addLine(to: point(0.50, 0.47))
        path.addLine(to: point(0.59, 0.71))
        path.addLine(to: point(0.73, 0.31))
        return path
    }
}

/// A seven-frame energy loop. The active charge pauses at the lateral extremes
/// through KineticNotchMotion's phase delays; this view itself is a static frame.
struct FluxLoopMark: View {
    let frame: Int
    var markerColor: Color = Tokens.accent

    private static let chargePositions = [
        CGPoint(x: 0.50, y: 0.10), CGPoint(x: 0.79, y: 0.20),
        // Phase 2 is KineticNotchMotion.rightEdgePhase.
        CGPoint(x: 0.90, y: 0.50), CGPoint(x: 0.70, y: 0.84),
        CGPoint(x: 0.30, y: 0.84),
        // Phase 5 is KineticNotchMotion.leftEdgePhase.
        CGPoint(x: 0.10, y: 0.50),
        CGPoint(x: 0.21, y: 0.20)
    ]

    private var chargePosition: CGPoint {
        Self.chargePositions[min(max(frame, 0), Self.chargePositions.count - 1)]
    }

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height) * 0.22
            ZStack {
                FluxLoopOutline()
                    .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                FluxLoopCore()
                    .stroke(style: StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round))
                Circle()
                    .fill(markerColor)
                    .frame(width: diameter, height: diameter)
                    .position(x: proxy.size.width * chargePosition.x,
                              y: proxy.size.height * chargePosition.y)
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
            let strokeW = max(1.2, s * 0.08)
            let angle = Double(frame) * (360.0 / 6.0)

            ZStack {
                Circle()
                    .stroke(style: StrokeStyle(lineWidth: strokeW * 0.75))
                    .opacity(0.35)
                    .frame(width: s * 0.88, height: s * 0.88)
                    .position(center)

                ZStack {
                    ForEach([0.0, 90.0, 180.0, 270.0], id: \.self) { a in
                        Path { p in
                            p.move(to: CGPoint(x: center.x, y: center.y - s * 0.10))
                            p.addQuadCurve(to: CGPoint(x: center.x + s * 0.28, y: center.y - s * 0.28),
                                           control: CGPoint(x: center.x + s * 0.22, y: center.y - s * 0.08))
                            p.addLine(to: CGPoint(x: center.x + s * 0.18, y: center.y - s * 0.38))
                            p.addQuadCurve(to: CGPoint(x: center.x, y: center.y - s * 0.10),
                                           control: CGPoint(x: center.x + s * 0.10, y: center.y - s * 0.22))
                        }
                        .fill(markerColor)
                        .rotationEffect(.degrees(a), anchor: .center)
                    }

                    Circle()
                        .fill(markerColor)
                        .frame(width: s * 0.24, height: s * 0.24)
                        .position(center)
                }
                .rotationEffect(.degrees(angle), anchor: .center)
            }
        }
    }
}

// 2. Dual Interlocking Gears Mark
struct GearsMark: View {
    let frame: Int
    var markerColor: Color = Tokens.accent

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            let r1 = s * 0.26
            let r2 = s * 0.16
            let c1 = CGPoint(x: s * 0.38, y: s * 0.42)
            let c2 = CGPoint(x: s * 0.74, y: s * 0.68)
            let strokeW = max(1.2, s * 0.06)
            let rot = Double(frame) / 8.0

            ZStack {
                // Gear 1
                ZStack {
                    Circle().stroke(lineWidth: strokeW).frame(width: r1 * 1.5, height: r1 * 1.5).position(c1)
                    Circle().fill(markerColor).frame(width: r1 * 0.5, height: r1 * 0.5).position(c1)
                    ForEach(0..<8, id: \.self) { i in
                        Rectangle()
                            .fill(markerColor)
                            .frame(width: strokeW * 1.8, height: r1 * 0.35)
                            .position(x: c1.x, y: c1.y - r1)
                            .rotationEffect(.degrees(Double(i) * 45.0), anchor: .center)
                    }
                }
                .rotationEffect(.degrees(rot * 360.0), anchor: UnitPoint(x: c1.x / proxy.size.width, y: c1.y / proxy.size.height))

                // Gear 2
                ZStack {
                    Circle().stroke(lineWidth: strokeW).frame(width: r2 * 1.4, height: r2 * 1.4).position(c2)
                    Circle().fill(markerColor).frame(width: r2 * 0.5, height: r2 * 0.5).position(c2)
                    ForEach(0..<6, id: \.self) { i in
                        Rectangle()
                            .fill(markerColor)
                            .frame(width: strokeW * 1.5, height: r2 * 0.35)
                            .position(x: c2.x, y: c2.y - r2)
                            .rotationEffect(.degrees(Double(i) * 60.0), anchor: .center)
                    }
                }
                .rotationEffect(.degrees(-rot * 360.0 * 1.6 + 15.0), anchor: UnitPoint(x: c2.x / proxy.size.width, y: c2.y / proxy.size.height))
            }
        }
    }
}

// 3. Flowing Pulse W Waveform Mark
struct PulseWaveMark: View {
    let frame: Int
    var markerColor: Color = Tokens.accent

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            let strokeW = max(1.5, s * 0.08)
            let centerY = s * 0.52
            let phase = Double(frame) / 8.0

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

// 4. Atomic Orbit Mark
struct AtomicOrbitMark: View {
    let frame: Int
    var markerColor: Color = Tokens.accent

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            let c = CGPoint(x: s / 2, y: s / 2)
            let rx = s * 0.42
            let ry = s * 0.17
            let strokeW = max(1.2, s * 0.07)
            let angle = Double(frame) / 8.0 * .pi * 2.0

            ZStack {
                // Orbit 1
                ZStack {
                    Ellipse()
                        .stroke(lineWidth: strokeW * 0.75)
                        .opacity(0.35)
                        .frame(width: rx * 2, height: ry * 2)
                    Circle()
                        .fill(markerColor)
                        .frame(width: strokeW * 2.2, height: strokeW * 2.2)
                        .position(x: rx + cos(angle) * rx, y: ry + sin(angle) * ry)
                }
                .rotationEffect(.degrees(35))
                .position(c)

                // Orbit 2
                ZStack {
                    Ellipse()
                        .stroke(lineWidth: strokeW * 0.75)
                        .opacity(0.35)
                        .frame(width: rx * 2, height: ry * 2)
                    Circle()
                        .fill(markerColor)
                        .frame(width: strokeW * 2.2, height: strokeW * 2.2)
                        .position(x: rx + cos(-angle * 1.3 + .pi) * rx, y: ry + sin(-angle * 1.3 + .pi) * ry)
                }
                .rotationEffect(.degrees(-35))
                .position(c)

                Circle()
                    .fill(markerColor)
                    .frame(width: s * 0.20, height: s * 0.20)
                    .position(c)
            }
        }
    }
}

// 5. Isometric Rotating 3D Cube Mark
struct Cube3DMark: View {
    let frame: Int
    var markerColor: Color = Tokens.accent

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            let c = CGPoint(x: s / 2, y: s / 2)
            let r = s * 0.32
            let strokeW = max(1.2, s * 0.075)
            let angle = Double(frame) / 12.0 * .pi * 2.0
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
                        .frame(width: strokeW * 1.5, height: strokeW * 1.5)
                        .position(projected[idx])
                }
            }
        }
    }
}

// 6. Infinity Loop Mark
struct InfinityLoopMark: View {
    let frame: Int
    var markerColor: Color = Tokens.accent

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            let c = CGPoint(x: s / 2, y: s / 2)
            let strokeW = max(1.4, s * 0.08)
            let t = Double(frame) / 8.0 * .pi * 2.0
            let scale = s * 0.40
            let denom = 1.0 + sin(t) * sin(t)
            let px = c.x + (scale * cos(t)) / denom
            let py = c.y + (scale * sin(t) * cos(t)) / denom

            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: c.x - s * 0.35, y: c.y))
                    p.addCurve(to: CGPoint(x: c.x, y: c.y),
                               control1: CGPoint(x: c.x - s * 0.35, y: c.y - s * 0.25),
                               control2: CGPoint(x: c.x, y: c.y - s * 0.25))
                    p.addCurve(to: CGPoint(x: c.x + s * 0.35, y: c.y),
                               control1: CGPoint(x: c.x + s * 0.25, y: c.y + s * 0.25),
                               control2: CGPoint(x: c.x + s * 0.35, y: c.y + s * 0.25))
                    p.addCurve(to: CGPoint(x: c.x, y: c.y),
                               control1: CGPoint(x: c.x + s * 0.35, y: c.y - s * 0.25),
                               control2: CGPoint(x: c.x, y: c.y - s * 0.25))
                    p.addCurve(to: CGPoint(x: c.x - s * 0.35, y: c.y),
                               control1: CGPoint(x: c.x - s * 0.25, y: c.y + s * 0.25),
                               control2: CGPoint(x: c.x - s * 0.35, y: c.y + s * 0.25))
                }
                .stroke(style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round))
                .opacity(0.35)

                Circle()
                    .fill(markerColor)
                    .frame(width: strokeW * 2.2, height: strokeW * 2.2)
                    .position(x: px, y: py)
            }
        }
    }
}

// 7. Mainframe Tape Reel Mark
struct TapeReelMark: View {
    let frame: Int
    var markerColor: Color = Tokens.accent

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            let r = s * 0.20
            let strokeW = max(1.2, s * 0.065)
            let c1 = CGPoint(x: s * 0.30, y: s * 0.50)
            let c2 = CGPoint(x: s * 0.70, y: s * 0.50)
            let rot = Double(frame) / 6.0 * 360.0

            ZStack {
                RoundedRectangle(cornerRadius: s * 0.08)
                    .stroke(lineWidth: strokeW * 0.75)
                    .opacity(0.3)
                    .frame(width: s * 0.84, height: s * 0.60)
                    .position(x: s * 0.5, y: s * 0.5)

                // Reel 1
                ZStack {
                    Circle().stroke(lineWidth: strokeW).frame(width: r * 2, height: r * 2).position(c1)
                    Circle().fill(markerColor).frame(width: r * 0.6, height: r * 0.6).position(c1)
                    ForEach([0.0, 120.0, 240.0], id: \.self) { a in
                        Rectangle()
                            .fill(markerColor)
                            .frame(width: strokeW * 0.8, height: r * 2)
                            .position(c1)
                            .rotationEffect(.degrees(a))
                    }
                }
                .rotationEffect(.degrees(rot), anchor: UnitPoint(x: c1.x / proxy.size.width, y: c1.y / proxy.size.height))

                // Reel 2
                ZStack {
                    Circle().stroke(lineWidth: strokeW).frame(width: r * 2, height: r * 2).position(c2)
                    Circle().fill(markerColor).frame(width: r * 0.6, height: r * 0.6).position(c2)
                    ForEach([0.0, 120.0, 240.0], id: \.self) { a in
                        Rectangle()
                            .fill(markerColor)
                            .frame(width: strokeW * 0.8, height: r * 2)
                            .position(c2)
                            .rotationEffect(.degrees(a))
                    }
                }
                .rotationEffect(.degrees(rot), anchor: UnitPoint(x: c2.x / proxy.size.width, y: c2.y / proxy.size.height))

                Path { p in
                    p.move(to: CGPoint(x: c1.x, y: c1.y + r))
                    p.addQuadCurve(to: CGPoint(x: c2.x, y: c2.y + r), control: CGPoint(x: s * 0.5, y: s * 0.72))
                }
                .stroke(style: StrokeStyle(lineWidth: strokeW, lineCap: .round))
            }
        }
    }
}

// 8. Thermal Convection Bubble Mark
struct ThermalBubbleMark: View {
    let frame: Int
    var markerColor: Color = Tokens.accent

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            let strokeW = max(1.2, s * 0.065)
            let phase = Double(frame) / 8.0

            let bubbles: [(x: Double, speed: Double, offset: Double, r: Double)] = [
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
                .stroke(style: StrokeStyle(lineWidth: strokeW * 0.8, lineCap: .round, lineJoin: .round))
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
        case .gears: GearsMark(frame: frame, markerColor: markerColor)
        case .pulseWave: PulseWaveMark(frame: frame, markerColor: markerColor)
        case .atomicOrbit: AtomicOrbitMark(frame: frame, markerColor: markerColor)
        case .cube3D: Cube3DMark(frame: frame, markerColor: markerColor)
        case .infinityLoop: InfinityLoopMark(frame: frame, markerColor: markerColor)
        case .tapeReel: TapeReelMark(frame: frame, markerColor: markerColor)
        case .thermalBubble: ThermalBubbleMark(frame: frame, markerColor: markerColor)
        case .fluxLoop: FluxLoopMark(frame: frame, markerColor: markerColor)
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
