# Refine Battery Settings UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refine the battery charge limit settings UI by removing the duplicate percentage label, removing the bottom advisory banner, and adding a helper button in the "최대 충전 한도" row that opens the macOS System Settings Battery pane.

**Architecture:** Update `SettingsBatterySection.swift` layout in SwiftUI: adjust `HStack` for "최대 충전 한도" to include a helper button opening `x-apple.systempreferences:com.apple.Battery-Settings.extension` (with fallback to `com.apple.preference.battery`) via `NSWorkspace.shared.open`, remove the `advisoryBanner` view and usage, and update unit tests.

**Tech Stack:** Swift, SwiftUI, AppKit (`NSWorkspace`), Swift Testing.

## Global Constraints

- Must support macOS 13+ System Settings (`x-apple.systempreferences:com.apple.Battery-Settings.extension`) with fallback to legacy `com.apple.preference.battery`.
- Maintain Wattly UI design tokens (`Tokens`, `WattlyFont`, `t.faint`, `t.text`).
- No regressions in `SettingsBatterySectionTests.swift` or `BatterySectionPresentationTests.swift`.

---

### Task 1: Update `SettingsBatterySection.swift` Layout and URL Opener

**Files:**
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift:42-192`

**Interfaces:**
- Consumes: `Tokens`, `WattlyFont`, `BatterySectionPresentation`, `BatteryControlClient`
- Produces: Updated `SettingsBatterySection` view without duplicate percentage label and obsolete banner, equipped with `openSystemBatterySettings()` helper.

- [ ] **Step 1: Update `SettingsBatterySection.swift`**

Update `SettingsBatterySection.swift`:
1. In `areDetailsVisible` block, update the "최대 충전 한도" `HStack` to replace `Text("\(batteryLimitPercentage)%")` with the helper button:
```swift
HStack {
    Text("최대 충전 한도")
        .font(WattlyFont.at(12, weight: .medium))
        .foregroundStyle(t.text)
    Spacer()
    Button {
        openSystemBatterySettings()
    } label: {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(t.faint)
    }
    .buttonStyle(.plain)
    .help("시스템 설정의 배터리 설정 열기")
    .accessibilityLabel("시스템 설정의 배터리 설정 열기")
}
.opacity(isLimitPickerEnabled ? 1 : 0.5)
```
2. Remove `advisoryBanner` from `VStack` and remove `private var advisoryBanner: some View` definition.
3. Add helper method `openSystemBatterySettings()`:
```swift
private func openSystemBatterySettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension"),
       NSWorkspace.shared.open(url) {
        return
    }
    if let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.battery") {
        NSWorkspace.shared.open(fallback)
    }
}
```

- [ ] **Step 2: Commit Task 1 changes**

```bash
git add Wattly/Views/Settings/SettingsBatterySection.swift
git commit -m "feat(settings): refine battery settings UI and add system battery settings link"
```

---

### Task 2: Update and Verify Unit Tests

**Files:**
- Modify: `WattlyTests/SettingsBatterySectionTests.swift`

**Interfaces:**
- Consumes: `SettingsBatterySection`, `Defaults`, `StorageKey`
- Produces: Passing unit tests verifying battery settings defaults and URL scheme constants.

- [ ] **Step 1: Add unit tests for System Settings Battery URL scheme strings in `SettingsBatterySectionTests.swift`**

Add tests to ensure the URL schemes used are valid URLs and non-empty:
```swift
@Test func systemBatterySettingsURLIsValid() {
    let primaryURL = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")
    let fallbackURL = URL(string: "x-apple.systempreferences:com.apple.preference.battery")
    #expect(primaryURL != nil)
    #expect(fallbackURL != nil)
    #expect(primaryURL?.scheme == "x-apple.systempreferences")
    #expect(fallbackURL?.scheme == "x-apple.systempreferences")
}
```

- [ ] **Step 2: Commit Task 2 changes**

```bash
git add WattlyTests/SettingsBatterySectionTests.swift
git commit -m "test(settings): add URL scheme validity test for battery settings"
```
