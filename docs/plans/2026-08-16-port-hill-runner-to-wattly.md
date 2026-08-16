# Port Hill Runner Dynamic Icon to Wattly Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port and integrate the fully calibrated, upright-postured, 24-frame dynamic Hill Runner (`MenuBarIconStyle.hillRunner`) menu bar icon and settings preview into the Wattly macOS application.

**Architecture:** 
- Extend `MenuBarIconStyle` enum with `.hillRunner` metadata (24 frames, category, labels, summary).
- Map continuous workload phases into 3 distinct biomechanical locomotion tiers (Uphill Walk, Flat Jog, Downhill Sprint) in `KineticNotchMotion` with calibrated $1.4\times$ phase pacing.
- Render dynamic 2-link IK legs, Cheek-to-Pocket rear arm drive, upright posture, and 2nd-order Bézier rolling hill terrain via `HillRunnerMark` SwiftUI vector view in `Glyphs.swift`.
- Integrate into `MenuBarGlyph` for menu bar status item rendering and `SettingsMenuBarSection` for live settings preview.

**Tech Stack:** Swift 6.0, SwiftUI, AppKit (`NSImage`, `ImageRenderer`), Swift Testing (`import Testing`), macOS 14.0+.

## Global Constraints

- Swift 6 strict concurrency compliance (`@MainActor`, `Sendable`).
- Native macOS menu bar dimensions (18x18 pt canvas, 1.4~1.6 pt stroke width).
- Zero external third-party animation dependencies (pure mathematical vector geometry in SwiftUI `Path` / `GeometryReader`).
- 100% test pass rate across all test suites via `xcodebuild test`.

---

### Task 1: Data Model Definition for MenuBarIconStyle.hillRunner

**Files:**
- Modify: `Wattly/Core/MenuBarIconStyle.swift`
- Test: `WattlyTests/MenuBarIconStyleTests.swift`

**Interfaces:**
- Produces: `MenuBarIconStyle.hillRunner` case with:
  - `label: "러너 (경사로 질주)"`
  - `category: "캐릭터 / 라이프"`
  - `summary: "부하(0%~100%)에 따라 오르막 힘겨운 걸음 → 평지 조깅 → 내리막 폭풍 질주로 지형 경사와 캐릭터 자세가 연속 전환됩니다."`
  - `frameCount: 24`
  - `staticFrame: 8`

- [ ] **Step 1: Write the failing unit test**

In `WattlyTests/MenuBarIconStyleTests.swift`:
```swift
@Test func hillRunnerMetadataMatchesSpecification() {
    let style = MenuBarIconStyle.hillRunner
    #expect(style.rawValue == "hillRunner")
    #expect(style.label == "러너 (경사로 질주)")
    #expect(style.category == "캐릭터 / 라이프")
    #expect(!style.summary.isEmpty)
    #expect(style.frameCount == 24)
    #expect(style.staticFrame == 8)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/MenuBarIconStyleTests`
Expected: FAIL if `.hillRunner` is missing or has incorrect metadata.

- [ ] **Step 3: Implement minimal code**

In `Wattly/Core/MenuBarIconStyle.swift`:
```swift
case hillRunner = "hillRunner"
```
And add metadata mappings:
```swift
public var label: String {
    switch self {
    // ...
    case .hillRunner: "러너 (경사로 질주)"
    }
}

public var category: String {
    switch self {
    // ...
    case .hillRunner: "캐릭터 / 라이프"
    }
}

public var summary: String {
    switch self {
    // ...
    case .hillRunner:
        "부하(0%~100%)에 따라 오르막 힘겨운 걸음 → 평지 조깅 → 내리막 폭풍 질주로 지형 경사와 캐릭터 자세가 연속 전환됩니다."
    }
}

public var frameCount: Int {
    switch self {
    // ...
    case .hillRunner: 24
    }
}

public var staticFrame: Int {
    switch self {
    // ...
    case .hillRunner: 8
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/MenuBarIconStyleTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/MenuBarIconStyle.swift WattlyTests/MenuBarIconStyleTests.swift
git commit -m "feat: integrate MenuBarIconStyle.hillRunner data model"
```

---

### Task 2: Tiered Locomotion Frame Mapping & Cadence in KineticNotchMotion

**Files:**
- Modify: `Wattly/Core/KineticNotchMotion.swift`
- Test: `WattlyTests/KineticNotchMotionTests.swift`

**Interfaces:**
- Consumes: `MenuBarIconStyle.hillRunner`
- Produces: `MenuBarIconMotion.displayedFrame(style:phase:load:reduceMotion:)` mapping:
  - `load < 25.0` -> Tier 0 (Frames 0..7)
  - `load < 65.0` -> Tier 1 (Frames 8..15)
  - `load >= 65.0` -> Tier 2 (Frames 16..23)
  - `reduceMotion == true` -> Returns `staticFrame` (8)
  - `phaseDelayMultiplier` -> `1.4` for natural human pacing

- [ ] **Step 1: Write the failing unit test**

In `WattlyTests/KineticNotchMotionTests.swift`:
```swift
@Test func hillRunnerMapsLoadTiersCorrectly() {
    let lowTier = MenuBarIconMotion.displayedFrame(style: .hillRunner, phase: 0.0, load: 15.0, reduceMotion: false)
    #expect((0...7).contains(lowTier))

    let midTier = MenuBarIconMotion.displayedFrame(style: .hillRunner, phase: 0.0, load: 45.0, reduceMotion: false)
    #expect((8...15).contains(midTier))

    let highTier = MenuBarIconMotion.displayedFrame(style: .hillRunner, phase: 0.0, load: 85.0, reduceMotion: false)
    #expect((16...23).contains(highTier))

    let staticFrame = MenuBarIconMotion.displayedFrame(style: .hillRunner, phase: 0.5, load: 85.0, reduceMotion: true)
    #expect(staticFrame == 8)

    let multiplier = MenuBarIconMotion.phaseDelayMultiplier(style: .hillRunner, phase: 0)
    #expect(multiplier == 1.4)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/KineticNotchMotionTests`
Expected: FAIL

- [ ] **Step 3: Implement minimal code**

In `Wattly/Core/KineticNotchMotion.swift`:
```swift
if style == .hillRunner {
    let clampedLoad = min(max(activeLoad, 0), 100)
    let tier: Int
    if clampedLoad < 25.0 {
        tier = 0
    } else if clampedLoad < 65.0 {
        tier = 1
    } else {
        tier = 2
    }
    let subPhase = Int(safePhase * 8.0) % 8
    return tier * 8 + subPhase
}
```
And in `phaseDelayMultiplier`:
```swift
case .hillRunner:
    return 1.4
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/KineticNotchMotionTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/KineticNotchMotion.swift WattlyTests/KineticNotchMotionTests.swift
git commit -m "feat: add tiered frame mapping and cadence multiplier for hillRunner"
```

---

### Task 3: Vector Graphic & 24-Frame Calibrated Pose Kinematics in Glyphs.swift

**Files:**
- Modify: `Wattly/DesignSystem/Glyphs.swift`
- Test: `WattlyTests/GlyphsRenderingTests.swift`

**Interfaces:**
- Consumes: `MenuBarIconStyle.hillRunner`, `frame: Int` (0..23)
- Produces: `HillRunnerMark: View` rendering stickman with 2-link IK legs, deep backward arm swing, upright posture (`leanAngle = (0.045 + t * 0.055) * .pi`), and 2nd-order Bézier rolling hill ground line (`Path.addQuadCurve`).

- [ ] **Step 1: Write the failing unit test**

In `WattlyTests/GlyphsRenderingTests.swift`:
```swift
@Test @MainActor func hillRunnerRendersAllFramesWithoutCrash() {
    for frame in 0..<MenuBarIconStyle.hillRunner.frameCount {
        let view = DynamicMenuBarIconMark(style: .hillRunner, frame: frame, markerColor: .black)
        #expect(view.style == .hillRunner)
        #expect(view.frame == frame)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/GlyphsRenderingTests`
Expected: FAIL

- [ ] **Step 3: Implement minimal code**

In `Wattly/DesignSystem/Glyphs.swift`:
Implement `struct HillRunnerMark: View` with complete calibrated pose tables:
```swift
struct HillRunnerMark: View {
    let frame: Int
    var markerColor: Color = Tokens.accent

    private struct Pose {
        let bob: Double
        let ft: Double, fk: Double
        let bt: Double, bk: Double
        let fa: Double, fab: Double
        let ba: Double, bab: Double
    }

    private static let poses: [[Pose]] = [
        // Tier 0: Uphill Heavy Walk (0..7) - Upright posture & deep rear arm swing
        [
            Pose(bob: -0.015, ft:  0.36, fk: 0.30, bt: -0.34, bk: 0.35, fa: -0.65, fab: -1.15, ba:  0.50, bab: -1.35),
            Pose(bob:  0.015, ft:  0.15, fk: 0.75, bt: -0.45, bk: 0.85, fa: -0.75, fab: -1.10, ba:  0.60, bab: -1.40),
            Pose(bob: -0.010, ft: -0.08, fk: 0.20, bt:  0.28, bk: 1.10, fa: -0.20, fab: -1.15, ba:  0.15, bab: -1.25),
            Pose(bob: -0.035, ft: -0.30, fk: 0.12, bt:  0.36, bk: 0.32, fa:  0.45, fab: -1.35, ba: -0.55, bab: -1.15),
            Pose(bob: -0.015, ft: -0.34, fk: 0.35, bt:  0.36, bk: 0.30, fa:  0.50, fab: -1.35, ba: -0.65, bab: -1.15),
            Pose(bob:  0.015, ft: -0.45, fk: 0.85, bt:  0.15, bk: 0.75, fa:  0.60, fab: -1.40, ba: -0.75, bab: -1.10),
            Pose(bob: -0.010, ft:  0.28, fk: 1.10, bt: -0.08, bk: 0.20, fa:  0.15, fab: -1.25, ba: -0.20, bab: -1.15),
            Pose(bob: -0.035, ft:  0.36, fk: 0.32, bt: -0.30, bk: 0.12, fa: -0.55, fab: -1.15, ba:  0.45, bab: -1.35)
        ],
        // Tier 1: Flat Athletic Jog (8..15) - Athletic upright posture & rear elbow drive
        [
            Pose(bob:  0.000, ft:  0.58, fk: 0.38, bt: -0.54, bk: 0.65, fa: -1.05, fab: -1.35, ba:  0.75, bab: -1.50),
            Pose(bob:  0.030, ft:  0.18, fk: 1.05, bt: -0.70, bk: 1.35, fa: -1.20, fab: -1.30, ba:  0.90, bab: -1.60),
            Pose(bob: -0.020, ft: -0.25, fk: 0.25, bt:  0.52, bk: 1.45, fa: -0.30, fab: -1.35, ba:  0.25, bab: -1.45),
            Pose(bob: -0.065, ft: -0.58, fk: 0.45, bt:  0.75, bk: 0.60, fa:  0.80, fab: -1.55, ba: -0.95, bab: -1.35),
            Pose(bob:  0.000, ft: -0.54, fk: 0.65, bt:  0.58, bk: 0.38, fa:  0.75, fab: -1.50, ba: -1.05, bab: -1.35),
            Pose(bob:  0.030, ft: -0.70, fk: 1.35, bt:  0.18, bk: 1.05, fa:  0.90, fab: -1.60, ba: -1.20, bab: -1.30),
            Pose(bob: -0.020, ft:  0.52, fk: 1.45, bt: -0.25, bk: 0.25, fa:  0.25, fab: -1.45, ba: -0.30, bab: -1.35),
            Pose(bob: -0.065, ft:  0.75, fk: 0.60, bt: -0.58, bk: 0.45, fa: -0.95, fab: -1.35, ba:  0.80, bab: -1.55)
        ],
        // Tier 2: Downhill Frantic Sprint (16..23) - Dynamic sprint & horizontal back reach
        [
            Pose(bob:  0.000, ft:  0.82, fk: 0.52, bt: -0.78, bk: 0.85, fa: -1.45, fab: -1.40, ba:  1.05, bab: -1.65),
            Pose(bob:  0.040, ft:  0.30, fk: 1.35, bt: -1.02, bk: 1.65, fa: -1.60, fab: -1.35, ba:  1.30, bab: -1.70),
            Pose(bob: -0.040, ft: -0.45, fk: 0.35, bt:  0.85, bk: 1.75, fa: -0.40, fab: -1.40, ba:  0.40, bab: -1.55),
            Pose(bob: -0.095, ft: -0.90, fk: 0.65, bt:  1.08, bk: 0.75, fa:  1.10, fab: -1.65, ba: -1.40, bab: -1.40),
            Pose(bob:  0.000, ft: -0.78, fk: 0.85, bt:  0.82, bk: 0.52, fa:  1.05, fab: -1.65, ba: -1.45, bab: -1.40),
            Pose(bob:  0.040, ft: -1.02, fk: 1.65, bt:  0.30, bk: 1.35, fa:  1.30, fab: -1.70, ba: -1.60, bab: -1.35),
            Pose(bob: -0.040, ft:  0.85, fk: 1.75, bt: -0.45, bk: 0.35, fa:  0.40, fab: -1.55, ba: -0.40, bab: -1.40),
            Pose(bob: -0.095, ft:  1.08, fk: 0.75, bt: -0.90, bk: 0.65, fa: -1.40, fab: -1.40, ba:  1.10, bab: -1.65)
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

            // Smooth rolling hill curve
            let smoothT = t * t * (3.0 - 2.0 * t)
            let gX1 = s * 0.08, gX2 = s * 0.92
            let gMidX = s * 0.50
            let gY1 = s * (0.82 - smoothT * 0.20)
            let gMidY = s * (0.75 - sin(smoothT * .pi) * 0.08 + (smoothT > 0.5 ? (smoothT - 0.5) * 0.10 : 0.0))
            let gY2 = s * (0.70 + smoothT * 0.16)

            let hipX = s * 0.48
            let u = (hipX - gX1) / (gX2 - gX1)
            let groundAtHip = (1.0 - u) * (1.0 - u) * gY1 + 2.0 * (1.0 - u) * u * gMidY + u * u * gY2

            let hipY = groundAtHip - s * (0.24 - t * 0.02) + s * pose.bob

            let leanAngle = (0.045 + t * 0.055) * .pi
            let torsoLen = s * 0.22
            let neckX = hipX + sin(leanAngle) * torsoLen
            let neckY = hipY - cos(leanAngle) * torsoLen

            let headAngle = leanAngle * 0.65
            let headX = neckX + sin(headAngle) * (s * 0.09)
            let headY = neckY - cos(headAngle) * (s * 0.09)

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
                Path { path in
                    path.move(to: CGPoint(x: gX1, y: gY1))
                    path.addQuadCurve(to: CGPoint(x: gX2, y: gY2), control: CGPoint(x: gMidX, y: gMidY))
                }
                .stroke(style: StrokeStyle(lineWidth: max(1.2, strokeW * 0.8), lineCap: .round))
                .opacity(0.35)

                if tier == 2 {
                    Path { path in
                        path.move(to: CGPoint(x: s * 0.12, y: neckY - s * 0.02))
                        path.addLine(to: CGPoint(x: s * 0.26, y: neckY - s * 0.02))
                        path.move(to: CGPoint(x: s * 0.06, y: hipY - s * 0.02))
                        path.addLine(to: CGPoint(x: s * 0.22, y: hipY - s * 0.02))
                    }
                    .stroke(style: StrokeStyle(lineWidth: strokeW * 0.65, lineCap: .round, dash: [s * 0.06, s * 0.04]))
                    .opacity(0.30)
                }

                Path { path in
                    path.move(to: CGPoint(x: bshX, y: bshY))
                    path.addLine(to: CGPoint(x: beX, y: beY))
                    path.addLine(to: CGPoint(x: bhX, y: bhY))
                }
                .stroke(style: StrokeStyle(lineWidth: strokeW * 0.85, lineCap: .round, lineJoin: .round))
                .opacity(0.55)

                Path { path in
                    path.move(to: CGPoint(x: hipX, y: hipY))
                    path.addLine(to: CGPoint(x: bkX, y: bkY))
                    path.addLine(to: CGPoint(x: bfX, y: bfY))
                }
                .stroke(style: StrokeStyle(lineWidth: strokeW * 0.85, lineCap: .round, lineJoin: .round))
                .opacity(0.55)

                Path { path in
                    path.move(to: CGPoint(x: hipX, y: hipY))
                    path.addLine(to: CGPoint(x: neckX, y: neckY))
                }
                .stroke(style: StrokeStyle(lineWidth: strokeW * 1.15, lineCap: .round))

                Path { path in
                    path.addEllipse(in: CGRect(x: headX - headR, y: headY - headR, width: headR * 2, height: headR * 2))
                }
                .fill(markerColor)

                Path { path in
                    path.move(to: CGPoint(x: hipX, y: hipY))
                    path.addLine(to: CGPoint(x: fkX, y: fkY))
                    path.addLine(to: CGPoint(x: ffX, y: ffY))
                }
                .stroke(style: StrokeStyle(lineWidth: strokeW * 1.05, lineCap: .round, lineJoin: .round))

                Path { path in
                    path.move(to: CGPoint(x: fshX, y: fshY))
                    path.addLine(to: CGPoint(x: feX, y: feY))
                    path.addLine(to: CGPoint(x: fhX, y: fhY))
                }
                .stroke(style: StrokeStyle(lineWidth: strokeW * 1.05, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
```
And add `case .hillRunner: HillRunnerMark(frame: frame, markerColor: markerColor)` in `DynamicMenuBarIconMark`.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/GlyphsRenderingTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/DesignSystem/Glyphs.swift WattlyTests/GlyphsRenderingTests.swift
git commit -m "feat: implement calibrated HillRunnerMark vector drawing in Glyphs"
```

---

### Task 4: Full App Integration & MenuBar NSImage Template Verification

**Files:**
- Modify: `Wattly/Views/Settings/SettingsMenuBarSection.swift` (already handles `MenuBarIconStyle.allCases`)
- Test: `WattlyTests/MenuBarGlyphTests.swift`

**Interfaces:**
- Consumes: `MenuBarIconStyle.hillRunner`, `DynamicMenuBarIconMark`
- Produces: Valid `NSImage` template with `isTemplate = true` via `MenuBarGlyph.template(style: .hillRunner, frame: frame)`

- [ ] **Step 1: Run full test suite to verify end-to-end integration**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData`
Expected: All 41 test suites and 461 tests PASS.

- [ ] **Step 2: Build debug binary for Wattly.app**

Run: `xcodebuild build -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add .
git commit -m "chore: verify full Wattly app integration for hillRunner icon"
```
