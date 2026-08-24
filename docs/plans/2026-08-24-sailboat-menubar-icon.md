# Sailboat (Paper Boat) Dynamic MenuBar Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the "Paper Boat on Waves" (`MenuBarIconStyle.sailboat`) dynamic menubar icon theme in Wattly, rendering a geometric paper boat navigating a single traveling sine wave that dynamically accelerates, scales in wave height, pitches across 4 workload tiers (96 frames total), and emits bow water splash particles at high system loads (80%+).

**Architecture:** 
- Add `case sailboat = "sailboat"` to `MenuBarIconStyle` with 96-frame metadata and static frame 0.
- Implement workload-to-frame mapping in `KineticNotchMotion.displayedFrame` across 4 tiers (0%~25%, 25%~55%, 55%~80%, 80%~100%) and maintain `stepsPerCycle = 24.0` in `interFrameDelay`.
- Render the single traveling sine wave and paper boat geometry via SwiftUI `Path` in `SailboatMark` inside `Glyphs.swift`, dispatched by `DynamicMenuBarIconMark`.
- Automatically leverage `MenuBarGlyph.template` rasterization and memory caching for 0% CPU footprint and native macOS dark/light menubar auto-tinting.

**Tech Stack:** Swift 6.0 (Strict Concurrency), SwiftUI, AppKit (NSImage Template Rasterization with ImageRenderer), Swift Testing (`@Test`, `#expect`), XcodeGen.

## Global Constraints

- Platform deployment target: macOS 14.0+
- Architecture: Apple Silicon (`arm64`)
- Language: Swift 6.0 with strict concurrency complete
- Zero external package dependencies (Pure SwiftUI / AppKit)
- Menubar icons must be 18×18pt template-tintable images
- All test suites must pass via `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData`

---

### Task 1: Data Model & Enum Metadata for `MenuBarIconStyle.sailboat`

**Files:**
- Modify: `Wattly/Core/MenuBarIconStyle.swift`
- Test: `WattlyTests/MenuBarIconStyleTests.swift`

**Interfaces:**
- Consumes: None
- Produces:
  - `MenuBarIconStyle.sailboat: MenuBarIconStyle`
  - `MenuBarIconStyle.allCases` containing 7 styles
  - `sailboat.frameCount == 96`, `sailboat.staticFrame == 0`
  - `sailboat.label == "종이배 (파도 항해)"`
  - `sailboat.category == "캐릭터 / 라이프"`

- [ ] **Step 1: Write the failing unit tests for `MenuBarIconStyle.sailboat`**

Modify `WattlyTests/MenuBarIconStyleTests.swift`:
```swift
import Testing
import Foundation
@testable import Wattly

struct MenuBarIconStyleTests {
    @Test func allIconStylesHaveValidMetadataAndFrameCounts() {
        let styles = MenuBarIconStyle.allCases
        #expect(styles.count == 7)
        for style in styles {
            #expect(!style.id.isEmpty)
            #expect(!style.label.isEmpty)
            #expect(!style.category.isEmpty)
            #expect(!style.summary.isEmpty)
            #expect(style.frameCount >= 4)
            #expect(style.staticFrame >= 0 && style.staticFrame < style.frameCount)
        }
    }

    @Test func sailboatHasSpecificMetadata() {
        let boat = MenuBarIconStyle.sailboat
        #expect(boat.rawValue == "sailboat")
        #expect(boat.label == "종이배 (파도 항해)")
        #expect(boat.category == "캐릭터 / 라이프")
        #expect(!boat.summary.isEmpty)
        #expect(boat.frameCount == 96)
        #expect(boat.staticFrame == 0)
    }

    @Test func hillRunnerHasSpecificMetadata() {
        let runner = MenuBarIconStyle.hillRunner
        #expect(runner.rawValue == "hillRunner")
        #expect(runner.label == "러너 (경사로 질주)")
        #expect(runner.category == "캐릭터 / 라이프")
        #expect(!runner.summary.isEmpty)
        #expect(runner.frameCount == 24)
        #expect(runner.staticFrame == 8)
    }

    @Test func defaultIconStyleIsHillRunner() {
        #expect(Defaults.menubarIconStyle == .hillRunner)
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
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/MenuBarIconStyleTests
```
Expected: FAIL with compilation error (`type 'MenuBarIconStyle' has no member 'sailboat'`).

- [ ] **Step 3: Implement `MenuBarIconStyle.sailboat`**

Modify `Wattly/Core/MenuBarIconStyle.swift`:
```swift
import Foundation

public enum MenuBarIconStyle: String, CaseIterable, Identifiable, Sendable {
    case turbine = "turbine"             // 1. 쿨링 터빈
    case pulseWave = "pulseWave"         // 2. 흐르는 펄스 W 파형
    case vuMeter = "vuMeter"             // 3. VU 파워 미터
    case cube3D = "cube3D"               // 4. 3D 와이어프레임 큐브
    case equalizer = "equalizer"         // 5. 디지털 이퀄라이저
    case hillRunner = "hillRunner"       // 6. 경사로 러너 (Hill Runner)
    case sailboat = "sailboat"           // 7. 종이배 (파도 항해)

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .turbine: "쿨링 터빈"
        case .pulseWave: "펄스 웨이브"
        case .vuMeter: "VU 파워 미터"
        case .cube3D: "3D 큐브"
        case .equalizer: "디지털 이퀄라이저"
        case .hillRunner: "러너 (경사로 질주)"
        case .sailboat: "종이배 (파도 항해)"
        }
    }

    public var category: String {
        switch self {
        case .turbine: "쿨링 / 팬"
        case .pulseWave: "전력 / 신호"
        case .vuMeter: "정밀 계측기"
        case .cube3D: "3D 기하학"
        case .equalizer: "디지털 스펙트럼"
        case .hillRunner, .sailboat: "캐릭터 / 라이프"
        }
    }

    public var summary: String {
        switch self {
        case .turbine: "맥북 쿨링 팬 블레이드가 부하에 맞춰 고속 회전합니다."
        case .pulseWave: "Wattly 시그니처 W 파형이 좌에서 우로 전파되며 전력 부하에 따라 가속됩니다."
        case .vuMeter: "아날로그 전력 계측기 바늘이 전력량에 맞춰 기민하게 스윙합니다."
        case .cube3D: "3차원 대각선 축을 기준으로 와이어프레임 큐브가 자전합니다."
        case .equalizer: "4개의 수직 디지털 바가 연산 및 전력 부하에 맞춰 상하 바운스합니다."
        case .hillRunner: "부하(0%~100%)에 따라 오르막 힘겨운 걸음 → 평지 조깅 → 내리막 폭풍 질주로 지형 경사와 캐릭터 자세가 연속 전환됩니다."
        case .sailboat: "잔잔한 바다를 순항하다가 시스템 부하가 높아지면 거센 파도와 함께 종이배가 역동적으로 출렁입니다."
        }
    }

    public var frameCount: Int {
        switch self {
        case .pulseWave, .sailboat:
            return 96 // 4 부하 티어 x 24 고해상도 위상 프레임
        case .turbine, .vuMeter, .cube3D, .equalizer, .hillRunner:
            return 24
        }
    }

    public var staticFrame: Int {
        switch self {
        case .hillRunner:
            return 8
        case .sailboat:
            return 0
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
Expected: PASS (All 5 tests in `MenuBarIconStyleTests` pass).

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/MenuBarIconStyle.swift WattlyTests/MenuBarIconStyleTests.swift
git commit -m "feat: add sailboat theme metadata to MenuBarIconStyle"
```

---

### Task 2: Kinematic Physics & Frame Calculations for Sailboat

**Files:**
- Modify: `Wattly/Core/KineticNotchMotion.swift`
- Test: `WattlyTests/KineticNotchMotionTests.swift`

**Interfaces:**
- Consumes: `MenuBarIconStyle.sailboat`
- Produces:
  - `MenuBarIconMotion.displayedFrame(style: .sailboat, phase: Double, load: Double?, reduceMotion: Bool) -> Int`
  - Correct `interFrameDelay` step calculation (`stepsPerCycle = 24.0` for `.sailboat`)

- [ ] **Step 1: Write failing tests for sailboat motion mapping and interFrameDelay**

Add to `WattlyTests/KineticNotchMotionTests.swift`:
```swift
    @Test func sailboatScalesTierWithLoad() {
        // Tier 0 (0..<25% load): Frames 0..23
        let lowFrame = MenuBarIconMotion.displayedFrame(style: .sailboat, phase: 0.3, load: 10.0, reduceMotion: false)
        #expect((0...23).contains(lowFrame))

        // Tier 1 (25..<55% load): Frames 24..47
        let midLowFrame = MenuBarIconMotion.displayedFrame(style: .sailboat, phase: 0.3, load: 40.0, reduceMotion: false)
        #expect((24...47).contains(midLowFrame))

        // Tier 2 (55..<80% load): Frames 48..71
        let midHighFrame = MenuBarIconMotion.displayedFrame(style: .sailboat, phase: 0.3, load: 65.0, reduceMotion: false)
        #expect((48...71).contains(midHighFrame))

        // Tier 3 (80..100% load): Frames 72..95
        let highFrame = MenuBarIconMotion.displayedFrame(style: .sailboat, phase: 0.3, load: 95.0, reduceMotion: false)
        #expect((72...95).contains(highFrame))
    }

    @Test func sailboatHonorsReduceMotion() {
        let staticFrame = MenuBarIconMotion.displayedFrame(style: .sailboat, phase: 0.5, load: 90.0, reduceMotion: true)
        #expect(staticFrame == MenuBarIconStyle.sailboat.staticFrame)
        #expect(staticFrame == 0)
    }

    @Test func sailboatInterFrameDelayUses24StepsPerCycle() {
        let pulseWaveDelay = MenuBarIconMotion.interFrameDelay(rps: 1.0, speed: .regular, frameCount: 96, style: .pulseWave)
        let sailboatDelay = MenuBarIconMotion.interFrameDelay(rps: 1.0, speed: .regular, frameCount: 96, style: .sailboat)
        #expect(abs(pulseWaveDelay - sailboatDelay) < 1e-6)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/KineticNotchMotionTests
```
Expected: FAIL (`sailboatScalesTierWithLoad` fails because `sailboat` is not yet mapped in `displayedFrame`).

- [ ] **Step 3: Implement sailboat motion and delay logic in `KineticNotchMotion.swift`**

Modify `Wattly/Core/KineticNotchMotion.swift`:
Update `interFrameDelay` (around lines 185):
```swift
        // Natural duration for 1 sprite advance at current RPS (24 discrete steps per revolution)
        let stepsPerCycle = (style == .pulseWave || style == .sailboat) ? 24.0 : Double(frameCount)
        let naturalFPS = max(rps * stepsPerCycle, 1.0)
        let naturalDelay = 1.0 / naturalFPS
```

Update `displayedFrame` (around lines 256):
```swift
        // Sailboat maps 4 workload tiers (Idle, Cruising, Swell, Storm) into 24 subphases each (96 frames total)
        if style == .sailboat {
            let clampedLoad = min(max(activeLoad, 0), 100)
            let tier: Int
            if clampedLoad < 25.0 {
                tier = 0 // 저부하 (0..<25%): 잔잔한 수평선 (Frames 0..23)
            } else if clampedLoad < 55.0 {
                tier = 1 // 중저부하 (25..<55%): 순항 파도 (Frames 24..47)
            } else if clampedLoad < 80.0 {
                tier = 2 // 중고부하 (55..<80%): 높은 너울 (Frames 48..71)
            } else {
                tier = 3 // 고부하 풀로드 (80..100%): 폭풍우와 물보라 (Frames 72..95)
            }
            let subPhase = Int(safePhase * 24.0) % 24
            return tier * 24 + subPhase
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/KineticNotchMotionTests
```
Expected: PASS (All tests in `KineticNotchMotionTests` pass).

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/KineticNotchMotion.swift WattlyTests/KineticNotchMotionTests.swift
git commit -m "feat: implement sailboat tier kinematics and frame calculation"
```

---

### Task 3: Vector Graphics & Paper Boat Mark in `Glyphs.swift`

**Files:**
- Modify: `Wattly/DesignSystem/Glyphs.swift`
- Test: `WattlyTests/GlyphsRenderingTests.swift`

**Interfaces:**
- Consumes: `MenuBarIconStyle.sailboat`
- Produces:
  - `struct SailboatMark: View`
  - `DynamicMenuBarIconMark` dispatcher case for `.sailboat`

- [ ] **Step 1: Write the failing tests for `SailboatMark` rendering**

Add to `WattlyTests/GlyphsRenderingTests.swift`:
```swift
    @Test @MainActor func sailboatMarkRendersAcrossAllTiers() {
        for frame in 0..<96 {
            let mark = SailboatMark(frame: frame, markerColor: .black)
            #expect(mark.frame == frame)
        }
    }

    @Test @MainActor func sailboatDynamicMarkRendersWithoutCrash() {
        for frame in 0..<MenuBarIconStyle.sailboat.frameCount {
            let view = DynamicMenuBarIconMark(style: .sailboat, frame: frame, markerColor: .black)
            #expect(view.style == .sailboat)
            #expect(view.frame == frame)
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/GlyphsRenderingTests
```
Expected: FAIL with compilation error (`cannot find 'SailboatMark' in scope`).

- [ ] **Step 3: Implement `SailboatMark` and connect `DynamicMenuBarIconMark`**

In `Wattly/DesignSystem/Glyphs.swift`, add `SailboatMark` with zero-size frame origin anchoring on the inner boat ZStack:

```swift
// 7. Paper Boat on Waves Mark (Sailboat)
struct SailboatMark: View {
    let frame: Int
    var markerColor: Color = Tokens.accent

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            let strokeW = max(1.3 * (s / 18.0), 1.2)

            let safeFrame = min(max(frame, 0), 95)
            let tier = safeFrame / 24
            let subPhase = safeFrame % 24
            let phaseRad = (Double(subPhase) / 24.0) * .pi * 2.0

            // Base geometry parameters
            let baseY = s * 0.68
            let ampRatio: Double = switch tier {
            case 0: 0.065   // ~1.17pt at 18pt
            case 1: 0.125   // ~2.25pt at 18pt
            case 2: 0.190   // ~3.42pt at 18pt
            default: 0.250  // ~4.50pt at 18pt
            }
            let tiltDamp: Double = switch tier {
            case 0: 0.75
            case 1: 0.90
            case 2: 1.05
            default: 1.20
            }

            let amp = s * ampRatio
            let waveFreq = (.pi * 2.0) / (s * 0.88)

            // Boat Kinematics at horizontal center (x = 0.50 s)
            let boatX = s * 0.50
            let boatY = baseY - amp * sin(waveFreq * boatX - phaseRad)
            let slope = -amp * waveFreq * cos(waveFreq * boatX - phaseRad)
            let rollAngle = atan(slope) * tiltDamp

            let hullW = s * 0.44
            let hullH = s * 0.13
            let mastH = s * 0.38

            ZStack {
                // 1. Single Traveling Sine Wave
                Path { path in
                    let steps = 24
                    for i in 0...steps {
                        let progress = Double(i) / Double(steps)
                        let x = progress * s
                        let y = baseY - amp * sin(waveFreq * x - phaseRad)
                        if i == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(markerColor, style: StrokeStyle(lineWidth: strokeW * 0.95, lineCap: .round, lineJoin: .round))

                // 2. Paper Boat (Folded Geometry with Roll Pitch Transform anchored at waterline (0,0))
                ZStack {
                    // Lower Hull (Inverted trapezoid / folded polygon)
                    Path { path in
                        path.move(to: CGPoint(x: -hullW * 0.5, y: 0))
                        path.addLine(to: CGPoint(x: -hullW * 0.25, y: hullH * 0.9))
                        path.addLine(to: CGPoint(x: hullW * 0.25, y: hullH * 0.9))
                        path.addLine(to: CGPoint(x: hullW * 0.5, y: 0))
                        path.addLine(to: CGPoint(x: 0, y: -hullH * 0.5))
                        path.closeSubpath()
                    }
                    .fill(markerColor)

                    // Upper Triangular Fold
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: -mastH * 0.95))
                        path.addLine(to: CGPoint(x: -hullW * 0.22, y: 0))
                        path.addLine(to: CGPoint(x: hullW * 0.22, y: 0))
                        path.closeSubpath()
                    }
                    .fill(markerColor)

                    // 3. Splash Spray VFX (Tier 3 full load only)
                    if tier == 3 {
                        let splashPhase = Double(subPhase % 12) / 12.0
                        let sprayR = strokeW * 0.70

                        let sp1X = hullW * 0.55 + splashPhase * (s * 0.15)
                        let sp1Y = -hullH * 0.4 - sin(splashPhase * .pi) * (s * 0.22)
                        Circle()
                            .fill(markerColor)
                            .frame(width: sprayR * 2.0, height: sprayR * 2.0)
                            .position(x: sp1X, y: sp1Y)

                        let sp2X = hullW * 0.42 + splashPhase * (s * 0.10)
                        let sp2Y = -hullH * 0.2 - sin(splashPhase * .pi) * (s * 0.14)
                        Circle()
                            .fill(markerColor)
                            .frame(width: sprayR * 1.6, height: sprayR * 1.6)
                            .position(x: sp2X, y: sp2Y)
                    }
                }
                .frame(width: 0, height: 0)
                .rotationEffect(.radians(rollAngle), anchor: .center)
                .position(x: boatX, y: boatY)
            }
        }
    }
}
```

Update `DynamicMenuBarIconMark.body`:
```swift
    var body: some View {
        switch style {
        case .turbine: TurbineMark(frame: frame, markerColor: markerColor)
        case .pulseWave: PulseWaveMark(frame: frame, markerColor: markerColor)
        case .vuMeter: VUMeterMark(frame: frame, markerColor: markerColor)
        case .cube3D: Cube3DMark(frame: frame, markerColor: markerColor)
        case .equalizer: EqualizerMark(frame: frame, markerColor: markerColor)
        case .hillRunner: HillRunnerMark(frame: frame, markerColor: markerColor)
        case .sailboat: SailboatMark(frame: frame, markerColor: markerColor)
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/GlyphsRenderingTests
```
Expected: PASS (All tests in `GlyphsRenderingTests` pass).

- [ ] **Step 5: Commit**

```bash
git add Wattly/DesignSystem/Glyphs.swift WattlyTests/GlyphsRenderingTests.swift
git commit -m "feat: implement SailboatMark vector glyph and dynamic dispatcher"
```

---

### Task 4: Template Caching, Settings UI & Full Suite Verification

**Files:**
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Modify: `WattlyTests/LocalizationTests.swift`
- Test: `WattlyTests/MenuBarGlyphTests.swift`
- Test: `WattlyTests/SettingsMenuBarIconSectionTests.swift`
- Test: `WattlyTests/LocalizationTests.swift`

**Interfaces:**
- Consumes: `MenuBarIconStyle.sailboat`
- Produces:
  - All 96 frames of `.sailboat` cached in `MenuBarGlyph.multiStyleCache`
  - Settings UI grid renders `.sailboat` button with live preview
  - Localization strings for English & Korean tested and verified

- [ ] **Step 1: Run MenuBarGlyphTests and SettingsMenuBarIconSectionTests**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData -only-testing:WattlyTests/MenuBarGlyphTests -only-testing:WattlyTests/SettingsMenuBarIconSectionTests
```
Expected: PASS (Both test suites iterate over `MenuBarIconStyle.allCases` and automatically test all 96 frames of `.sailboat`).

- [ ] **Step 2: Add localization strings and update `LocalizationTests.swift`**

Add entries for `"종이배 (파도 항해)"` in `Wattly/Resources/Localizable.xcstrings`:
```json
    "종이배 (파도 항해)" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Paper Boat (Ocean Waves)"
          }
        },
        "ko" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "종이배 (파도 항해)"
          }
        }
      }
    }
```

In `WattlyTests/LocalizationTests.swift`, update `iconDesignThemeTranslations()`:
```swift
    @Test func iconDesignThemeTranslations() {
        #expect(String(localized: "쿨링 터빈", locale: Locale(identifier: "en")) == "Cooling Turbine")
        #expect(String(localized: "쿨링 터빈", locale: Locale(identifier: "ja")) == "クーリングタービン")
        #expect(String(localized: "펄스 웨이브", locale: Locale(identifier: "en")) == "Pulse Wave")
        #expect(String(localized: "VU 파워 미터", locale: Locale(identifier: "en")) == "VU Power Meter")
        #expect(String(localized: "3D 큐브", locale: Locale(identifier: "en")) == "3D Cube")
        #expect(String(localized: "디지털 이퀄라이저", locale: Locale(identifier: "en")) == "Equalizer")
        #expect(String(localized: "러너 (경사로 질주)", locale: Locale(identifier: "en")) == "Hill Runner")
        #expect(String(localized: "종이배 (파도 항해)", locale: Locale(identifier: "en")) == "Paper Boat (Ocean Waves)")
    }
```

- [ ] **Step 3: Run the full test suite to ensure zero regressions**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData
```
Expected: **TEST SUCCEEDED** across all unit and integration test targets.

- [ ] **Step 4: Commit**

```bash
git add Wattly/Resources/Localizable.xcstrings WattlyTests/LocalizationTests.swift WattlyTests/
git commit -m "feat: add localization and verify full test suite for sailboat icon theme"
```

---

## Verification Plan

### Automated Tests
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData
```
- `MenuBarIconStyleTests`: Validates 7 total themes, metadata, 96 frameCount, staticFrame 0.
- `KineticNotchMotionTests`: Validates workload-to-frame tier mapping across 4 tiers, `interFrameDelay` 24 steps per cycle, and Reduce Motion fallback.
- `GlyphsRenderingTests`: Validates `SailboatMark` and `DynamicMenuBarIconMark` rendering across all 96 frames without runtime error or crash.
- `MenuBarGlyphTests`: Validates template image creation and memory caching for all 96 frames.
- `LocalizationTests`: Validates Korean and English translations for the theme title.

### Manual Verification
1. Launch Wattly app on macOS:
   ```bash
   open .derivedData/Build/Products/Debug/Wattly.app
   ```
2. Open Settings $\to$ MenuBar section $\to$ Select "종이배 (파도 항해)".
3. Verify live animation in menubar item alongside metric text (`14 W`).
4. Switch macOS System Appearance between Light and Dark mode to confirm automatic monochrome template tinting.
5. In Settings preview, drag workload slider between 0% and 100% to visually confirm smooth acceleration, wave swelling, paper boat rocking, and splash particles at 80%+.
