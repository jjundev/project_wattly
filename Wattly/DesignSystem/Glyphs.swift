import SwiftUI

/// The Wattly lightning mark — the exact prototype polygon
/// (`points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"`, 24×24 viewBox, line 67),
/// so the brand glyph is pixel-faithful rather than an SF Symbol approximation.
struct LightningGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let pts: [(CGFloat, CGFloat)] = [
            (13, 2), (3, 14), (12, 14), (11, 22), (21, 10), (12, 10), (13, 2),
        ]
        let s = min(rect.width, rect.height) / 24
        var p = Path()
        for (i, pt) in pts.enumerated() {
            let cg = CGPoint(x: rect.minX + pt.0 * s, y: rect.minY + pt.1 * s)
            if i == 0 { p.move(to: cg) } else { p.addLine(to: cg) }
        }
        p.closeSubpath()
        return p
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
