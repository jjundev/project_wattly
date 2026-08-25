# Simplify Battery Heat Protection into Fixed 35°C Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Simplify the Battery Heat Protection feature in the settings view by removing the redundant and deadlock-prone temperature preset segment picker (`[32°C, 35°C, 38°C, 40°C]`) and converting it into a clean, intuitive On/Off toggle fixed at 35°C (with 33°C resume).

**Architecture:** Remove the preset segment picker UI in `SettingsBatterySection`, update the toggle description text to explain the 35°C pause / 33°C resume behavior, clean up presentation helpers, and update the test suites accordingly while preserving protocol backward compatibility.

**Tech Stack:** Swift 5.9+, SwiftUI, Swift Testing (`Testing`).

## Global Constraints

- Target macOS 14.0 and later on Apple Silicon arm64; no Intel path.
- Add no third-party dependencies.
- Preserve backward and forward compatibility across the privileged XPC interface for older helpers and app versions.
- The full validation gate is `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData` and `xcodebuild build -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData`.

---

### Task 1: Update UI in SettingsBatterySection & Localizable Strings

**Files:**
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift:15-30,147-182,354-407`
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Test: `WattlyTests/SettingsBatterySectionTests.swift`

**Interfaces:**
- Consumes: `Defaults.batteryHeatProtectionThreshold == 35`, `BatteryControlClient.apply`
- Produces: Streamlined `SettingsBatterySection` without the threshold picker segment.

- [ ] **Step 1: Write the failing test**

In `WattlyTests/SettingsBatterySectionTests.swift`:
Update `SettingsBatterySectionTests.swift` to assert that heat protection defaults remain consistent at 35°C and verify the toggle row text and settings representation.

```swift
    @Test func heatProtectionToggleConfigurationIsFixedAt35() {
        #expect(Defaults.batteryHeatProtectionThreshold == 35)
        #expect(Defaults.batteryHeatProtectionEnabled == false)
    }
```

- [ ] **Step 2: Run test to verify it passes or fails**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing:WattlyTests/SettingsBatterySectionTests`
Expected: PASS (or fail if old segment test still present)

- [ ] **Step 3: Update SettingsBatterySection & Localizable strings**

In `Wattly/Views/Settings/SettingsBatterySection.swift`:
1. Remove `@AppStorage(StorageKey.batteryHeatProtectionThreshold)` property wrapper from `SettingsBatterySection`.
2. Update the Heat Protection toggle row description:
```swift
SettingsToggleRow(isOn: $batteryHeatProtectionEnabled,
                  divider: false,
                  isEnabled: isToggleEnabled) {
    VStack(alignment: .leading, spacing: 2) {
        SettingsRowTitle("발열 보호 (Heat Protection)")
        Text("배터리 온도가 35°C를 초과하면 충전을 일시 중단하고, 33°C 이하로 냉각되면 재개합니다.")
            .font(WattlyFont.at(10.5, weight: .regular))
            .foregroundStyle(t.faint)
            .fixedSize(horizontal: false, vertical: true)
    }
}
```
3. Remove the `if batteryHeatProtectionEnabled { VStack { ... WattlySegment ... } }` segment picker block and its surrounding padding.
4. In action handlers and `.onChange(of: batteryHeatProtectionEnabled)`, pass `Defaults.batteryHeatProtectionThreshold` (35) as the threshold.
5. Remove `.onChange(of: batteryHeatProtectionThreshold)`.

In `Wattly/Resources/Localizable.xcstrings`:
Add/update the localized description key `"배터리 온도가 35°C를 초과하면 충전을 일시 중단하고, 33°C 이하로 냉각되면 재개합니다."` with translations across supported languages (e.g. English: `"Pauses charging when battery temperature exceeds 35°C and resumes when cooled down to 33°C or below."`, Japanese: `"バッテリー温度が35°Cを超えると充電を一時停止し、33°C以下に冷却されると再開します。"`).

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing:WattlyTests/SettingsBatterySectionTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
GIT_CONFIG_GLOBAL=/dev/null git add Wattly/Views/Settings/SettingsBatterySection.swift Wattly/Resources/Localizable.xcstrings WattlyTests/SettingsBatterySectionTests.swift
GIT_CONFIG_GLOBAL=/dev/null git commit -m "feat(ui): simplify battery heat protection into fixed 35C toggle"
```

---

### Task 2: Clean up BatterySectionPresentation & Update Unit Tests

**Files:**
- Modify: `Wattly/Core/BatterySectionPresentation.swift:245-255`
- Modify: `WattlyTests/BatterySectionPresentationTests.swift:630-635`
- Modify: `WattlyTests/SettingsBatterySectionTests.swift:45-65`
- Test: `WattlyTests/BatterySectionPresentationTests.swift`
- Test: `WattlyTests/SettingsBatterySectionTests.swift`

**Interfaces:**
- Consumes: `BatterySectionPresentation`
- Produces: Cleaned up presentation helpers and updated test cases.

- [ ] **Step 1: Write the failing tests**

In `WattlyTests/BatterySectionPresentationTests.swift`:
Remove `heatProtectionThresholdPresetsAreValid` and replace with test verifying presentation behavior for heat protection status.

In `WattlyTests/SettingsBatterySectionTests.swift`:
Remove `heatProtectionPresetsMatchExpectedValues` and `batteryHeatProtectionThresholdCanBePersisted` preset loop, and verify toggle-only behavior with fixed 35°C default.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing:WattlyTests/BatterySectionPresentationTests -only-testing:WattlyTests/SettingsBatterySectionTests`
Expected: FAIL (missing / modified test expectations)

- [ ] **Step 3: Clean up BatterySectionPresentation and test suites**

In `Wattly/Core/BatterySectionPresentation.swift`:
Remove `static let heatProtectionThresholdPresets = [32, 35, 38, 40]`.

In `WattlyTests/BatterySectionPresentationTests.swift` and `WattlyTests/SettingsBatterySectionTests.swift`:
Update test methods to cleanly reflect the removal of `heatProtectionThresholdPresets`.

- [ ] **Step 4: Run full test suite and build**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData`
Run: `xcodebuild build -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData`
Expected: ALL tests PASS, BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
GIT_CONFIG_GLOBAL=/dev/null git add Wattly/Core/BatterySectionPresentation.swift WattlyTests/BatterySectionPresentationTests.swift WattlyTests/SettingsBatterySectionTests.swift
GIT_CONFIG_GLOBAL=/dev/null git commit -m "refactor(battery): remove heat protection threshold presets"
```
