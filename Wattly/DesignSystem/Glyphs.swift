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
            let strokeW = max(1.6, s * 0.09)
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
                .stroke(style: StrokeStyle(lineWidth: max(1.5, strokeW * 0.95), lineCap: .round, lineJoin: .round))
                .opacity(0.70)

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

            let clampedFrame = min(max(frame, 0), 23)
            let tier = clampedFrame / 6
            let tierLoads = [0.15, 0.40, 0.70, 1.00]
            let tierLoad = tierLoads[tier]
            let subPhase = Double(clampedFrame % 6) / 6.0

            let offsets = [0.0, 0.25, 0.50, 0.75]

            ZStack {
                // Baseline track
                Path { p in
                    p.move(to: CGPoint(x: startX - gap * 0.5, y: baseY + 1.5))
                    p.addLine(to: CGPoint(x: startX + totalW + gap * 0.5, y: baseY + 1.5))
                }
                .stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                .opacity(0.30)

                // 4 Bouncing Bars (smooth wave oscillation scaled by workload tier)
                ForEach(0..<4, id: \.self) { i in
                    let x = startX + CGFloat(i) * (barWidth + gap)
                    let wave = (sin((subPhase + offsets[i]) * .pi * 2.0) + 1.0) / 2.0
                    let hFactor = min(1.0, 0.18 + tierLoad * 0.40 + wave * (0.20 + tierLoad * 0.42))
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

// 7. Dynamic Hill Runner Mark (Discrete 8-Keyframe Locomotion Pose Tables)
struct HillRunnerMark: View {
    let frame: Int
    var markerColor: Color = Tokens.accent

    private struct Pose {
        let bob: CGFloat
        let ft: Double; let fk: Double
        let bt: Double; let bk: Double
        let fa: Double; let fab: Double
        let ba: Double; let bab: Double
    }

    private static let poses: [[Pose]] = [
        // Tier 0: Uphill Heavy Walk (0..7)
        [
            // Frame 0: Contact (Lead Heel Strike on Hill)
            Pose(bob:  0.00, ft:  0.38, fk: 0.22, bt: -0.36, bk: 0.32, fa: -0.45, fab: -1.25, ba:  0.40, bab: -1.40),
            // Frame 1: Recoil / Down (Weight Acceptance & Knee Cushion)
            Pose(bob:  0.02, ft:  0.18, fk: 0.65, bt: -0.48, bk: 0.85, fa: -0.55, fab: -1.20, ba:  0.50, bab: -1.45),
            // Frame 2: Passing (Single Support / Foot Clearance)
            Pose(bob: -0.01, ft: -0.08, fk: 0.20, bt:  0.28, bk: 1.10, fa: -0.15, fab: -1.15, ba:  0.15, bab: -1.25),
            // Frame 3: High Point / Up (Uphill Push-Off)
            Pose(bob: -0.03, ft: -0.32, fk: 0.10, bt:  0.38, bk: 0.35, fa:  0.30, fab: -1.35, ba: -0.38, bab: -1.20),
            // Frame 4: Contact Mirror
            Pose(bob:  0.00, ft: -0.36, fk: 0.32, bt:  0.38, bk: 0.22, fa:  0.40, fab: -1.40, ba: -0.45, bab: -1.25),
            // Frame 5: Recoil Mirror
            Pose(bob:  0.02, ft: -0.48, fk: 0.85, bt:  0.18, bk: 0.65, fa:  0.50, fab: -1.45, ba: -0.55, bab: -1.20),
            // Frame 6: Passing Mirror
            Pose(bob: -0.01, ft:  0.28, fk: 1.10, bt: -0.08, bk: 0.20, fa:  0.15, fab: -1.25, ba: -0.15, bab: -1.15),
            // Frame 7: High Point Mirror
            Pose(bob: -0.03, ft:  0.38, fk: 0.35, bt: -0.32, bk: 0.10, fa: -0.38, fab: -1.20, ba:  0.30, bab: -1.35)
        ],
        // Tier 1: Flat Athletic Jog (8..15)
        [
            // Frame 8 (0): Contact (Forward Foot Strike)
            Pose(bob:  0.00, ft:  0.62, fk: 0.32, bt: -0.58, bk: 0.65, fa: -0.75, fab: -1.45, ba:  0.65, bab: -1.55),
            // Frame 9 (1): Compression (Maximum Stance Knee Cushion)
            Pose(bob:  0.04, ft:  0.22, fk: 0.95, bt: -0.75, bk: 1.35, fa: -0.90, fab: -1.40, ba:  0.80, bab: -1.65),
            // Frame 10 (2): Drive / Passing (Explosive Takeoff)
            Pose(bob: -0.02, ft: -0.25, fk: 0.25, bt:  0.52, bk: 1.45, fa: -0.20, fab: -1.35, ba:  0.20, bab: -1.45),
            // Frame 11 (3): Air Apex (Flight Phase Suspension)
            Pose(bob: -0.06, ft: -0.62, fk: 0.45, bt:  0.78, bk: 0.60, fa:  0.65, fab: -1.55, ba: -0.75, bab: -1.45),
            // Frame 12 (4): Contact Mirror
            Pose(bob:  0.00, ft: -0.58, fk: 0.65, bt:  0.62, bk: 0.32, fa:  0.65, fab: -1.55, ba: -0.75, bab: -1.45),
            // Frame 13 (5): Compression Mirror
            Pose(bob:  0.04, ft: -0.75, fk: 1.35, bt:  0.22, bk: 0.95, fa:  0.80, fab: -1.65, ba: -0.90, bab: -1.40),
            // Frame 14 (6): Drive Mirror
            Pose(bob: -0.02, ft:  0.52, fk: 1.45, bt: -0.25, bk: 0.25, fa:  0.20, fab: -1.45, ba: -0.20, bab: -1.35),
            // Frame 15 (7): Air Apex Mirror
            Pose(bob: -0.06, ft:  0.78, fk: 0.60, bt: -0.62, bk: 0.45, fa: -0.75, fab: -1.45, ba:  0.65, bab: -1.55)
        ],
        // Tier 2: Downhill Frantic Sprint (16..23)
        [
            // Frame 16 (0): Wide Touchdown (Downhill Ground Reach)
            Pose(bob:  0.00, ft:  0.88, fk: 0.42, bt: -0.85, bk: 0.85, fa: -1.15, fab: -1.50, ba:  0.95, bab: -1.70),
            // Frame 17 (1): Hard Stomp (Deep Compression & Butt-Kick)
            Pose(bob:  0.05, ft:  0.35, fk: 1.25, bt: -1.10, bk: 1.65, fa: -1.35, fab: -1.45, ba:  1.20, bab: -1.75),
            // Frame 18 (2): Air Launch (High Knee Propulsion)
            Pose(bob: -0.04, ft: -0.45, fk: 0.35, bt:  0.85, bk: 1.75, fa: -0.30, fab: -1.40, ba:  0.30, bab: -1.55),
            // Frame 19 (3): Max Spread (Airborne Sprint Stride)
            Pose(bob: -0.09, ft: -0.95, fk: 0.65, bt:  1.15, bk: 0.75, fa:  0.95, fab: -1.70, ba: -1.15, bab: -1.50),
            // Frame 20 (4): Wide Touchdown Mirror
            Pose(bob:  0.00, ft: -0.85, fk: 0.85, bt:  0.88, bk: 0.42, fa:  0.95, fab: -1.70, ba: -1.15, bab: -1.50),
            // Frame 21 (5): Hard Stomp Mirror
            Pose(bob:  0.05, ft: -1.10, fk: 1.65, bt:  0.35, bk: 1.25, fa:  1.20, fab: -1.75, ba: -1.35, bab: -1.45),
            // Frame 22 (6): Air Launch Mirror
            Pose(bob: -0.04, ft:  0.85, fk: 1.75, bt: -0.45, bk: 0.35, fa:  0.30, fab: -1.55, ba: -0.30, bab: -1.40),
            // Frame 23 (7): Max Spread Mirror
            Pose(bob: -0.09, ft:  1.15, fk: 0.75, bt: -0.95, bk: 0.65, fa: -1.15, fab: -1.50, ba:  0.95, bab: -1.70)
        ]
    ]

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            let strokeW = max(1.4, s * 0.08)
            let headR = s * 0.095

            let clampedFrame = min(max(frame, 0), 23)
            let tier = clampedFrame / 8
            let frameIdx = clampedFrame % 8
            let pose = Self.poses[tier][frameIdx]

            let t: Double = switch tier {
            case 0: 0.15
            case 1: 0.50
            default: 0.85
            }

            // 1. Smooth Rolling Hill Elevation
            let smoothT = t * t * (3.0 - 2.0 * t)
            let gX1 = s * 0.08, gX2 = s * 0.92
            let gMidX = s * 0.50
            let gY1 = s * (0.82 - smoothT * 0.20)
            let gMidY = s * (0.75 - sin(smoothT * .pi) * 0.08 + (smoothT > 0.5 ? (smoothT - 0.5) * 0.10 : 0.0))
            let gY2 = s * (0.70 + smoothT * 0.16)

            let hipX = s * 0.46
            let u = (hipX - gX1) / (gX2 - gX1)
            let groundAtHip = (1.0 - u) * (1.0 - u) * gY1 + 2.0 * (1.0 - u) * u * gMidY + u * u * gY2

            // 2. Hip Position
            let hipY = groundAtHip - s * (0.24 - t * 0.02) + s * pose.bob

            // 3. Torso & Head
            let leanAngle = (0.22 - (1.0 - abs(t - 0.5) * 2.0) * 0.10 + (t > 0.5 ? (t - 0.5) * 0.32 : 0.0)) * .pi
            let torsoLen = s * 0.22
            let neckX = hipX + sin(leanAngle) * torsoLen
            let neckY = hipY - cos(leanAngle) * torsoLen

            let headAngle = leanAngle * 0.65
            let headX = neckX + sin(headAngle) * (s * 0.09)
            let headY = neckY - cos(headAngle) * (s * 0.09)

            // 4. Legs Forward Kinematics
            let L1 = s * 0.13, L2 = s * 0.13
            let fThighAngle = .pi * 0.5 - pose.ft
            let fKneeAngle = fThighAngle + pose.fk
            let fkX = hipX + cos(fThighAngle) * L1
            let fkY = hipY + sin(fThighAngle) * L1
            let ffX = fkX + cos(fKneeAngle) * L2
            let ffY = fkY + sin(fKneeAngle) * L2

            let bThighAngle = .pi * 0.5 - pose.bt
            let bKneeAngle = bThighAngle + pose.bk
            let bkX = hipX + cos(bThighAngle) * L1
            let bkY = hipY + sin(bThighAngle) * L1
            let bfX = bkX + cos(bKneeAngle) * L2
            let bfY = bkY + sin(bKneeAngle) * L2

            // 5. Arms Forward Kinematics
            let A1 = s * 0.13, A2 = s * 0.12
            let fArmUpperAngle = .pi * 0.5 - pose.fa
            let fArmLowerAngle = fArmUpperAngle + pose.fab
            let fshX = neckX + s * 0.02, fshY = neckY + s * 0.02
            let feX = fshX + cos(fArmUpperAngle) * A1
            let feY = fshY + sin(fArmUpperAngle) * A1
            let fhX = feX + cos(fArmLowerAngle) * A2
            let fhY = feY + sin(fArmLowerAngle) * A2

            let bArmUpperAngle = .pi * 0.5 - pose.ba
            let bArmLowerAngle = bArmUpperAngle + pose.bab
            let bshX = neckX - s * 0.02, bshY = neckY
            let beX = bshX + cos(bArmUpperAngle) * A1
            let beY = bshY + sin(bArmUpperAngle) * A1
            let bhX = beX + cos(bArmLowerAngle) * A2
            let bhY = beY + sin(bArmLowerAngle) * A2

            ZStack {
                // Smooth Rolling Hill Curve
                Path { path in
                    path.move(to: CGPoint(x: gX1, y: gY1))
                    path.addQuadCurve(to: CGPoint(x: gX2, y: gY2), control: CGPoint(x: gMidX, y: gMidY))
                }
                .stroke(style: StrokeStyle(lineWidth: max(1.0, strokeW * 0.75), lineCap: .round))
                .opacity(0.45)

                // High speed dash lines (Tier 2 only)
                if tier == 2 {
                    Path { path in
                        path.move(to: CGPoint(x: hipX - s * 0.28, y: hipY - s * 0.16))
                        path.addLine(to: CGPoint(x: hipX - s * 0.08, y: hipY - s * 0.12))
                        path.move(to: CGPoint(x: hipX - s * 0.24, y: hipY + s * 0.02))
                        path.addLine(to: CGPoint(x: hipX - s * 0.06, y: hipY + s * 0.05))
                    }
                    .stroke(style: StrokeStyle(lineWidth: strokeW * 0.7, lineCap: .round))
                    .opacity(0.80)
                }

                // Back Arm
                Path { path in
                    path.move(to: CGPoint(x: bshX, y: bshY))
                    path.addLine(to: CGPoint(x: beX, y: beY))
                    path.addLine(to: CGPoint(x: bhX, y: bhY))
                }
                .stroke(style: StrokeStyle(lineWidth: strokeW * 0.85, lineCap: .round, lineJoin: .round))
                .opacity(0.50)

                // Back Leg
                Path { path in
                    path.move(to: CGPoint(x: hipX, y: hipY))
                    path.addLine(to: CGPoint(x: bkX, y: bkY))
                    path.addLine(to: CGPoint(x: bfX, y: bfY))
                }
                .stroke(style: StrokeStyle(lineWidth: strokeW * 0.85, lineCap: .round, lineJoin: .round))
                .opacity(0.50)

                // Torso Spine
                Path { path in
                    path.move(to: CGPoint(x: hipX, y: hipY))
                    path.addLine(to: CGPoint(x: neckX, y: neckY))
                }
                .stroke(style: StrokeStyle(lineWidth: strokeW, lineCap: .round))

                // Head
                Circle()
                    .frame(width: headR * 2, height: headR * 2)
                    .position(x: headX, y: headY)

                // Front Leg
                Path { path in
                    path.move(to: CGPoint(x: hipX, y: hipY))
                    path.addLine(to: CGPoint(x: fkX, y: fkY))
                    path.addLine(to: CGPoint(x: ffX, y: ffY))
                }
                .stroke(markerColor, style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round))

                // Front Arm
                Path { path in
                    path.move(to: CGPoint(x: fshX, y: fshY))
                    path.addLine(to: CGPoint(x: feX, y: feY))
                    path.addLine(to: CGPoint(x: fhX, y: fhY))
                }
                .stroke(markerColor, style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round))
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
        case .hillRunner: HillRunnerMark(frame: frame, markerColor: markerColor)
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
