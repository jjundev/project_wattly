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
