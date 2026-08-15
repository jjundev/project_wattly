# Fan Curve Presets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Provide 4 community-proven fan curve presets (균형, 저소음, 성능, 최대) in Wattly Settings, allowing one-click selection while preserving custom curve dragging.

**Architecture:** Define a pure, testable `FanCurvePreset` enum in `FanControlShared` that maps presets to 15-anchor `FanCurve` instances and detects whether a curve matches a known preset. In `SettingsView.swift`, replace the single "기본값" button with a macOS-native preset `Menu` dropdown that displays the currently active preset (or "사용자 지정" when customized) and switches curves on tap.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI, XcodeGen, Swift Testing (`@Test`, `#expect`), macOS 14+ Apple Silicon.

## Global Constraints

- Target macOS 14.0+ on Apple Silicon and Swift 6 strict concurrency.
- Add no third-party dependencies or new persisted `@AppStorage` keys. The existing `StorageKey.fanCurve` remains the single source of truth for the active curve.
- Maintain full compatibility with `FanCurve.anchorsCelsius` (15 anchors: 30°C to 100°C in 5°C increments).
- `FanCurvePreset.balanced.curve` must exactly equal `Defaults.fanCurve`.
- When an active curve matches a preset, the UI displays that preset's name (`균형`, `저소음`, `성능`, `최대`). When modified, it displays `사용자 지정`.
- Preserve the zero-RPM hold range warning banner (`FanCurveGeometry.zeroRPMHoldRange`) for presets that include zero-RPM anchors (e.g. `저소음` with zero plateau through 50°C).
- Final test: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test`
- Final build: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`

---

## File Structure

| File | Responsibility |
|---|---|
| `FanControlShared/FanCurvePreset.swift` | [NEW] Defines `FanCurvePreset` enum, preset curve definitions for the 15 anchors, titles, and `matchingPreset(for:)` reverse-lookup. |
| `WattlyTests/FanCurvePresetTests.swift` | [NEW] Unit tests validating all preset curves: 15 anchors, finite values, non-negative, balanced identity with Defaults, silent zero-RPM hold range (`48...50`), and matching logic. |
| `Wattly/Views/SettingsView.swift` | [MODIFY] Replaces the static "기본값" button with the preset `Menu` picker displaying active preset name or "사용자 지정", with keyboard and VoiceOver accessibility. |
| `project.yml` / `Wattly.xcodeproj` | XcodeGen regeneration to register new source and test files. |

---

### Task 1: Create `FanCurvePreset` in `FanControlShared` and Unit Tests

**Files:**
- Create: `FanControlShared/FanCurvePreset.swift`
- Create: `WattlyTests/FanCurvePresetTests.swift`
- Modify: `Wattly.xcodeproj/project.pbxproj` (via `xcodegen generate`)

**Interfaces:**
- Produces:
  ```swift
  enum FanCurvePreset: String, CaseIterable, Sendable, Identifiable {
      case balanced = "균형"
      case silent = "저소음"
      case performance = "성능"
      case fullSpeed = "최대"

      var id: String { rawValue }
      var title: String { ... }
      var curve: FanCurve { ... }
      static func matchingPreset(for curve: FanCurve) -> FanCurvePreset?
  }
  ```

- [ ] **Step 1: Write failing unit tests for `FanCurvePreset`**

Create `WattlyTests/FanCurvePresetTests.swift`:

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
        #expect(FanCurveGeometry.zeroRPMHoldRange(for: silentCurve) == 48...50)
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
        #expect(maxCurve.rpms.allSatisfy { $0 == 7400 })
        #expect(FanCurvePreset.matchingPreset(for: maxCurve) == .fullSpeed)
    }

    @Test func customCurveReturnsNilMatchingPreset() {
        let custom = FanCurve(rpms: [1000, 1100, 1200, 1300, 1400, 1500, 1600, 1700, 1800, 1900, 2000, 2100, 2200, 2300, 2400])
        #expect(FanCurvePreset.matchingPreset(for: custom) == nil)
    }

    @Test func presetTitlesIncludeDescriptions() {
        #expect(FanCurvePreset.balanced.title == "균형 (기본값)")
        #expect(FanCurvePreset.silent.title == "저소음")
        #expect(FanCurvePreset.performance.title == "성능")
        #expect(FanCurvePreset.fullSpeed.title == "최대")
    }
}
```

- [ ] **Step 2: Implement `FanControlShared/FanCurvePreset.swift`**

Create `FanControlShared/FanCurvePreset.swift`:

```swift
import Foundation

/// Community-tested presets for CPU temperature → target fan RPM curves.
/// Mapped across the 15 temperature anchors (30°C to 100°C in 5°C steps).
enum FanCurvePreset: String, CaseIterable, Sendable, Identifiable {
    case balanced = "균형"
    case silent = "저소음"
    case performance = "성능"
    case fullSpeed = "최대"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced: return "균형 (기본값)"
        case .silent: return "저소음"
        case .performance: return "성능"
        case .fullSpeed: return "최대"
        }
    }

    var curve: FanCurve {
        switch self {
        case .balanced:
            return Defaults.fanCurve
        case .silent:
            // 30°C..50°C at 0 RPM (5 anchors), then ramp up to allow 48..50°C zero-RPM hold range
            return FanCurve(rpms: [0, 0, 0, 0, 0, 1000, 1500, 2000, 2600, 3400, 4400, 5600, 6600, 7200, 7400])
        case .performance:
            return FanCurve(rpms: [1500, 1800, 2200, 2800, 3500, 4200, 4800, 5400, 6000, 6500, 7000, 7400, 7400, 7400, 7400])
        case .fullSpeed:
            return FanCurve(rpms: Array(repeating: 7400.0, count: FanCurve.anchorsCelsius.count))
        }
    }

    static func matchingPreset(for curve: FanCurve) -> FanCurvePreset? {
        allCases.first { $0.curve == curve }
    }
}
```

- [ ] **Step 3: Run `xcodegen generate` and verify tests pass**

Run:
```bash
xcodegen generate
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
```
Expected: PASS with 382+ tests.

- [ ] **Step 4: Commit**

```bash
git add FanControlShared/FanCurvePreset.swift WattlyTests/FanCurvePresetTests.swift Wattly.xcodeproj/project.pbxproj
git commit -m "feat(fan): add FanCurvePreset enum with balanced, silent, performance, and max curves"
```

---

### Task 2: Integrate Preset Selector into `SettingsView`

**Files:**
- Modify: `Wattly/Views/SettingsView.swift:489-535`

**Interfaces:**
- Consumes: `FanCurvePreset`, `$fanCurve`, `$fanCurvePreview`
- Produces: Interactive preset `Menu` UI in `fanCurveSection` with current preset label ("균형", "저소음", "성능", "최대", or "사용자 지정").

- [ ] **Step 1: Update `SettingsView.swift` fan curve toolbar**

In `Wattly/Views/SettingsView.swift`, replace the entire toolbar `HStack` (lines 489-524) with:

```swift
                    HStack(spacing: 8) {
                        if let holdRange = FanCurveGeometry.zeroRPMHoldRange(for: fanCurvePreview ?? fanCurve) {
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Tokens.statusOrange.opacity(0.12))
                                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Tokens.statusOrange.opacity(0.8), lineWidth: 1))
                                    .frame(width: 14, height: 10)
                                Text("팬 상태 유지 구간")
                                    .font(WattlyFont.at(10.5, weight: .regular))
                                    .foregroundStyle(t.faint)
                                Button { isZeroFanHelpPresented = true } label: {
                                    Image(systemName: "questionmark.circle")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(t.faint)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("팬 상태 유지 구간 작동 방식 보기")
                                .popover(isPresented: $isZeroFanHelpPresented, arrowEdge: .bottom) {
                                    zeroFanHelpPopover(for: holdRange)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                        Spacer()
                        presetMenu
                    }
```

Add the `presetMenu` subview:

```swift
    private var presetMenu: some View {
        let currentPreset = FanCurvePreset.matchingPreset(for: fanCurvePreview ?? fanCurve)
        let labelText = currentPreset?.rawValue ?? "사용자 지정"

        return Menu {
            ForEach(FanCurvePreset.allCases) { preset in
                Button {
                    fanCurvePreview = nil
                    fanCurve = preset.curve
                } label: {
                    if currentPreset == preset {
                        Label(preset.title, systemImage: "checkmark")
                    } else {
                        Text(preset.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(labelText)
                    .font(WattlyFont.at(11, weight: .semibold))
                    .foregroundStyle(currentPreset != nil ? t.sub : Tokens.accent)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(t.faint)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(t.cardBg))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(t.rowBorder, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("팬 커브 프리셋 선택, 현재 \(labelText)")
    }
```

- [ ] **Step 2: Verify project builds and test suite passes**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
```
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add Wattly/Views/SettingsView.swift
git commit -m "feat(settings): add fan curve preset menu with custom curve indicator"
```

---

### Task 3: Full Verification and Build Validation

**Files:**
- None (verification task)

- [ ] **Step 1: Run full test suite**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
```
Expected: PASS (** TEST SUCCEEDED **)

- [ ] **Step 2: Run release/debug build check**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```
Expected: Build Succeeded with zero compiler warnings or errors.

---

## Verification Plan

### Automated Tests
- `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test` (Run unit tests including `FanCurvePresetTests`, `FanCurveGeometryTests`, `SettingsResetTests`, and all daemon tests)

### Manual Verification
1. Open Settings -> "팬 커브" section.
2. Verify the preset button shows "균형" by default.
3. Click preset button: observe 4 options (`균형 (기본값)`, `저소음`, `성능`, `최대`).
4. Select `저소음`: graph updates immediately with 0 RPM below 50°C, and "팬 상태 유지 구간" orange badge appears.
5. Select `성능`: curve shifts higher with 1500 RPM starting point.
6. Select `최대`: flat line at 7400 RPM across all anchors.
7. Drag any point on graph: label immediately changes to "사용자 지정".
8. Select `균형`: curve resets to default curve.
