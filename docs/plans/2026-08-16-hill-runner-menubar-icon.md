# Dynamic Hill Runner MenuBar Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the "Hill Runner (경사로 러너)" dynamic menu bar icon theme (`case hillRunner = "hillRunner"`) reacting to workload from 0% to 100% across 3 distinct continuous locomotion tiers (Uphill plod, Flat jog, Downhill sprint) with 2-link IK legs and Cheek-to-Pocket arm kinematics.

**Architecture:** 
- Extend `MenuBarIconStyle` with `case hillRunner = "hillRunner"` (24 frames total, static frame 8).
- Update `KineticNotchMotion.displayedFrame` to calculate the 24-frame index mapped across 3 workload tiers (0~25% Uphill: frames 0..7, 25~65% Flat: frames 8..15, 65~100% Downhill: frames 16..23) with continuous phase stepping.
- Implement `HillRunnerMark` in `Glyphs.swift` as a pure vector SwiftUI `View` rendering an articulated stick figure with constant-bone-length 2-link leg IK and Cheek-to-Pocket anti-phase arms.
- Update `DynamicMenuBarIconMark` dispatcher and expand test suites in `WattlyTests/` to verify rendering and motion across all frames.

**Tech Stack:** Swift 6.0, SwiftUI, AppKit (NSImage template rasterization), Swift Testing (`@Test`, `#expect`), XcodeGen.

## Global Constraints

- Platform deployment target: macOS 14.0+
- Architecture: Apple Silicon (`arm64`)
- Language: Swift 6.0 with strict concurrency
- Zero non-standard external dependencies (Pure SwiftUI / AppKit)
- Template NSImages must set `isTemplate = true` and support light/dark status bar tinting
- All tests must pass with `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData`

---

### Task 1: Data Model Expansion for `MenuBarIconStyle.hillRunner`

**Files:**
- Modify: `Wattly/Core/MenuBarIconStyle.swift:3-55`
- Test: `WattlyTests/MenuBarIconStyleTests.swift:1-35`

**Interfaces:**
- Consumes: None
- Produces: 
  - `MenuBarIconStyle.hillRunner`
  - `MenuBarIconStyle.label`: `"러너 (경사로 질주)"`
  - `MenuBarIconStyle.category`: `"캐릭터 / 라이프"`
  - `MenuBarIconStyle.summary`: `"부하(0%~100%)에 따라 오르막 힘겨운 걸음 → 평지 조깅 → 내리막 폭풍 질주로 지형 경사와 캐릭터 자세가 연속 전환됩니다."`
  - `MenuBarIconStyle.frameCount`: `24`
  - `MenuBarIconStyle.staticFrame`: `8`

- [ ] **Step 1: Write failing unit test for `MenuBarIconStyle.hillRunner`**

Update `WattlyTests/MenuBarIconStyleTests.swift`:
```swift
import Testing
import Foundation
@testable import Wattly

struct MenuBarIconStyleTests {
    @Test func allIconStylesHaveValidMetadataAndFrameCounts() {
        let styles = MenuBarIconStyle.allCases
        #expect(styles.count == 7) // 6 existing + 1 hillRunner
        for style in styles {
            #expect(!style.id.isEmpty)
            #expect(!style.label.isEmpty)
            #expect(!style.category.isEmpty)
            #expect(!style.summary.isEmpty)
            #expect(style.frameCount >= 4)
            #expect(style.staticFrame >= 0 && style.staticFrame < style.frameCount)
        }
    }

    @Test func hillRunnerHasSpecificMetadata() {
        let runner = MenuBarIconStyle.hillRunner
        #expect(runner.rawValue == "hillRunner")
        #expect(runner.label == "러너 (경사로 질주)")
        #expect(runner.category == "캐릭터 / 라이프")
        #expect(runner.frameCount == 24)
        #expect(runner.staticFrame == 8)
    }

    @Test func defaultIconStyleIsCoolingTurbine() {
        #expect(Defaults.menubarIconStyle == .turbine)
        #expect(StorageKey.menubarIconStyle == "menubarIconStyle")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodegen generate
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/MenuBarIconStyleTests
```
Expected: FAIL with compilation error (`hillRunner` not defined on `MenuBarIconStyle`).

- [ ] **Step 3: Implement `MenuBarIconStyle.hillRunner`**

Modify `Wattly/Core/MenuBarIconStyle.swift`:
```swift
import Foundation

public enum MenuBarIconStyle: String, CaseIterable, Identifiable, Sendable {
    case turbine = "turbine"             // 1. 쿨링 터빈
    case pulseWave = "pulseWave"         // 2. 흐르는 펄스 W 파형
    case vuMeter = "vuMeter"             // 3. VU 파워 미터
    case cube3D = "cube3D"               // 4. 3D 와이어프레임 큐브
    case thermalBubble = "thermalBubble" // 5. 열 대류 버블
    case equalizer = "equalizer"         // 6. 디지털 이퀄라이저
    case hillRunner = "hillRunner"       // 7. 경사로 러너 (Hill Runner)

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .turbine: "쿨링 터빈"
        case .pulseWave: "펄스 웨이브"
        case .vuMeter: "VU 파워 미터"
        case .cube3D: "3D 큐브"
        case .thermalBubble: "열 대류 버블"
        case .equalizer: "디지털 이퀄라이저"
        case .hillRunner: "러너 (경사로 질주)"
        }
    }

    public var category: String {
        switch self {
        case .turbine: "쿨링 / 팬"
        case .pulseWave: "전력 / 신호"
        case .vuMeter: "정밀 계측기"
        case .cube3D: "3D 기하학"
        case .thermalBubble: "열역학"
        case .equalizer: "디지털 스펙트럼"
        case .hillRunner: "캐릭터 / 라이프"
        }
    }

    public var summary: String {
        switch self {
        case .turbine: "맥북 쿨링 팬 블레이드가 부하에 맞춰 고속 회전합니다."
        case .pulseWave: "Wattly 시그니처 W 파형이 좌에서 우로 전파되며 전력 부하에 따라 가속됩니다."
        case .vuMeter: "아날로그 전력 계측기 바늘이 전력량에 맞춰 기민하게 스윙합니다."
        case .cube3D: "3차원 대각선 축을 기준으로 와이어프레임 큐브가 자전합니다."
        case .thermalBubble: "하단에서 상단으로 열 배출 기포 파티클이 상승합니다."
        case .equalizer: "4개의 수직 디지털 바가 연산 및 전력 부하에 맞춰 상하 바운스합니다."
        case .hillRunner: "부하(0%~100%)에 따라 오르막 힘겨운 걸음 → 평지 조깅 → 내리막 폭풍 질주로 지형 경사와 캐릭터 자세가 연속 전환됩니다."
        }
    }

    public var frameCount: Int {
        switch self {
        case .turbine, .pulseWave, .vuMeter, .cube3D, .thermalBubble, .equalizer, .hillRunner:
            return 24
        }
    }

    public var staticFrame: Int {
        switch self {
        case .hillRunner:
            return 8
        default:
            return 0
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/MenuBarIconStyleTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/MenuBarIconStyle.swift WattlyTests/MenuBarIconStyleTests.swift
git commit -m "feat: add hillRunner case to MenuBarIconStyle"
```

---

### Task 2: Kinematic Motion & Tiered Frame Mapping for `MenuBarIconStyle.hillRunner`

**Files:**
- Modify: `Wattly/Core/KineticNotchMotion.swift:208-250`
- Test: `WattlyTests/KineticNotchMotionTests.swift:130-185`

**Interfaces:**
- Consumes: `MenuBarIconStyle.hillRunner`
- Produces: `MenuBarIconMotion.displayedFrame(style:phase:load:reduceMotion:)` supporting `.hillRunner`

- [ ] **Step 1: Write failing unit test for `displayedFrame` with `.hillRunner`**

Add tests to `WattlyTests/KineticNotchMotionTests.swift`:
```swift
    @Test func hillRunnerMapsLoadTiersCorrectly() {
        // Low load (0~24%) -> Tier 0 (Frames 0..7)
        let lowFrame = MenuBarIconMotion.displayedFrame(style: .hillRunner, phase: 0.5, load: 10.0, reduceMotion: false)
        #expect(lowFrame >= 0 && lowFrame <= 7)

        // Mid load (25~64%) -> Tier 1 (Frames 8..15)
        let midFrame = MenuBarIconMotion.displayedFrame(style: .hillRunner, phase: 0.5, load: 45.0, reduceMotion: false)
        #expect(midFrame >= 8 && midFrame <= 15)

        // High load (65~100%) -> Tier 2 (Frames 16..23)
        let highFrame = MenuBarIconMotion.displayedFrame(style: .hillRunner, phase: 0.5, load: 85.0, reduceMotion: false)
        #expect(highFrame >= 16 && highFrame <= 23)
    }

    @Test func hillRunnerStaticFrameHonorsReduceMotion() {
        let frame = MenuBarIconMotion.displayedFrame(style: .hillRunner, phase: 0.5, load: 90.0, reduceMotion: true)
        #expect(frame == 8)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/KineticNotchMotionTests
```
Expected: FAIL.

- [ ] **Step 3: Implement `displayedFrame` mapping for `.hillRunner`**

Modify `Wattly/Core/KineticNotchMotion.swift`:
```swift
        // Hill Runner maps 3 workload tiers (Low Uphill, Mid Flat, High Downhill) into 8 subphases each
        if style == .hillRunner {
            let clampedLoad = min(max(activeLoad, 0), 100)
            let tier: Int
            if clampedLoad < 25.0 {
                tier = 0 // 저부하: 오르막 (Frames 0..7)
            } else if clampedLoad < 65.0 {
                tier = 1 // 중부하: 평지 (Frames 8..15)
            } else {
                tier = 2 // 고부하: 내리막 질주 (Frames 16..23)
            }
            let subPhase = Int(safePhase * 8.0) % 8
            return tier * 8 + subPhase
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/KineticNotchMotionTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/KineticNotchMotion.swift WattlyTests/KineticNotchMotionTests.swift
git commit -m "feat: add hillRunner frame calculation to KineticNotchMotion"
```

---

### Task 3: Vector Graphic & Kinematic Articulation in `Glyphs.swift`

**Files:**
- Modify: `Wattly/DesignSystem/Glyphs.swift:360-400`
- Test: `WattlyTests/GlyphsRenderingTests.swift:1-40`

**Interfaces:**
- Consumes: `MenuBarIconStyle.hillRunner`, `Tokens.accent`
- Produces: `struct HillRunnerMark: View`, integration into `DynamicMenuBarIconMark`

- [ ] **Step 1: Write failing test for HillRunnerMark rendering across all 24 frames**

Update `WattlyTests/GlyphsRenderingTests.swift`:
```swift
    @Test func allDynamicMenuBarIconsRenderWithoutCrashing() {
        for style in MenuBarIconStyle.allCases {
            for frame in 0..<style.frameCount {
                let view = DynamicMenuBarIconMark(style: style, frame: frame)
                #expect(view.style == style)
                #expect(view.frame == frame)
            }
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/GlyphsRenderingTests
```
Expected: FAIL (missing `case .hillRunner` in `DynamicMenuBarIconMark`).

- [ ] **Step 3: Implement `HillRunnerMark` in `Glyphs.swift`**

Add `HillRunnerMark` and update `DynamicMenuBarIconMark` in `Wattly/DesignSystem/Glyphs.swift`:
```swift
// 7. Dynamic Hill Runner Mark (2-Link IK Legs & Cheek-to-Pocket Arms)
struct HillRunnerMark: View {
    let frame: Int
    var markerColor: Color = Tokens.accent

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            let strokeW = max(1.4, s * 0.08)
            let headR = s * 0.095

            let clampedFrame = min(max(frame, 0), 23)
            let tier = clampedFrame / 8 // 0: Uphill, 1: Flat, 2: Downhill
            let subPhase = Double(clampedFrame % 8) / 8.0

            // Tier parameters
            let t: Double = switch tier {
            case 0: 0.10 // Uphill
            case 1: 0.50 // Flat
            default: 0.90 // Downhill
            }

            // 1. Ground Slope
            let gX1 = s * 0.08, gX2 = s * 0.92
            let gY1 = s * (0.88 - t * 0.30)
            let gY2 = s * (0.62 + t * 0.28)
            let groundSlope = (gY2 - gY1) / (gX2 - gX1)
            let groundAtHip = gY1 + (s * 0.46 - gX1) * groundSlope

            // 2. Hip Position
            let hipX = s * 0.46
            let p = subPhase * .pi * 2.0
            let u1 = subPhase
            let u2 = (subPhase + 0.5).truncatingRemainder(dividingBy: 1.0)
            let bob = abs(sin(p * 2.0)) * s * (0.02 + t * 0.04)
            let hipY = groundAtHip - s * (0.24 - t * 0.02) - bob

            // 3. Torso & Head
            let leanAngle = (0.24 - (1.0 - abs(t - 0.5) * 2.0) * 0.12 + (t > 0.5 ? (t - 0.5) * 0.38 : 0.0)) * .pi
            let torsoLen = s * 0.22
            let neckX = hipX + sin(leanAngle) * torsoLen
            let neckY = hipY - cos(leanAngle) * torsoLen

            let headAngle = leanAngle * 0.65
            let headX = neckX + sin(headAngle) * (s * 0.09)
            let headY = neckY - cos(headAngle) * (s * 0.09)

            // 4. Leg Kinematics (2-Link Constant Bone Length IK)
            let strideScale = s * (0.13 + t * 0.09)
            let liftScale = s * (0.05 + t * 0.09)
            let frenzy = max(0.0, (t - 0.60) / 0.40)

            let foot1 = calcFoot(u: u1, hipX: hipX, hipY: hipY, p: p, phaseOffset: 0.6, strideScale: strideScale, liftScale: liftScale, frenzy: frenzy, s: s, gX1: gX1, gY1: gY1, groundSlope: groundSlope)
            let foot2 = calcFoot(u: u2, hipX: hipX, hipY: hipY, p: p, phaseOffset: .pi + 0.6, strideScale: strideScale, liftScale: liftScale, frenzy: frenzy, s: s, gX1: gX1, gY1: gY1, groundSlope: groundSlope)

            let L1 = s * 0.13, L2 = s * 0.13
            let leg1 = solveLegIK(hx: hipX, hy: hipY, fx: foot1.x, fy: foot1.y, L1: L1, L2: L2)
            let leg2 = solveLegIK(hx: hipX, hy: hipY, fx: foot2.x, fy: foot2.y, L1: L1, L2: L2)

            // 5. Arm Kinematics (Cheek-to-Pocket Anti-Phase)
            let A1 = s * 0.14, A2 = s * 0.13
            let arm1 = calcArm(isFront: true, u: u2, neckX: neckX, neckY: neckY, t: t, p: p, frenzy: frenzy, A1: A1, A2: A2, s: s)
            let arm2 = calcArm(isFront: false, u: u1, neckX: neckX, neckY: neckY, t: t, p: p, frenzy: frenzy, A1: A1, A2: A2, s: s)

            ZStack {
                // Ground slope line
                Path { path in
                    path.move(to: CGPoint(x: gX1, y: gY1))
                    path.addLine(to: CGPoint(x: gX2, y: gY2))
                }
                .stroke(style: StrokeStyle(lineWidth: max(1.0, strokeW * 0.7), lineCap: .round))
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
                    path.move(to: CGPoint(x: arm2.shX, y: arm2.shY))
                    path.addLine(to: CGPoint(x: arm2.ex, y: arm2.ey))
                    path.addLine(to: CGPoint(x: arm2.hx, y: arm2.hy))
                }
                .stroke(style: StrokeStyle(lineWidth: strokeW * 0.85, lineCap: .round, lineJoin: .round))
                .opacity(0.50)

                // Back Leg
                Path { path in
                    path.move(to: CGPoint(x: hipX, y: hipY))
                    path.addLine(to: CGPoint(x: leg2.kx, y: leg2.ky))
                    path.addLine(to: CGPoint(x: leg2.fx, y: leg2.fy))
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
                    path.addLine(to: CGPoint(x: leg1.kx, y: leg1.ky))
                    path.addLine(to: CGPoint(x: leg1.fx, y: leg1.fy))
                }
                .stroke(markerColor, style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round))

                // Front Arm
                Path { path in
                    path.move(to: CGPoint(x: arm1.shX, y: arm1.shY))
                    path.addLine(to: CGPoint(x: arm1.ex, y: arm1.ey))
                    path.addLine(to: CGPoint(x: arm1.hx, y: arm1.hy))
                }
                .stroke(markerColor, style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func calcFoot(u: Double, hipX: CGFloat, hipY: CGFloat, p: Double, phaseOffset: Double, strideScale: CGFloat, liftScale: CGFloat, frenzy: Double, s: CGFloat, gX1: CGFloat, gY1: CGFloat, groundSlope: CGFloat) -> CGPoint {
        var fx: CGFloat
        var fy: CGFloat
        if u < 0.45 {
            let xi = u / 0.45
            fx = hipX + strideScale * (1.0 - 2.0 * xi)
            fy = gY1 + (fx - gX1) * groundSlope
        } else {
            let eta = (u - 0.45) / 0.55
            fx = hipX - strideScale * cos(.pi * eta)
            fy = (gY1 + (fx - gX1) * groundSlope) - liftScale * sin(.pi * eta)
        }

        if frenzy > 0 {
            let circX = hipX + cos(p + phaseOffset) * (s * 0.20)
            let circY = hipY + sin(p + phaseOffset) * (s * 0.20) + s * 0.06
            fx = fx * (1.0 - frenzy) + circX * frenzy
            fy = fy * (1.0 - frenzy) + circY * frenzy
        }
        return CGPoint(x: fx, y: fy)
    }

    private func solveLegIK(hx: CGFloat, hy: CGFloat, fx: CGFloat, fy: CGFloat, L1: CGFloat, L2: CGFloat) -> (kx: CGFloat, ky: CGFloat, fx: CGFloat, fy: CGFloat) {
        let dx = fx - hx
        let dy = fy - hy
        let dist = min(max(sqrt(dx * dx + dy * dy), 0.01), (L1 + L2) * 0.999)
        let baseAngle = atan2(dy, dx)
        let cosAlpha = (L1 * L1 + dist * dist - L2 * L2) / (2 * L1 * dist)
        let alpha = acos(min(max(cosAlpha, -1.0), 1.0))
        let kneeAngle = baseAngle - alpha
        let kx = hx + cos(kneeAngle) * L1
        let ky = hy + sin(kneeAngle) * L1
        return (kx, ky, fx, fy)
    }

    private func calcArm(isFront: Bool, u: Double, neckX: CGFloat, neckY: CGFloat, t: Double, p: Double, frenzy: Double, A1: CGFloat, A2: CGFloat, s: CGFloat) -> (shX: CGFloat, shY: CGFloat, ex: CGFloat, ey: CGFloat, hx: CGFloat, hy: CGFloat) {
        let shX = neckX + (isFront ? s * 0.02 : -s * 0.02)
        let shY = neckY + (isFront ? s * 0.02 : 0.0)
        let swing = sin(u * .pi * 2.0)

        var upperAngle: Double
        var forearmAngle: Double
        if swing >= 0 {
            let prog = swing
            upperAngle = 1.30 - prog * 0.85
            forearmAngle = upperAngle - (1.15 + prog * 0.35)
        } else {
            let prog = -swing
            upperAngle = 1.30 + prog * 1.35
            forearmAngle = upperAngle - (1.70 - prog * 0.15)
        }

        var ex = shX + cos(upperAngle) * A1
        var ey = shY + sin(upperAngle) * A1
        var hx = ex + cos(forearmAngle) * A2
        var hy = ey + sin(forearmAngle) * A2

        if frenzy > 0 {
            let flailPhase = p + (isFront ? 0.0 : .pi)
            let flailUpperAngle = 0.4 - cos(flailPhase) * 1.6
            let flailForearmAngle = flailUpperAngle - 1.1 + sin(flailPhase) * 0.4

            let fex = shX + cos(flailUpperAngle) * A1
            let fey = shY + sin(flailUpperAngle) * A1
            let fhx = fex + cos(flailForearmAngle) * A2
            let fhy = fey - sin(flailForearmAngle) * A2

            ex = ex * (1.0 - frenzy) + fex * frenzy
            ey = ey * (1.0 - frenzy) + fey * frenzy
            hx = hx * (1.0 - frenzy) + fhx * frenzy
            hy = hy * (1.0 - frenzy) + fhy * frenzy
        }

        return (shX, shY, ex, ey, hx, hy)
    }
}
```

- [ ] **Step 4: Connect `case .hillRunner` to `DynamicMenuBarIconMark`**

```swift
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
```

- [ ] **Step 5: Run tests to verify all 24 frames render cleanly**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/GlyphsRenderingTests
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Wattly/DesignSystem/Glyphs.swift WattlyTests/GlyphsRenderingTests.swift
git commit -m "feat: implement HillRunnerMark vector drawing in Glyphs"
```

---

### Task 4: Integration Verification & Full Test Suite Execution

**Files:**
- Test: `WattlyTests/MenuBarGlyphTests.swift`
- Test: `WattlyTests/SettingsMenuBarIconSectionTests.swift`
- Test: Full Test Suite

- [ ] **Step 1: Run full test suite to verify 0 regressions across entire codebase**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData
```
Expected: PASS (All test suites pass).

- [ ] **Step 2: Commit plan document**

```bash
git add docs/plans/2026-08-16-hill-runner-menubar-icon.md
git commit -m "docs: add implementation plan for hillRunner dynamic icon"
```
