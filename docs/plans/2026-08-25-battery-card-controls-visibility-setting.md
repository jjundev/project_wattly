# Battery Card Controls Visibility Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add user settings in the Display settings view to toggle the visibility of "한 번만 완충 (Top-Up)" and "수동 방전 (Manual Discharge)" rows in the expanded Battery card.

**Architecture:** Add two independent persisted settings (`showBatteryTopUp`, `showBatteryManualDischarge`) defaulting to `true`. Expose toggle switches under the Battery section in `SettingsDisplaySection`. Update pure presentation helper functions in `BatterySectionPresentation` and bind them in `CardExpandRegion` so that active top-up or active discharge rows are temporarily shown for user safety/control even if the toggle is off, while idle rows are cleanly omitted (including the section divider).

**Tech Stack:** Swift 6.0, SwiftUI, Swift Testing framework (`import Testing`), macOS 14.0+ Deployment Target, `UserDefaults` / `@AppStorage`, `Localizable.xcstrings`.

## Global Constraints

- Swift 6 language mode with complete concurrency checking (`SWIFT_VERSION: "6.0"`).
- Target platform: macOS 14.0+ on Apple Silicon (arm64).
- Ad-hoc code signing (`CODE_SIGN_IDENTITY: "-"`).
- Pure logic must be separated from SwiftUI views and covered with unit tests using Swift Testing (`#expect`).
- All user-facing strings must be localized across the 30 supported languages in `Localizable.xcstrings`.
- Every persisted key must be reset to its `Defaults` value in `SettingsReset.applyDefaults`.

---

### Task 1: Add StorageKey, Defaults, and SettingsReset support with unit tests

**Files:**
- Modify: `Wattly/Settings/Settings.swift:440-485`
- Modify: `Wattly/Core/SettingsReset.swift:25-55`
- Test: `WattlyTests/SettingsResetTests.swift:215-235`

**Interfaces:**
- Produces:
  - `Defaults.showBatteryTopUp: Bool = true`
  - `Defaults.showBatteryManualDischarge: Bool = true`
  - `StorageKey.showBatteryTopUp: String = "showBatteryTopUp"`
  - `StorageKey.showBatteryManualDischarge: String = "showBatteryManualDischarge"`
  - `SettingsReset.applyDefaults(into:login:maxFanRPM:)` resetting both keys

- [ ] **Step 1: Write the failing tests in `SettingsResetTests.swift`**

Add tests asserting that `applyDefaults` restores `showBatteryTopUp` and `showBatteryManualDischarge` to their default (`true`) values:

```swift
    @Test func resetIncludesBatteryCardControlVisibilityKeys() {
        let d = makeDefaults(#function)
        d.set(false, forKey: StorageKey.showBatteryTopUp)
        d.set(false, forKey: StorageKey.showBatteryManualDischarge)

        SettingsReset.applyDefaults(into: d)

        #expect(Defaults.showBatteryTopUp == true)
        #expect(Defaults.showBatteryManualDischarge == true)
        #expect(d.bool(forKey: StorageKey.showBatteryTopUp) == true)
        #expect(d.bool(forKey: StorageKey.showBatteryManualDischarge) == true)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Wattly -configuration Debug -derivedDataPath /tmp/WattlyDerivedData -only-testing:WattlyTests/SettingsResetTests/resetIncludesBatteryCardControlVisibilityKeys test`
Expected: Compilation failure because `showBatteryTopUp` and `showBatteryManualDischarge` do not exist yet on `StorageKey` or `Defaults`.

- [ ] **Step 3: Implement `Defaults`, `StorageKey`, and `SettingsReset` changes**

In `Wattly/Settings/Settings.swift`:
```swift
    static let showBatteryTopUp = true
    static let showBatteryManualDischarge = true
```
and under `enum StorageKey`:
```swift
    static let showBatteryTopUp = "showBatteryTopUp"
    static let showBatteryManualDischarge = "showBatteryManualDischarge"
```

In `Wattly/Core/SettingsReset.swift`:
```swift
        defaults.set(Defaults.showBatteryTopUp, forKey: StorageKey.showBatteryTopUp)
        defaults.set(Defaults.showBatteryManualDischarge, forKey: StorageKey.showBatteryManualDischarge)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Wattly -configuration Debug -derivedDataPath /tmp/WattlyDerivedData -only-testing:WattlyTests/SettingsResetTests test`
Expected: PASS (all 23 tests pass).

- [ ] **Step 5: Commit**

```bash
git add Wattly/Settings/Settings.swift Wattly/Core/SettingsReset.swift WattlyTests/SettingsResetTests.swift
git commit -m "feat(settings): add showBatteryTopUp and showBatteryManualDischarge storage keys and reset logic"
```

---

### Task 2: Add pure presentation logic for top-up & manual discharge card visibility with unit tests

**Files:**
- Modify: `Wattly/Core/BatterySectionPresentation.swift:480-499`
- Modify: `WattlyTests/BatterySectionPresentationTests.swift:830-868`

**Interfaces:**
- Produces:
  - `BatterySectionPresentation.shouldShowTopUpRow(showSetting:isTopUpActive:) -> Bool`
  - `BatterySectionPresentation.shouldShowManualDischargeRow(showSetting:isDischarging:currentSoC:targetSoC:) -> Bool`
  - `BatterySectionPresentation.shouldShowBatteryControlSection(showControlRows:willShowTopUp:willShowDischarge:) -> Bool`

- [ ] **Step 1: Write failing unit tests in `BatterySectionPresentationTests.swift`**

Add unit tests covering normal display, setting disabled when idle, override when active, and empty section gating:

```swift
    @Test func topUpRowVisibilityPolicy() {
        // Setting ON + Inactive -> Shown
        #expect(BatterySectionPresentation.shouldShowTopUpRow(showSetting: true, isTopUpActive: false))
        // Setting OFF + Inactive -> Hidden
        #expect(!BatterySectionPresentation.shouldShowTopUpRow(showSetting: false, isTopUpActive: false))
        // Setting OFF + Active -> Shown (Safety override)
        #expect(BatterySectionPresentation.shouldShowTopUpRow(showSetting: false, isTopUpActive: true))
        // Setting ON + Active -> Shown
        #expect(BatterySectionPresentation.shouldShowTopUpRow(showSetting: true, isTopUpActive: true))
    }

    @Test func manualDischargeRowVisibilityPolicy() {
        // Setting ON, current SoC 90 > target 80, not discharging -> Shown
        #expect(BatterySectionPresentation.shouldShowManualDischargeRow(
            showSetting: true,
            isDischarging: false,
            currentSoC: 90,
            targetSoC: 80
        ))

        // Setting ON, current SoC 70 <= target 80, not discharging -> Hidden (SoC below target)
        #expect(!BatterySectionPresentation.shouldShowManualDischargeRow(
            showSetting: true,
            isDischarging: false,
            currentSoC: 70,
            targetSoC: 80
        ))

        // Setting OFF, not discharging -> Hidden even if SoC > target
        #expect(!BatterySectionPresentation.shouldShowManualDischargeRow(
            showSetting: false,
            isDischarging: false,
            currentSoC: 90,
            targetSoC: 80
        ))

        // Setting OFF, but actively discharging -> Shown (Safety override to allow stopping)
        #expect(BatterySectionPresentation.shouldShowManualDischargeRow(
            showSetting: false,
            isDischarging: true,
            currentSoC: 70,
            targetSoC: 80
        ))
    }

    @Test func batteryControlSectionDividerAndContainerGating() {
        // Both rows hidden -> Entire section hidden (no Divider rendered)
        #expect(!BatterySectionPresentation.shouldShowBatteryControlSection(
            showControlRows: true,
            willShowTopUp: false,
            willShowDischarge: false
        ))

        // Top up shown -> Section shown
        #expect(BatterySectionPresentation.shouldShowBatteryControlSection(
            showControlRows: true,
            willShowTopUp: true,
            willShowDischarge: false
        ))

        // Discharge shown -> Section shown
        #expect(BatterySectionPresentation.shouldShowBatteryControlSection(
            showControlRows: true,
            willShowTopUp: false,
            willShowDischarge: true
        ))

        // showControlRows false (e.g. unplugged and not discharging) -> Section hidden regardless
        #expect(!BatterySectionPresentation.shouldShowBatteryControlSection(
            showControlRows: false,
            willShowTopUp: true,
            willShowDischarge: true
        ))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Wattly -configuration Debug -derivedDataPath /tmp/WattlyDerivedData -only-testing:WattlyTests/BatterySectionPresentationTests test`
Expected: Compilation failure because `shouldShowTopUpRow`, `shouldShowManualDischargeRow`, and `shouldShowBatteryControlSection` methods are not defined.

- [ ] **Step 3: Implement presentation helper methods in `BatterySectionPresentation.swift`**

In `Wattly/Core/BatterySectionPresentation.swift`:
```swift
    /// Determines whether the "한 번만 완충 (Top-Up)" row should be visible in the expanded battery card.
    /// Returns true if enabled by user settings, or if top-up is currently active.
    static func shouldShowTopUpRow(
        showSetting: Bool,
        isTopUpActive: Bool
    ) -> Bool {
        showSetting || isTopUpActive
    }

    /// Determines whether the "수동 방전 (Manual Discharge)" row should be visible in the expanded battery card.
    /// Returns true if currently discharging (safety override), or if enabled by settings and current SoC exceeds target.
    static func shouldShowManualDischargeRow(
        showSetting: Bool,
        isDischarging: Bool,
        currentSoC: Int,
        targetSoC: Int
    ) -> Bool {
        if isDischarging { return true }
        guard showSetting else { return false }
        return currentSoC > targetSoC
    }

    /// Determines whether the battery control section container and divider should be rendered.
    static func shouldShowBatteryControlSection(
        showControlRows: Bool,
        willShowTopUp: Bool,
        willShowDischarge: Bool
    ) -> Bool {
        showControlRows && (willShowTopUp || willShowDischarge)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Wattly -configuration Debug -derivedDataPath /tmp/WattlyDerivedData -only-testing:WattlyTests/BatterySectionPresentationTests test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/BatterySectionPresentation.swift WattlyTests/BatterySectionPresentationTests.swift
git commit -m "feat(presentation): add battery card control row visibility policy functions"
```

---

### Task 3: Add localization strings for new settings options in all supported languages

**Files:**
- Create: `/tmp/battery_visibility_i18n.json`
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Test: `WattlyTests/LocalizationTests.swift`

**Interfaces:**
- Produces:
  - `"한 번만 완충 보기"` translated to all 30 languages (e.g., en: "Show Top Up", ja: "1回のみフル充電を表示", etc.)
  - `"배터리 카드에서 일회성 100% 충전 버튼을 표시합니다."` translated to all 30 languages
  - `"수동 방전 보기"` translated to all 30 languages (e.g., en: "Show Manual Discharge", ja: "手동放電を表示", etc.)
  - `"배터리 카드에서 목표 잔량까지 수동 방전 버튼을 표시합니다."` translated to all 30 languages

- [ ] **Step 1: Write a temporary additions JSON mapping the keys across all 30 languages**

Create `/tmp/battery_visibility_i18n.json` containing translations for `ar`, `cs`, `da`, `de`, `el`, `en`, `es`, `fi`, `fr`, `he`, `hi`, `hu`, `id`, `it`, `ja`, `ko`, `nb`, `nl`, `pl`, `pt-BR`, `pt-PT`, `ro`, `ru`, `sv`, `th`, `tr`, `uk`, `vi`, `zh-Hans`, `zh-Hant`.

- [ ] **Step 2: Merge translations using `scripts/add_localizations.py`**

Run: `python3 scripts/add_localizations.py /tmp/battery_visibility_i18n.json`
Expected: `merged 4 keys; catalog now has N keys`.

- [ ] **Step 3: Write test in `LocalizationTests.swift`**

Add assertion in `LocalizationTests.swift`:
```swift
    @Test func batteryCardControlVisibilityLocalization() {
        let en = Locale(identifier: "en")
        let ko = Locale(identifier: "ko")
        #expect(String(localized: "한 번만 완충 보기", locale: en) == "Show Top Up")
        #expect(String(localized: "한 번만 완충 보기", locale: ko) == "한 번만 완충 보기")
        #expect(String(localized: "수동 방전 보기", locale: en) == "Show Manual Discharge")
        #expect(String(localized: "수동 방전 보기", locale: ko) == "수동 방전 보기")
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Wattly -configuration Debug -derivedDataPath /tmp/WattlyDerivedData -only-testing:WattlyTests/LocalizationTests test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Resources/Localizable.xcstrings WattlyTests/LocalizationTests.swift
git commit -m "i18n: add translations for battery card control visibility settings"
```

---

### Task 4: Update SettingsDisplaySection UI with sub-toggles under 배터리

**Files:**
- Modify: `Wattly/Views/Settings/SettingsDisplaySection.swift:75-105`

**Interfaces:**
- Consumes:
  - `@AppStorage(StorageKey.showBatteryTopUp) private var showBatteryTopUp`
  - `@AppStorage(StorageKey.showBatteryManualDischarge) private var showBatteryManualDischarge`
- Produces:
  - Settings UI containing indented sub-toggles for `showBatteryTopUp` and `showBatteryManualDischarge` nested under `if showBattery`.

- [ ] **Step 1: Add `@AppStorage` properties and UI rows in `SettingsDisplaySection.swift`**

In `SettingsDisplaySection.swift`:
```swift
    @AppStorage(StorageKey.showBatteryTopUp) private var showBatteryTopUp = Defaults.showBatteryTopUp
    @AppStorage(StorageKey.showBatteryManualDischarge) private var showBatteryManualDischarge = Defaults.showBatteryManualDischarge
```

Inside `showSection` under `if showBattery`:
```swift
                if showBattery {
                    SettingsToggleRow(isOn: $showBatteryEfficiency, divider: true,
                                      isEnabled: monitor.isPresent(.battery),
                                      disabledReason: monitor.isPresent(.battery) ? nil : "이 Mac에서는 사용할 수 없습니다") {
                        VStack(alignment: .leading, spacing: 2) {
                            SettingsRowTitle("배터리 효율 보기")
                            Text("배터리 효율 수치가 신경 쓰인다면, 필요할 때만 표시하세요.")
                                .font(WattlyFont.at(11.5, weight: .regular))
                                .foregroundStyle(t.faint)
                            if !monitor.isPresent(.battery) {
                                Text("이 Mac에서는 사용할 수 없습니다")
                                    .font(WattlyFont.at(11.5, weight: .regular))
                                    .foregroundStyle(t.faint)
                            }
                        }
                    }
                    .padding(.leading, 14)

                    SettingsToggleRow(isOn: $showBatteryTopUp, divider: true,
                                      isEnabled: monitor.isPresent(.battery),
                                      disabledReason: monitor.isPresent(.battery) ? nil : "이 Mac에서는 사용할 수 없습니다") {
                        VStack(alignment: .leading, spacing: 2) {
                            SettingsRowTitle("한 번만 완충 보기")
                            Text("배터리 카드에서 일회성 100% 충전 버튼을 표시합니다.")
                                .font(WattlyFont.at(11.5, weight: .regular))
                                .foregroundStyle(t.faint)
                            if !monitor.isPresent(.battery) {
                                Text("이 Mac에서는 사용할 수 없습니다")
                                    .font(WattlyFont.at(11.5, weight: .regular))
                                    .foregroundStyle(t.faint)
                            }
                        }
                    }
                    .padding(.leading, 14)

                    SettingsToggleRow(isOn: $showBatteryManualDischarge, divider: true,
                                      isEnabled: monitor.isPresent(.battery),
                                      disabledReason: monitor.isPresent(.battery) ? nil : "이 Mac에서는 사용할 수 없습니다") {
                        VStack(alignment: .leading, spacing: 2) {
                            SettingsRowTitle("수동 방전 보기")
                            Text("배터리 카드에서 목표 잔량까지 수동 방전 버튼을 표시합니다.")
                                .font(WattlyFont.at(11.5, weight: .regular))
                                .foregroundStyle(t.faint)
                            if !monitor.isPresent(.battery) {
                                Text("이 Mac에서는 사용할 수 없습니다")
                                    .font(WattlyFont.at(11.5, weight: .regular))
                                    .foregroundStyle(t.faint)
                            }
                        }
                    }
                    .padding(.leading, 14)
                }
```

- [ ] **Step 2: Build debug scheme to verify compilation**

Run: `xcodebuild -scheme Wattly -configuration Debug -derivedDataPath /tmp/WattlyDerivedData build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Wattly/Views/Settings/SettingsDisplaySection.swift
git commit -m "feat(settings): add Top-Up and Manual Discharge toggles to SettingsDisplaySection"
```

---

### Task 5: Wire CardExpandRegion with new settings and presentation logic

**Files:**
- Modify: `Wattly/Views/CardExpandRegion.swift:14-25, 335-365`

**Interfaces:**
- Consumes:
  - `showBatteryTopUp`, `showBatteryManualDischarge` via `@AppStorage`
  - `BatterySectionPresentation.shouldShowTopUpRow`
  - `BatterySectionPresentation.shouldShowManualDischargeRow`
  - `BatterySectionPresentation.shouldShowBatteryControlSection`

- [ ] **Step 1: Add `@AppStorage` bindings and update rendering in `CardExpandRegion.swift`**

In `Wattly/Views/CardExpandRegion.swift`:
```swift
    @AppStorage(StorageKey.showBatteryTopUp) private var showBatteryTopUp = Defaults.showBatteryTopUp
    @AppStorage(StorageKey.showBatteryManualDischarge) private var showBatteryManualDischarge = Defaults.showBatteryManualDischarge
```

Update battery control section rendering:
```swift
            if let batteryControl {
                let showControlRows = BatterySectionPresentation.shouldShowBatteryControlRows(
                    sampleCharging: s.charging,
                    sampleExternalConnected: s.externalConnected,
                    serviceAdapterConnected: batteryControl.status.isPowerAdapterConnected,
                    activity: batteryControl.status.activity,
                    manualDischargeActive: batteryControl.status.desiredConfiguration?.manualDischargeActive == true
                )

                let isTopUpActive = batteryControl.status.desiredConfiguration?.topUpActive == true
                    || batteryControl.status.activity == .topUp
                let isDischargeActive = batteryControl.status.activity == .discharging
                    || batteryControl.status.desiredConfiguration?.manualDischargeActive == true
                let currentSoC = s.percentage ?? batteryControl.status.currentPercentage

                let willShowTopUp = BatterySectionPresentation.shouldShowTopUpRow(
                    showSetting: showBatteryTopUp,
                    isTopUpActive: isTopUpActive
                )
                let willShowDischarge = BatterySectionPresentation.shouldShowManualDischargeRow(
                    showSetting: showBatteryManualDischarge,
                    isDischarging: isDischargeActive,
                    currentSoC: currentSoC,
                    targetSoC: manualDischargeTarget
                )

                if BatterySectionPresentation.shouldShowBatteryControlSection(
                    showControlRows: showControlRows,
                    willShowTopUp: willShowTopUp,
                    willShowDischarge: willShowDischarge
                ) {
                    Divider().background(t.line).opacity(0.6)
                    if willShowTopUp {
                        batteryTopUpRow(batteryControl, s)
                    }
                    if willShowDischarge {
                        batteryDischargeRow(batteryControl, s)
                    }
                }
            }
```
Remove obsolete private `shouldShowDischargeRow` method if no longer used.

- [ ] **Step 2: Build and run all test suites**

Run: `xcodebuild -scheme Wattly -configuration Debug -derivedDataPath /tmp/WattlyDerivedData test`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add Wattly/Views/CardExpandRegion.swift
git commit -m "feat(ui): respect showBatteryTopUp and showBatteryManualDischarge in CardExpandRegion"
```

---

### Task 6: Build release and end-to-end verification

**Files:**
- Verification: `.build/DerivedData/Build/Products/Release/Wattly.app`

- [ ] **Step 1: Execute release build script**

Run: `./scripts/build_release.sh`
Expected: `==> Success! Release asset created at build/Release/Wattly.zip`.

- [ ] **Step 2: Run and verify the app**

Run:
```bash
pkill -x Wattly || true
open /tmp/WattlyDerivedData/Build/Products/Release/Wattly.app
```
Expected: App launches cleanly with new Settings toggles in "설정 › 표시 › 표시 지표 › 배터리". Toggling them updates the battery card live.
