# Dynamic MenuBar Icons (RunCat Benchmark Theme Collection) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement 8 newly designed non-creature dynamic menubar icon themes (Cooling Turbine, Dual Gears, Pulse W Waveform, Atomic Orbit, 3D Wireframe Cube, Infinity Ribbon, Vintage Tape Reel, Thermal Convection Bubbles) alongside the existing Flux Loop, allowing users to select and live-preview their preferred dynamic icon style in Settings.

**Architecture:** 
- Define a unified `MenuBarIconStyle` enum supporting all 9 dynamic themes with their respective frame counts and metadata.
- Provide vector rendering views in `Glyphs.swift` for each theme, wrapped by a unified `DynamicMenuBarIconMark` dispatcher.
- Generalize motion and frame delay calculations in `KineticNotchMotion.swift` (maintaining backward-compatible typealiases for `KineticNotch*`).
- Rasterize and cache template `NSImage` instances in `MenuBarGlyph` per style and frame to ensure 0% CPU idle footprint and native dark/light menu bar tinting.
- Expand `SettingsMenuBarSection.swift` with an interactive Icon Theme Selector grid featuring live animated previews.

**Tech Stack:** Swift 6.0, SwiftUI, AppKit (NSImage template rasterization with `ImageRenderer`), Swift Testing (`@Test`, `#expect`), XcodeGen.

## Global Constraints

- Platform deployment target: macOS 14.0+
- Architecture: Apple Silicon (`arm64`)
- Language: Swift 6.0 with strict concurrency
- Zero non-standard external dependencies (Pure SwiftUI / AppKit)
- Template NSImages must set `isTemplate = true` and support light/dark status bar tinting
- All tests must pass with `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData`

---

### Task 1: Data Model & Settings Integration for `MenuBarIconStyle`

**Files:**
- Create: `Wattly/Core/MenuBarIconStyle.swift`
- Modify: `Wattly/Settings/Settings.swift`
- Modify: `Wattly/Core/SettingsReset.swift`
- Test: `WattlyTests/MenuBarIconStyleTests.swift`

**Interfaces:**
- Consumes: None
- Produces: 
  - `enum MenuBarIconStyle: String, CaseIterable, Identifiable, Sendable`
  - `StorageKey.menubarIconStyle: String`
  - `Defaults.menubarIconStyle: MenuBarIconStyle`

- [ ] **Step 1: Write the failing unit tests for `MenuBarIconStyle`**

Create `WattlyTests/MenuBarIconStyleTests.swift`:
```swift
import Testing
import Foundation
@testable import Wattly

struct MenuBarIconStyleTests {
    @Test func allIconStylesHaveValidMetadataAndFrameCounts() {
        let styles = MenuBarIconStyle.allCases
        #expect(styles.count == 9)
        for style in styles {
            #expect(!style.id.isEmpty)
            #expect(!style.label.isEmpty)
            #expect(!style.category.isEmpty)
            #expect(!style.summary.isEmpty)
            #expect(style.frameCount >= 4)
            #expect(style.staticFrame == 0)
        }
    }

    @Test func defaultIconStyleIsCoolingTurbine() {
        #expect(Defaults.menubarIconStyle == .turbine)
        #expect(StorageKey.menubarIconStyle == "menubarIconStyle")
    }

    @Test func settingsResetRestoresDefaultIconStyle() {
        let defaults = UserDefaults(suiteName: "MenuBarIconStyleTests")!
        defaults.set(MenuBarIconStyle.cube3D.rawValue, forKey: StorageKey.menubarIconStyle)
        #expect(defaults.string(forKey: StorageKey.menubarIconStyle) == MenuBarIconStyle.cube3D.rawValue)

        SettingsReset.applyDefaults(into: defaults)
        #expect(defaults.string(forKey: StorageKey.menubarIconStyle) == Defaults.menubarIconStyle.rawValue)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodegen generate
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/MenuBarIconStyleTests
```
Expected: FAIL with compilation error (MenuBarIconStyle not found).

- [ ] **Step 3: Implement `MenuBarIconStyle` and update `Settings` & `SettingsReset`**

Create `Wattly/Core/MenuBarIconStyle.swift`:
```swift
import Foundation

public enum MenuBarIconStyle: String, CaseIterable, Identifiable, Sendable {
    case turbine = "turbine"             // 1. 쿨링 터빈
    case gears = "gears"                 // 2. 듀얼 인터로킹 기어
    case pulseWave = "pulseWave"         // 3. 흐르는 펄스 W 파형
    case atomicOrbit = "atomicOrbit"     // 4. 원자 궤도
    case cube3D = "cube3D"               // 5. 3D 와이어프레임 큐브
    case infinityLoop = "infinityLoop"   // 6. 뫼비우스 인피니티
    case tapeReel = "tapeReel"           // 7. 레트로 테이프 릴
    case thermalBubble = "thermalBubble" // 8. 열 대류 버블
    case fluxLoop = "fluxLoop"           // 9. 플럭스 루프 (Kinetic Notch)

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .turbine: "쿨링 터빈"
        case .gears: "듀얼 기어"
        case .pulseWave: "펄스 웨이브"
        case .atomicOrbit: "원자 궤도"
        case .cube3D: "3D 큐브"
        case .infinityLoop: "뫼비우스 루프"
        case .tapeReel: "테이프 릴"
        case .thermalBubble: "열 대류 버블"
        case .fluxLoop: "플럭스 루프"
        }
    }

    public var category: String {
        switch self {
        case .turbine: "쿨링 / 팬"
        case .gears: "기계 메커니즘"
        case .pulseWave: "전력 / 신호"
        case .atomicOrbit: "에너지 물리"
        case .cube3D: "3D 기하학"
        case .infinityLoop: "유체 모션"
        case .tapeReel: "레트로 컴퓨팅"
        case .thermalBubble: "열역학"
        case .fluxLoop: "노치 루프"
        }
    }

    public var summary: String {
        switch self {
        case .turbine: "맥북 쿨링 팬 블레이드가 부하에 맞춰 고속 회전합니다."
        case .gears: "맞물린 2개의 기어가 서로 반대 방향으로 회전하며 연산 작업을 시각화합니다."
        case .pulseWave: "Wattly 시그니처 W 파형이 좌에서 우로 전파되며 전력 부하에 따라 가속됩니다."
        case .atomicOrbit: "중앙 핵 주위의 2개 타원 궤도를 따라 전자가 고속 순환합니다."
        case .cube3D: "3차원 대각선 축을 기준으로 와이어프레임 큐브가 자전합니다."
        case .infinityLoop: "무한대(∞) 궤적을 따라 유체 에너지 파티클이 순환합니다."
        case .tapeReel: "클래식 메인프레임의 마그네틱 테이프 릴이 연동 회전합니다."
        case .thermalBubble: "하단에서 상단으로 열 배출 기포 파티클이 상승합니다."
        case .fluxLoop: "맥북 노치 형태의 트랙을 따라 에너지 점이 순환합니다."
        }
    }

    public var frameCount: Int {
        switch self {
        case .turbine: 6
        case .gears: 8
        case .pulseWave: 8
        case .atomicOrbit: 8
        case .cube3D: 12
        case .infinityLoop: 8
        case .tapeReel: 6
        case .thermalBubble: 8
        case .fluxLoop: 7
        }
    }

    public var staticFrame: Int { 0 }
}
```

Update `Wattly/Settings/Settings.swift`:
```swift
// In enum Defaults:
    static let menubarIconStyle = MenuBarIconStyle.turbine

// In enum StorageKey:
    static let menubarIconStyle = "menubarIconStyle"
```

Update `Wattly/Core/SettingsReset.swift`:
```swift
// Inside SettingsReset.applyDefaults(into:login:):
        defaults.set(Defaults.menubarIconStyle.rawValue, forKey: StorageKey.menubarIconStyle)
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodegen generate
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/MenuBarIconStyleTests
```
Expected: PASS with 0 failures.

- [ ] **Step 5: Commit changes**

```bash
git add Wattly/Core/MenuBarIconStyle.swift Wattly/Settings/Settings.swift Wattly/Core/SettingsReset.swift WattlyTests/MenuBarIconStyleTests.swift
git commit -m "feat(menubar): add MenuBarIconStyle model and settings integration"
```

---

### Task 2: Motion Logic Generalization (`KineticNotchMotion.swift`)

**Files:**
- Modify: `Wattly/Core/KineticNotchMotion.swift`
- Modify: `WattlyTests/KineticNotchMotionTests.swift`

**Interfaces:**
- Consumes: `MenuBarIconStyle`
- Produces:
  - `MenuBarIconMotion.displayedFrame(style:phase:reduceMotion:) -> Int`
  - `MenuBarIconMotion.frameDelay(style:phase:frameRate:) -> TimeInterval`
  - `MenuBarIconMotion.frameRate(load:speed:) -> Double?`
  - Backward-compatible `KineticNotchMotion` aliases

- [ ] **Step 1: Write the failing unit tests for multi-style motion handling**

Update `WattlyTests/KineticNotchMotionTests.swift` to add:
```swift
    @Test func motionCalculatesDisplayedFrameForVariousStyles() {
        for style in MenuBarIconStyle.allCases {
            #expect(MenuBarIconMotion.displayedFrame(style: style, phase: 0, reduceMotion: false) == 0)
            #expect(MenuBarIconMotion.displayedFrame(style: style, phase: style.frameCount - 1, reduceMotion: false) == style.frameCount - 1)
            #expect(MenuBarIconMotion.displayedFrame(style: style, phase: style.frameCount, reduceMotion: false) == 0)
            #expect(MenuBarIconMotion.displayedFrame(style: style, phase: -1, reduceMotion: false) == style.frameCount - 1)
            #expect(MenuBarIconMotion.displayedFrame(style: style, phase: 3, reduceMotion: true) == style.staticFrame)
        }
    }

    @Test func frameDelaysSumToCycleTime() {
        for style in MenuBarIconStyle.allCases {
            let delays = (0..<style.frameCount).map {
                MenuBarIconMotion.frameDelay(style: style, phase: $0, frameRate: 5.0)
            }
            let totalTime = delays.reduce(0, +)
            let expectedTotalTime = Double(style.frameCount) / 5.0
            #expect(abs(totalTime - expectedTotalTime) < 1e-9)
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/KineticNotchMotionTests`
Expected: FAIL.

- [ ] **Step 3: Implement `MenuBarIconMotion` and compatibility in `KineticNotchMotion.swift`**

Replace `Wattly/Core/KineticNotchMotion.swift` with:
```swift
import Foundation

public enum KineticNotchSource: String, CaseIterable, Identifiable, Sendable {
    case cpu, gpu, cpuGPU
    public var id: String { rawValue }
    public var label: String {
        switch self { case .cpu: "CPU"; case .gpu: "GPU"; case .cpuGPU: "CPU + GPU" }
    }
    public var requiredCards: Set<CardKind> {
        switch self { case .cpu: [.cpu]; case .gpu: [.gpu]; case .cpuGPU: [.cpu, .gpu] }
    }
    public func load(cpu: Double?, gpu: Double?) -> Double? {
        func valid(_ value: Double?) -> Double? {
            guard let value, value.isFinite else { return nil }
            return min(max(value, 0), 100)
        }
        switch self {
        case .cpu: return valid(cpu)
        case .gpu: return valid(gpu)
        case .cpuGPU:
            guard let cpu = valid(cpu), let gpu = valid(gpu) else { return nil }
            return (cpu + gpu) / 2
        }
    }
}

public enum KineticNotchSpeed: String, CaseIterable, Identifiable, Sendable {
    case eco, standard, responsive
    public var id: String { rawValue }
    public var label: String {
        switch self { case .eco: "절전"; case .standard: "표준"; case .responsive: "민감" }
    }
    public var minimumFrameRate: Double {
        switch self { case .eco: 0.75; case .standard: 1.25; case .responsive: 2 }
    }
    public var maximumFrameRate: Double {
        switch self { case .eco: 3; case .standard: 5; case .responsive: 7 }
    }
    public var description: String {
        switch self {
        case .eco: "낮은 전력으로 부하에 따라 0.75~3 fps로 움직입니다."
        case .standard: "균형 잡힌 반응으로 부하에 따라 1.25~5 fps로 움직입니다."
        case .responsive: "부하 변화에 민감하게 2~7 fps로 움직입니다."
        }
    }
}

public enum MenuBarIconMotion {
    public static let idleThreshold = 5.0
    public static let fluxLoopPhaseDelayMultipliers = [0.92, 0.78, 1.32, 0.96, 0.78, 1.32, 0.92]

    public static func displayedFrame(style: MenuBarIconStyle, phase: Int, reduceMotion: Bool) -> Int {
        guard !reduceMotion else { return style.staticFrame }
        let count = style.frameCount
        return ((phase % count) + count) % count
    }

    public static func phaseDelayMultiplier(style: MenuBarIconStyle, phase: Int) -> Double {
        if style == .fluxLoop {
            let count = fluxLoopPhaseDelayMultipliers.count
            return fluxLoopPhaseDelayMultipliers[((phase % count) + count) % count]
        }
        return 1.0
    }

    public static func frameDelay(style: MenuBarIconStyle, phase: Int, frameRate: Double) -> TimeInterval {
        phaseDelayMultiplier(style: style, phase: phase) / frameRate
    }

    public static func frameRate(load: Double, speed: KineticNotchSpeed) -> Double? {
        let load = min(max(load, 0), 100)
        guard load > idleThreshold else { return nil }
        let progress = sqrt((load - idleThreshold) / (100 - idleThreshold))
        return speed.minimumFrameRate + (speed.maximumFrameRate - speed.minimumFrameRate) * progress
    }
}

/// Backward-compatible wrapper for Flux Loop / Kinetic Notch
public enum KineticNotchMotion {
    public static let frameCount = 7
    public static let idleThreshold = MenuBarIconMotion.idleThreshold
    public static let staticFrame = 0
    public static let rightEdgePhase = 2
    public static let leftEdgePhase = 5

    public static func displayedFrame(phase: Int, reduceMotion: Bool) -> Int {
        MenuBarIconMotion.displayedFrame(style: .fluxLoop, phase: phase, reduceMotion: reduceMotion)
    }

    public static func phaseDelayMultiplier(phase: Int) -> Double {
        MenuBarIconMotion.phaseDelayMultiplier(style: .fluxLoop, phase: phase)
    }

    public static func frameDelay(phase: Int, frameRate: Double) -> TimeInterval {
        MenuBarIconMotion.frameDelay(style: .fluxLoop, phase: phase, frameRate: frameRate)
    }

    public static func frameRate(load: Double, speed: KineticNotchSpeed) -> Double? {
        MenuBarIconMotion.frameRate(load: load, speed: speed)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/KineticNotchMotionTests`
Expected: PASS with 0 failures.

- [ ] **Step 5: Commit changes**

```bash
git add Wattly/Core/KineticNotchMotion.swift WattlyTests/KineticNotchMotionTests.swift
git commit -m "feat(menubar): generalize motion calculation for all icon styles"
```

---

### Task 3: Vector Glyph Shapes & Unified Dispatcher (`Glyphs.swift`)

**Files:**
- Modify: `Wattly/DesignSystem/Glyphs.swift`
- Test: `WattlyTests/GlyphsRenderingTests.swift`

**Interfaces:**
- Consumes: `MenuBarIconStyle`
- Produces:
  - `struct TurbineMark: View`
  - `struct GearsMark: View`
  - `struct PulseWaveMark: View`
  - `struct AtomicOrbitMark: View`
  - `struct Cube3DMark: View`
  - `struct InfinityLoopMark: View`
  - `struct TapeReelMark: View`
  - `struct ThermalBubbleMark: View`
  - `struct DynamicMenuBarIconMark: View`

- [ ] **Step 1: Write the failing unit tests for glyph rendering**

Create `WattlyTests/GlyphsRenderingTests.swift`:
```swift
import Testing
import SwiftUI
@testable import Wattly

struct GlyphsRenderingTests {
    @Test @MainActor func allStylesRenderValidViewsForAllFrames() {
        for style in MenuBarIconStyle.allCases {
            for frame in 0..<style.frameCount {
                let view = DynamicMenuBarIconMark(style: style, frame: frame, markerColor: .black)
                #expect(view.style == style)
                #expect(view.frame == frame)
            }
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodegen generate
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/GlyphsRenderingTests
```
Expected: FAIL (DynamicMenuBarIconMark not found).

- [ ] **Step 3: Implement all 8 vector mark views and `DynamicMenuBarIconMark` in `Glyphs.swift`**

Add the following vector mark views and `DynamicMenuBarIconMark` to `Wattly/DesignSystem/Glyphs.swift`:

```swift
// 1. Cooling Turbine Mark
public struct TurbineMark: View {
    public let frame: Int
    public var markerColor: Color = Tokens.accent

    public var body: some View {
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
public struct GearsMark: View {
    public let frame: Int
    public var markerColor: Color = Tokens.accent

    public var body: some View {
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
public struct PulseWaveMark: View {
    public let frame: Int
    public var markerColor: Color = Tokens.accent

    public var body: some View {
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
public struct AtomicOrbitMark: View {
    public let frame: Int
    public var markerColor: Color = Tokens.accent

    public var body: some View {
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
public struct Cube3DMark: View {
    public let frame: Int
    public var markerColor: Color = Tokens.accent

    public var body: some View {
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
public struct InfinityLoopMark: View {
    public let frame: Int
    public var markerColor: Color = Tokens.accent

    public var body: some View {
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
                               control1: CGPoint(x: c.x, y: c.y + s * 0.25),
                               control2: CGPoint(x: c.x + s * 0.35, y: c.y + s * 0.25))
                    p.addCurve(to: CGPoint(x: c.x, y: c.y),
                               control1: CGPoint(x: c.x + s * 0.35, y: c.y - s * 0.25),
                               control2: CGPoint(x: c.x, y: c.y - s * 0.25))
                    p.addCurve(to: CGPoint(x: c.x - s * 0.35, y: c.y),
                               control1: CGPoint(x: c.x, y: c.y + s * 0.25),
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
public struct TapeReelMark: View {
    public let frame: Int
    public var markerColor: Color = Tokens.accent

    public var body: some View {
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
public struct ThermalBubbleMark: View {
    public let frame: Int
    public var markerColor: Color = Tokens.accent

    public var body: some View {
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
public struct DynamicMenuBarIconMark: View {
    public let style: MenuBarIconStyle
    public let frame: Int
    public var markerColor: Color = Tokens.accent

    public init(style: MenuBarIconStyle, frame: Int, markerColor: Color = Tokens.accent) {
        self.style = style
        self.frame = frame
        self.markerColor = markerColor
    }

    public var body: some View {
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
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodegen generate
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/GlyphsRenderingTests
```
Expected: PASS with 0 failures.

- [ ] **Step 5: Commit changes**

```bash
git add Wattly/DesignSystem/Glyphs.swift WattlyTests/GlyphsRenderingTests.swift
git commit -m "feat(menubar): implement vector glyphs for all 8 new dynamic icon styles"
```

---

### Task 4: Template NSImage Rasterization & Multi-Style Cache (`MenuBarLabel.swift`)

**Files:**
- Modify: `Wattly/Views/MenuBarLabel.swift`
- Test: `WattlyTests/MenuBarGlyphTests.swift`

**Interfaces:**
- Consumes: `MenuBarIconStyle`, `DynamicMenuBarIconMark`, `MenuBarIconMotion`
- Produces:
  - `MenuBarGlyph.template(style:frame:) -> NSImage?`
  - `MenuBarLabel` reading `@AppStorage(StorageKey.menubarIconStyle)`

- [ ] **Step 1: Write the failing unit tests for `MenuBarGlyph` template caching**

Create `WattlyTests/MenuBarGlyphTests.swift`:
```swift
import Testing
import AppKit
@testable import Wattly

struct MenuBarGlyphTests {
    @Test @MainActor func templatesAreGeneratedAndMarkedAsTemplateImage() {
        for style in MenuBarIconStyle.allCases {
            for frame in 0..<style.frameCount {
                let image = MenuBarGlyph.template(style: style, frame: frame)
                #expect(image != nil)
                #expect(image?.isTemplate == true)
            }
        }
    }

    @Test @MainActor func templatesAreCachedInMemory() {
        let firstCall = MenuBarGlyph.template(style: .turbine, frame: 0)
        let secondCall = MenuBarGlyph.template(style: .turbine, frame: 0)
        #expect(firstCall === secondCall)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodegen generate
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/MenuBarGlyphTests
```
Expected: FAIL.

- [ ] **Step 3: Update `MenuBarGlyph` and `MenuBarLabel` in `MenuBarLabel.swift`**

Replace `Wattly/Views/MenuBarLabel.swift` with:
```swift
import SwiftUI
import AppKit

struct MenuBarLabel: View {
    let monitor: SystemMonitor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visibilitySettings = VisibilitySettings.shared
    @State private var dynamicIconPhase = 0
    @AppStorage(StorageKey.menubarTextEnabled) private var textEnabled = Defaults.menubarTextEnabled
    @AppStorage(StorageKey.powerSmoothed)      private var powerSmoothed = Defaults.powerSmoothed
    @AppStorage(StorageKey.kineticNotchMotionEnabled) private var kineticNotchMotionEnabled = Defaults.kineticNotchMotionEnabled
    @AppStorage(StorageKey.kineticNotchSource) private var kineticNotchSource = Defaults.kineticNotchSource
    @AppStorage(StorageKey.kineticNotchSpeed) private var kineticNotchSpeed = Defaults.kineticNotchSpeed
    @AppStorage(StorageKey.menubarIconStyle) private var iconStyle = Defaults.menubarIconStyle

    var body: some View {
        let label = assembled
        let glyph = MenuBarGlyph.template(style: iconStyle, frame: currentFrame).map(Image.init(nsImage:)) ?? Image(systemName: "waveform.path")
        return HStack(spacing: 4) {
            glyph
            if let label {
                Text(label)
                    .font(WattlyFont.at(11, weight: .semibold))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .task(id: "\(iconStyle.rawValue)-\(kineticNotchMotionEnabled)-\(kineticNotchSource.rawValue)-\(kineticNotchSpeed.rawValue)-\(reduceMotion)-\(dynamicIconFrameRate ?? 0)") {
            guard let frameRate = dynamicIconFrameRate else { return }
            while !Task.isCancelled {
                let phase = dynamicIconPhase
                let delay = MenuBarIconMotion.frameDelay(style: iconStyle, phase: phase, frameRate: frameRate)
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                dynamicIconPhase = (phase + 1) % iconStyle.frameCount
            }
        }
    }

    private var accessibilityLabel: String {
        Accessibility.menuBarLabel(items: items, states: activeStates)
    }

    private var assembled: String? {
        guard textEnabled else { return nil }
        return MenuBarText.assemble(items: items, states: activeStates)
    }

    private var items: [MenuBarItem] {
        visibilitySettings.menuItems
    }

    private var activeStates: [CardKind: MetricState] {
        let kinds = Set(items.map(\.requiredCard))
        return Dictionary(uniqueKeysWithValues:
            kinds.map { ($0, monitor.cardState($0, smoothed: powerSmoothed)) })
    }

    private var kineticNotchLoad: Double? {
        let cpu: Double?
        if case .value(.cpu(let sample)) = monitor.cardState(.cpu) {
            cpu = sample.overall
        } else {
            cpu = nil
        }

        let gpu: Double?
        if case .value(.gpu(let sample)) = monitor.cardState(.gpu) {
            gpu = sample.overall
        } else {
            gpu = nil
        }
        return kineticNotchSource.load(cpu: cpu, gpu: gpu)
    }

    private var currentFrame: Int {
        MenuBarIconMotion.displayedFrame(
            style: iconStyle,
            phase: dynamicIconPhase,
            reduceMotion: reduceMotion || dynamicIconFrameRate == nil
        )
    }

    private var dynamicIconFrameRate: Double? {
        guard kineticNotchMotionEnabled, !reduceMotion, let kineticNotchLoad else { return nil }
        return MenuBarIconMotion.frameRate(load: kineticNotchLoad, speed: kineticNotchSpeed)
    }
}

@MainActor
public enum MenuBarGlyph {
    private static var multiStyleCache: [MenuBarIconStyle: [Int: NSImage]] = [:]

    public static func template(style: MenuBarIconStyle = .fluxLoop, frame: Int) -> NSImage? {
        let index = min(max(frame, 0), style.frameCount - 1)
        if let cached = multiStyleCache[style]?[index] { return cached }

        let renderer = ImageRenderer(content:
            DynamicMenuBarIconMark(style: style, frame: index, markerColor: .black)
                .frame(width: 16, height: 14)
                .padding(1.5)
                .foregroundStyle(.black)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true

        if multiStyleCache[style] == nil {
            multiStyleCache[style] = [:]
        }
        multiStyleCache[style]?[index] = image
        return image
    }

    public static func template(frame: Int) -> NSImage? {
        template(style: .fluxLoop, frame: frame)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/MenuBarGlyphTests`
Expected: PASS with 0 failures.

- [ ] **Step 5: Commit changes**

```bash
git add Wattly/Views/MenuBarLabel.swift WattlyTests/MenuBarGlyphTests.swift
git commit -m "feat(menubar): cache rasterized template NSImages for all styles in MenuBarGlyph"
```

---

### Task 5: Interactive Icon Style Selector in Settings (`SettingsMenuBarSection.swift`)

**Files:**
- Modify: `Wattly/Views/Settings/SettingsMenuBarSection.swift`
- Test: `WattlyTests/SettingsMenuBarIconSectionTests.swift`

**Interfaces:**
- Consumes: `MenuBarIconStyle`, `DynamicMenuBarIconMark`, `MenuBarIconMotion`, `Tokens`
- Produces: Rich interactive 3-column / 3-row grid selector in Settings > MenuBar.

- [ ] **Step 1: Write unit test for settings icon style bindings**

Create `WattlyTests/SettingsMenuBarIconSectionTests.swift`:
```swift
import Testing
import Foundation
@testable import Wattly

struct SettingsMenuBarIconSectionTests {
    @Test func iconStylesCanBePersistedAndReadViaUserDefaults() {
        let defaults = UserDefaults(suiteName: "SettingsMenuBarIconSectionTests")!
        for style in MenuBarIconStyle.allCases {
            defaults.set(style.rawValue, forKey: StorageKey.menubarIconStyle)
            let readValue = defaults.string(forKey: StorageKey.menubarIconStyle)
            #expect(readValue == style.rawValue)
            let parsedStyle = MenuBarIconStyle(rawValue: readValue ?? "")
            #expect(parsedStyle == style)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it passes**

Run:
```bash
xcodegen generate
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/SettingsMenuBarIconSectionTests
```
Expected: PASS.

- [ ] **Step 3: Implement the interactive Icon Theme Selection Grid in `SettingsMenuBarSection.swift`**

Update `Wattly/Views/Settings/SettingsMenuBarSection.swift` `kineticNotchControls`:
```swift
    @AppStorage(StorageKey.menubarIconStyle) private var iconStyle = Defaults.menubarIconStyle
    @State private var iconPreviewPhase = 0

    private var kineticNotchControls: some View {
        VStack(spacing: 0) {
            SettingsToggleRow(isOn: $kineticNotchMotionEnabled, divider: true) {
                VStack(alignment: .leading, spacing: 2) {
                    SettingsRowTitle("부하에 맞춰 아이콘 움직이기")
                    Text("선택한 부하가 높을수록 메뉴바 아이콘의 회전/모션 속도가 빨라집니다.")
                        .font(WattlyFont.at(11.5, weight: .regular))
                        .foregroundStyle(t.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                kineticNotchField(title: "아이콘 디자인 테마") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(MenuBarIconStyle.allCases) { style in
                            Button {
                                iconStyle = style
                            } label: {
                                VStack(spacing: 6) {
                                    DynamicMenuBarIconMark(
                                        style: style,
                                        frame: MenuBarIconMotion.displayedFrame(
                                            style: style,
                                            phase: iconPreviewPhase,
                                            reduceMotion: !kineticNotchMotionEnabled || reduceMotion
                                        ),
                                        markerColor: iconStyle == style ? t.accent : t.text
                                    )
                                    .frame(width: 28, height: 24)
                                    .foregroundStyle(iconStyle == style ? t.accent : t.text)

                                    Text(style.label)
                                        .font(WattlyFont.at(11.5, weight: iconStyle == style ? .semibold : .regular))
                                        .foregroundStyle(iconStyle == style ? t.text : t.faint)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .padding(.horizontal, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(iconStyle == style ? t.accent.opacity(0.12) : t.surface)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(iconStyle == style ? t.accent : t.border, lineWidth: iconStyle == style ? 1.5 : 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if kineticNotchMotionEnabled {
                    kineticNotchField(title: "부하 원본") {
                        WattlySegment(selection: $kineticNotchSource,
                                      options: KineticNotchSource.allCases.map { ($0, $0.label) },
                                      fontSize: 11.5, pillVPadding: 6)
                    }
                    kineticNotchField(title: "움직임 속도") {
                        VStack(alignment: .leading, spacing: 8) {
                            WattlySegment(selection: $kineticNotchSpeed,
                                          options: KineticNotchSpeed.allCases.map { ($0, $0.label) },
                                          fontSize: 11.5, pillVPadding: 6)
                            Text(kineticNotchSpeed.description)
                                .font(WattlyFont.at(11.5, weight: .regular))
                                .foregroundStyle(t.faint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    kineticNotchField(title: "실시간 속도") {
                        HStack(spacing: 8) {
                            if let previewLoad {
                                let frameRate = MenuBarIconMotion.frameRate(load: previewLoad, speed: kineticNotchSpeed) ?? 0
                                Text("\(Int(previewLoad.rounded()))% · \(frameRate, specifier: "%.1f") fps")
                                    .font(WattlyFont.at(11.5, weight: .medium))
                                    .foregroundStyle(t.faint)
                            } else {
                                Text("선택한 부하를 읽는 동안 아이콘은 정지합니다.")
                                    .font(WattlyFont.at(11.5, weight: .regular))
                                    .foregroundStyle(t.faint)
                            }
                        }
                    }
                }
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            .task(id: "\(iconStyle.rawValue)-\(kineticNotchMotionEnabled)-\(kineticNotchSpeed.rawValue)-\(previewFrameRate ?? 0)-\(reduceMotion)") {
                guard let frameRate = previewFrameRate,
                      kineticNotchMotionEnabled,
                      !reduceMotion else {
                    iconPreviewPhase = iconStyle.staticFrame
                    return
                }
                while !Task.isCancelled {
                    let phase = iconPreviewPhase
                    let delay = MenuBarIconMotion.frameDelay(style: iconStyle, phase: phase, frameRate: frameRate)
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    iconPreviewPhase = (phase + 1) % iconStyle.frameCount
                }
            }
        }
    }
```

- [ ] **Step 4: Build and verify compilation**

Run: `xcodebuild build -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit changes**

```bash
git add Wattly/Views/Settings/SettingsMenuBarSection.swift WattlyTests/SettingsMenuBarIconSectionTests.swift
git commit -m "feat(settings): add interactive icon style selector grid with live animation previews"
```

---

### Task 6: Full Integration Test & Verification

**Files:**
- Test: All test suites in `WattlyTests/`

**Interfaces:**
- Comprehensive regression testing across all metrics, settings reset, and menubar label behaviors.

- [ ] **Step 1: Run all unit tests**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData`
Expected: ALL TESTS PASS with 0 failures.

- [ ] **Step 2: Final commit**

```bash
git commit --allow-empty -m "chore: verify dynamic menubar icon themes and settings integration"
```
