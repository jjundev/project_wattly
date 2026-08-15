# Hardware-Adaptive Fan Curve Presets & Dynamic Y-Axis Scaling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically detect the host Mac's hardware maximum fan RPM via SMC (`F{n}Mx`), dynamically generate fan curve presets scaled to the detected hardware maximum (defaulting safely to 6500 RPM for fanless/fallback), and scale the fan curve editor's Y-axis grid, labels, anchor handles, and drag bounds to match.

**Architecture:** Extend `FanSample` and `SystemMonitor` to expose `hardwareMaxFanRPM`, update `FanCurvePreset` with a ratio-based `curve(forMaxRPM:)` builder rounded to 100-RPM increments, synchronize `Defaults.fanCurve` to `FanCurvePreset.balanced.curve`, update `FanCurveGeometry` to parameterize `rpmMax` (defaulting to 6500), and thread the detected maximum RPM through `SettingsView` into `FanCurveEditor` and preset selection.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Observation framework, macOS 14+ SMC / IOKit.

---

## Global Constraints

- Target macOS 14.0+ on Apple Silicon with Swift 6 strict concurrency complete mode.
- Add no third-party dependencies or new persisted `@AppStorage` keys.
- Preserve 15 anchors in `FanCurve.anchorsCelsius` (30°C to 100°C in 5°C steps).
- Maintain 100-RPM rounding on all computed anchor values.
- Maintain zero-RPM hold range detection (`48...55°C`) for presets and custom curves with 0 RPM below 55°C.
- Clean separation between `FanControlShared`, `Wattly`, and `WattlyTests`.

---

### Task 1: Core Data Model & Preset Scaling (`Fan.swift`, `FanCurvePreset.swift`, `Settings.swift`, `FanCurvePresetTests.swift`)

**Files:**
- Modify: `Wattly/Core/Fan.swift`
- Modify: `FanControlShared/FanCurvePreset.swift`
- Modify: `Wattly/Settings/Settings.swift`
- Modify: `WattlyTests/FanCurvePresetTests.swift`

**Interfaces:**
- Consumes: `FanReading`, `FanSample`, `FanCurve.anchorsCelsius`
- Produces: `FanSample.maxFanRPM: Double?`, `FanCurvePreset.defaultMaxRPM: Double = 6500`, `FanCurvePreset.curve(forMaxRPM: Double) -> FanCurve`, `FanCurvePreset.matchingPreset(for: FanCurve, maxRPM: Double) -> FanCurvePreset?`

- [ ] **Step 1: Write and update tests in `FanCurvePresetTests.swift`**

```swift
import Testing
@testable import Wattly

struct FanCurvePresetTests {
    @Test func allPresetsHaveValidAnchorCountAndFiniteRPMs() {
        for preset in FanCurvePreset.allCases {
            let curve = preset.curve
            #expect(curve.rpms.count == FanCurve.anchorsCelsius.count)
            #expect(curve.rpms.allSatisfy { $0.isFinite && (0.0...20_000.0).contains($0) })
        }
    }

    @Test func balancedPresetMatchesDefaultFanCurve() {
        #expect(FanCurvePreset.balanced.curve == Defaults.fanCurve)
        #expect(FanCurvePreset.matchingPreset(for: Defaults.fanCurve) == .balanced)
    }

    @Test func silentPresetProvidesZeroRPMHoldRange() {
        let silentCurve = FanCurvePreset.silent.curve
        #expect(silentCurve.rpms.first == 0)
        #expect(FanCurveGeometry.zeroRPMHoldRange(for: silentCurve) == 48...55)
        #expect(FanCurvePreset.matchingPreset(for: silentCurve) == .silent)
    }

    @Test func performancePresetHasHigherRPMsThanBalancedAtLowTemps() {
        let perfCurve = FanCurvePreset.performance.curve
        let balancedCurve = FanCurvePreset.balanced.curve
        #expect(perfCurve.rpms[0] > balancedCurve.rpms[0])
        #expect(FanCurvePreset.matchingPreset(for: perfCurve) == .performance)
    }

    @Test func fullSpeedPresetIsMaxRPMAtAllAnchors() {
        let maxCurve = FanCurvePreset.fullSpeed.curve
        #expect(maxCurve.rpms.allSatisfy { $0 == FanCurvePreset.defaultMaxRPM })
        #expect(FanCurvePreset.matchingPreset(for: maxCurve) == .fullSpeed)
    }

    @Test func presetsScaleToCustomHardwareMaxRPM() {
        let maxRPM = 5800.0
        let fullSpeed = FanCurvePreset.fullSpeed.curve(forMaxRPM: maxRPM)
        #expect(fullSpeed.rpms.allSatisfy { $0 == 5800 })
        #expect(FanCurvePreset.matchingPreset(for: fullSpeed, maxRPM: maxRPM) == .fullSpeed)

        let balanced = FanCurvePreset.balanced.curve(forMaxRPM: maxRPM)
        #expect(balanced.rpms.last == 5800)
        #expect(balanced.rpms.allSatisfy { $0.truncatingRemainder(dividingBy: 100) == 0 })
        #expect(FanCurvePreset.matchingPreset(for: balanced, maxRPM: maxRPM) == .balanced)

        let silent = FanCurvePreset.silent.curve(forMaxRPM: maxRPM)
        #expect(silent.rpms[0...5].allSatisfy { $0 == 0 }) // 30..55°C = 0
        #expect(silent.rpms.last == 5800)
        #expect(FanCurvePreset.matchingPreset(for: silent, maxRPM: maxRPM) == .silent)
    }

    @Test func customCurveReturnsNilMatchingPreset() {
        let custom = FanCurve(rpms: [1000, 1100, 1200, 1300, 1400, 1500, 1600, 1700, 1800, 1900, 2000, 2100, 2200, 2300, 2400])
        #expect(FanCurvePreset.matchingPreset(for: custom) == nil)
    }

    @Test func fanSampleComputesMaxFanRPM() {
        let sample = FanSample(fans: [
            FanReading(index: 0, actualRPM: 2000, minRPM: 1500, maxRPM: 5800, targetRPM: 2000),
            FanReading(index: 1, actualRPM: 2200, minRPM: 1500, maxRPM: 6200, targetRPM: 2200)
        ])
        #expect(sample.maxFanRPM == 6200)

        let emptySample = FanSample(fans: [])
        #expect(emptySample.maxFanRPM == nil)
    }

    @Test func presetTitlesIncludeDescriptions() {
        #expect(FanCurvePreset.balanced.title == "균형 (기본값)")
        #expect(FanCurvePreset.silent.title == "저소음")
        #expect(FanCurvePreset.performance.title == "성능")
        #expect(FanCurvePreset.fullSpeed.title == "최대")
    }
}
```

- [ ] **Step 2: Update `Wattly/Settings/Settings.swift` to align `Defaults.fanCurve`**

In `Wattly/Settings/Settings.swift`:
```swift
    static let fanCurve = FanCurve(rpms: [800, 900, 1000, 1200, 1500, 1900, 2400, 3000, 3600, 4200, 4800, 5500, 6000, 6300, 6500])
```

- [ ] **Step 3: Run tests to verify they pass**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test`
Expected: PASS

- [ ] **Step 4: Commit Task 1**

```bash
git add Wattly/Core/Fan.swift FanControlShared/FanCurvePreset.swift Wattly/Settings/Settings.swift WattlyTests/FanCurvePresetTests.swift
git commit -m "feat(fan): add hardware-adaptive curve scaling to FanCurvePreset and sync Defaults"
```

---

### Task 2: Geometry & UI Dynamic Scaling (`FanCurveGeometry.swift`, `FanCurveEditor.swift`, `FanCurveGeometryTests.swift`)

**Files:**
- Modify: `Wattly/Core/FanCurveGeometry.swift`
- Modify: `Wattly/Views/FanCurveEditor.swift`
- Modify: `WattlyTests/FanCurveGeometryTests.swift`

**Interfaces:**
- Consumes: `FanCurveGeometry.defaultRpmMax: Double = 6500`
- Produces: `FanCurveGeometry.y(forRPM:rpmMax:in:)`, `FanCurveGeometry.rpm(forY:rpmMax:in:)`, `FanCurveGeometry.handlePoints(_:rpmMax:in:)`, `FanCurveEditor.rpmMax: Double`

- [ ] **Step 1: Write and update tests in `FanCurveGeometryTests.swift`**

```swift
    @Test func yAndRpmScaleDynamicallyWithCustomRpmMax() {
        let size = CGSize(width: 300, height: 150)
        let customMax = 6000.0
        let yAtTop = FanCurveGeometry.y(forRPM: 6000, rpmMax: customMax, in: size)
        let plot = FanCurveGeometry.plotRect(in: size)
        #expect(yAtTop == plot.minY)

        let rpmAtMid = FanCurveGeometry.rpm(forY: (plot.minY + plot.maxY) / 2, rpmMax: customMax, in: size)
        #expect(rpmAtMid == 3000)
    }

    @Test func rpmForYClampsAboveTheTopToRpmMax() {
        let size = CGSize(width: 300, height: 150)
        #expect(FanCurveGeometry.rpm(forY: -50, in: size) == FanCurveGeometry.defaultRpmMax)
        #expect(FanCurveGeometry.rpm(forY: -50, rpmMax: 8000, in: size) == 8000)
    }
```

- [ ] **Step 2: Update `FanCurveGeometry.swift` and `FanCurveEditor.swift`**

In `Wattly/Core/FanCurveGeometry.swift`:
```swift
    static let defaultRpmMax: Double = 6500
    static let rpmMin: Double = 0
    static let rpmStep: Double = 100

    static func y(forRPM rpm: Double, rpmMax: Double = defaultRpmMax, in size: CGSize) -> CGFloat {
        let rect = plotRect(in: size)
        let clamped = min(max(rpm, rpmMin), rpmMax)
        let t = (clamped - rpmMin) / (rpmMax - rpmMin)
        return rect.maxY - CGFloat(t) * rect.height
    }

    static func rpm(forY y: CGFloat, rpmMax: Double = defaultRpmMax, in size: CGSize) -> Double {
        let rect = plotRect(in: size)
        let clampedY = min(max(y, rect.minY), rect.maxY)
        let t = Double((rect.maxY - clampedY) / rect.height)
        let raw = rpmMin + t * (rpmMax - rpmMin)
        return (raw / rpmStep).rounded() * rpmStep
    }

    static func handlePoints(_ rpms: [Double], rpmMax: Double = defaultRpmMax, in size: CGSize) -> [CGPoint] {
        guard rpms.count == anchorsCelsius.count else { return [] }
        return zip(anchorsCelsius, rpms).map { c, r in
            CGPoint(x: x(forCelsius: c, in: size), y: y(forRPM: r, rpmMax: rpmMax, in: size))
        }
    }
```

In `Wattly/Views/FanCurveEditor.swift`:
- Add `var rpmMax: Double = FanCurveGeometry.defaultRpmMax`
- In `canvas(_ size: CGSize)`:
  Compute grid stride from `stride(from: 0.0, through: rpmMax, by: 2000)` and draw corresponding labels.
  Pass `rpmMax` to `FanCurveGeometry.handlePoints(rpms, rpmMax: rpmMax, in: size)` and `FanCurveGeometry.y(forRPM:..., rpmMax: rpmMax, in: size)`.
- In `drag(in size: CGSize)`:
  Pass `rpmMax` to `FanCurveGeometry.rpm(forY: value.location.y, rpmMax: rpmMax, in: size)`.
- In `nudge(_ delta: Double, at index: Int)`:
  Clamp to `self.rpmMax`: `let clamped = min(max(curve.rpms[index] + delta, FanCurveGeometry.rpmMin), rpmMax)`.
- In `anchorControls(_ size: CGSize)`:
  Pass `rpmMax` to `FanCurveGeometry.handlePoints(displayRPMs, rpmMax: rpmMax, in: size)`.

- [ ] **Step 3: Run tests to verify they pass**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test`
Expected: PASS

- [ ] **Step 4: Commit Task 2**

```bash
git add Wattly/Core/FanCurveGeometry.swift Wattly/Views/FanCurveEditor.swift WattlyTests/FanCurveGeometryTests.swift
git commit -m "feat(fan): support dynamic rpmMax in FanCurveGeometry and FanCurveEditor"
```

---

### Task 3: SystemMonitor & SettingsView Integration (`SystemMonitor.swift`, `SettingsView.swift`)

**Files:**
- Modify: `Wattly/Core/SystemMonitor.swift`
- Modify: `Wattly/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `SystemMonitor.hardwareMaxFanRPM: Double?`, `FanCurvePreset.curve(forMaxRPM:)`, `FanCurveEditor(rpmMax:)`
- Produces: Live hardware-adaptive preset switching and live-scaled Y-axis graph in Settings

- [ ] **Step 1: Add `hardwareMaxFanRPM` helper to `SystemMonitor.swift`**

```swift
    /// The maximum hardware RPM reported by SMC across all detected fans, or nil if unavailable/fanless.
    var hardwareMaxFanRPM: Double? {
        guard let state = states[.fan],
              case .value(let sample) = state,
              case .fan(let fanSample) = sample else { return nil }
        return fanSample.maxFanRPM
    }
```

- [ ] **Step 2: Update `SettingsView.swift` to use `hardwareMaxFanRPM`**

In `SettingsView.swift`:
- Determine active max RPM:
  ```swift
  private var activeMaxFanRPM: Double {
      monitor.hardwareMaxFanRPM ?? FanCurvePreset.defaultMaxRPM
  }
  ```
- Update `selectedPresetBinding`:
  ```swift
  private var selectedPresetBinding: Binding<FanCurvePreset?> {
      Binding(
          get: { FanCurvePreset.matchingPreset(for: fanCurvePreview ?? fanCurve, maxRPM: activeMaxFanRPM) },
          set: { preset in
              if let preset {
                  fanCurvePreview = nil
                  fanCurve = preset.curve(forMaxRPM: activeMaxFanRPM)
              }
          }
      )
  }
  ```
- Pass `rpmMax: activeMaxFanRPM` to `FanCurveEditor(curve: $fanCurve, previewCurve: $fanCurvePreview, currentCPU: currentHottestCPU, rpmMax: activeMaxFanRPM)`.

- [ ] **Step 3: Run test suite & build**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test`
Expected: PASS with 382+ tests passing.

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit Task 3**

```bash
git add Wattly/Core/SystemMonitor.swift Wattly/Views/SettingsView.swift
git commit -m "feat(settings): wire hardware-adaptive fan curve presets and dynamic editor Y-axis"
```

---

## Verification Plan

### Automated Tests
- `FanCurvePresetTests`: Test ratio scaling with custom max RPM (e.g. 5800, 6550, 7200), zero-RPM hold range preservation, and reverse lookup.
- `FanCurveGeometryTests`: Test Y mapping and drag inversions with various `rpmMax` values.
- Full test suite: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test`

### Manual Verification
- Launch `Wattly.app` on the live M5 Mac.
- Open Settings -> Fan Curve.
- Verify the Y-axis top tick dynamically matches the SMC max RPM (around 6.5k).
- Select each preset (`균형`, `저소음`, `성능`, `최대`) and verify the curves scale proportionally up to the machine's maximum RPM.
