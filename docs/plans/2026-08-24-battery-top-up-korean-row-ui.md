# Battery Top Up UI & Terminology ('한 번만 완충') Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unify the battery Top Up terminology to **"한 번만 완충"** across all UI, daemon status reasons, status texts, notifications, and settings, and revamp the popover battery card expand region to show a clean, dedicated row with **`(활성화)` / `(비활성화)`** toggle controls aligned with existing detail rows.

**Architecture:** 
1. Update status strings in `FanControlShared/BatteryControlStatusReason.swift`, `Wattly/Core/BatteryStatusText.swift`, `Wattly/Core/BatteryNotificationManager.swift`, `Wattly/Core/LegacyBatteryDetail.swift`, and `Wattly/Resources/Localizable.xcstrings` to use **"한 번만 완충"** and provide complete Korean/English translations.
2. Update all corresponding test expectations across `BatteryStatusTextTests`, `BatteryNotificationManagerTests`, `LocalizationTests`, `BatterySectionPresentationTests`, and `BatteryControlStatusReasonTests`.
3. Replace the standalone button in `CardExpandRegion.swift` with a structured `batteryTopUpRow` that mirrors `batteryDetailRow` (label on left, `(활성화)`/`(비활성화)` interactive capsule toggle on right).
4. Align `SettingsBatterySection.swift` and `SettingsBatterySectionTests.swift` with the unified naming and toggle presentation.

**Tech Stack:** Swift 5.10+, SwiftUI, XPC, macOS 14.0+, Swift Testing.

## Global Constraints

- Support macOS 14.0 and later on Apple Silicon arm64; no third-party dependencies.
- LaunchDaemon helper (`WattlyFanDaemon`) and hardware readback remain the single source of truth for persistent policy and state.
- Normal `limitPercentage` (e.g. 80%) must never be permanently overwritten by Top Up.
- Unplugging the power adapter automatically terminates Top Up and restores the permanent charge limit.
- Any new/renamed source file requires running `xcodegen generate` and committing the updated `Wattly.xcodeproj/project.pbxproj`.
- Full validation command: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'` followed by `xcodebuild build -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'`.

---

### Task 1: Update Localization, Status Reason, and Presentation Copy for '한 번만 완충'

**Files:**
- Modify: `FanControlShared/BatteryControlStatusReason.swift:160-161`
- Modify: `Wattly/Core/BatteryStatusText.swift:84-88`
- Modify: `Wattly/Core/BatteryNotificationManager.swift:20-27`
- Modify: `Wattly/Core/LegacyBatteryDetail.swift:30-33`
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Modify: `WattlyTests/BatteryStatusTextTests.swift:162-178`
- Modify: `WattlyTests/BatteryNotificationManagerTests.swift:6-19`
- Modify: `WattlyTests/LocalizationTests.swift:298-319`
- Modify: `WattlyTests/BatterySectionPresentationTests.swift:665-692`
- Modify: `WattlyTests/BatteryControlStatusReasonTests.swift:131-144`

**Interfaces:**
- Consumes: `BatteryControlStatusReason.Kind.topUpCharging`, `BatteryControlStatusReason.Kind.topUpComplete`.
- Produces: Localized Korean/English status copy for "한 번만 완충" / "One-Time Full Charge" across daemon, core, notifications, and tests.

- [ ] **Step 1: Update existing test suites with new Korean and English expectations**

In `WattlyTests/BatteryStatusTextTests.swift`:
```swift
    @Test func topUpStatusTextLocalized() {
        let ko = Locale(identifier: "ko")
        let en = Locale(identifier: "en")

        let chargingReason = BatteryControlStatusReason(kind: .topUpCharging, limitPercentage: 100)
        let completeReason = BatteryControlStatusReason(kind: .topUpComplete, limitPercentage: 100)

        #expect(BatteryStatusText.text(reason: chargingReason, detail: "", locale: ko)
                == "한 번만 완충 중 (100%까지 충전)")
        #expect(BatteryStatusText.text(reason: chargingReason, detail: "", locale: en)
                == "One-time full charging (up to 100%)")

        #expect(BatteryStatusText.text(reason: completeReason, detail: "", locale: ko)
                == "한 번만 완충 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)")
        #expect(BatteryStatusText.text(reason: completeReason, detail: "", locale: en)
                == "One-time full charge complete (holding at 100%, reverts to limit on disconnect)")
    }
```

In `WattlyTests/BatteryNotificationManagerTests.swift`:
```swift
    @Test func notificationTitleAndBodyAreLocalized() {
        let ko = Locale(identifier: "ko")
        let en = Locale(identifier: "en")

        #expect(BatteryNotificationManager.topUpCompleteTitle(locale: ko) == "한 번만 완충 완료")
        #expect(BatteryNotificationManager.topUpCompleteTitle(locale: en) == "One-Time Full Charge Complete")

        #expect(BatteryNotificationManager.topUpCompleteBody(locale: ko) == "배터리가 100%까지 충전되었습니다. 어댑터를 분리하면 기존 충전 제한으로 자동 복귀합니다.")
        #expect(BatteryNotificationManager.topUpCompleteBody(locale: en) == "Battery is charged to 100%. Normal limit will restore automatically when unplugged.")
    }
```

In `WattlyTests/BatterySectionPresentationTests.swift`:
```swift
    @Test func topUpStatusRendersTopUpIndicator() {
        let ko = Locale(identifier: "ko")
        let statusCharging = BatterySectionPresentation.status(
            isLimitOn: true,
            isInstalling: false,
            mode: .charging,
            reason: .init(kind: .topUpCharging, limitPercentage: 100),
            detail: "한 번만 완충 중 (100%까지 충전)",
            locale: ko,
            activity: .topUp
        )
        #expect(statusCharging.indicator == .topUp)
        #expect(statusCharging.indicator.symbolName == "arrow.up.circle.fill")
        #expect(statusCharging.indicator.tone == .green)
        #expect(statusCharging.text == "한 번만 완충 중 (100%까지 충전)")

        let statusComplete = BatterySectionPresentation.status(
            isLimitOn: true,
            isInstalling: false,
            mode: .inhibited,
            reason: .init(kind: .topUpComplete, limitPercentage: 100),
            detail: "한 번만 완충 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)",
            locale: ko,
            activity: .topUp
        )
        #expect(statusComplete.indicator == .topUp)
        #expect(statusComplete.text == "한 번만 완충 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)")
    }
```

In `WattlyTests/BatteryControlStatusReasonTests.swift`:
```swift
    @Test func topUpReasonsRoundTripAndProvideLegacyKoreanDetail() throws {
        let charging = BatteryControlStatusReason(kind: .topUpCharging, limitPercentage: 100)
        #expect(charging.legacyKoreanDetail == "한 번만 완충 중 (100%까지 충전)")

        let complete = BatteryControlStatusReason(kind: .topUpComplete, limitPercentage: 100)
        #expect(complete.legacyKoreanDetail == "한 번만 완충 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)")
    }
```

In `WattlyTests/LocalizationTests.swift`:
```swift
    @Test func topUpTranslations() {
        let en = Locale(identifier: "en")
        let ko = Locale(identifier: "ko")

        #expect(String(localized: "한 번만 완충", locale: en) == "One-Time Full Charge")
        #expect(String(localized: "한 번만 완충 중 (100%까지 충전)", locale: en) == "One-time full charging (up to 100%)")
        #expect(String(localized: "한 번만 완충 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)", locale: en) == "One-time full charge complete (holding at 100%, reverts to limit on disconnect)")
        #expect(String(localized: "한 번만 완충 완료", locale: en) == "One-Time Full Charge Complete")
        #expect(String(localized: "(활성화)", locale: en) == "(Active)")
        #expect(String(localized: "(비활성화)", locale: en) == "(Inactive)")
        #expect(String(localized: "다음 외출이나 출장을 위해 배터리를 일회성으로 100%까지 완전 충전합니다. 어댑터를 분리하면 기존 충전 제한으로 자동 복귀합니다.", locale: en) == "Charges to 100% once before heading out, then automatically restores your charge limit when unplugged.")
        #expect(String(localized: "배터리가 100%까지 충전되었습니다. 어댑터를 분리하면 기존 충전 제한으로 자동 복귀합니다.", locale: en) == "Battery is charged to 100%. Normal limit will restore automatically when unplugged.")

        #expect(String(localized: "한 번만 완충", locale: ko) == "한 번만 완충")
        #expect(String(localized: "한 번만 완충 중 (100%까지 충전)", locale: ko) == "한 번만 완충 중 (100%까지 충전)")
        #expect(String(localized: "한 번만 완충 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)", locale: ko) == "한 번만 완충 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)")
        #expect(String(localized: "한 번만 완충 완료", locale: ko) == "한 번만 완충 완료")
        #expect(String(localized: "(활성화)", locale: ko) == "(활성화)")
        #expect(String(localized: "(비활성화)", locale: ko) == "(비활성화)")
        #expect(String(localized: "다음 외출이나 출장을 위해 배터리를 일회성으로 100%까지 완전 충전합니다. 어댑터를 분리하면 기존 충전 제한으로 자동 복귀합니다.", locale: ko) == "다음 외출이나 출장을 위해 배터리를 일회성으로 100%까지 완전 충전합니다. 어댑터를 분리하면 기존 충전 제한으로 자동 복귀합니다.")
        #expect(String(localized: "배터리가 100%까지 충전되었습니다. 어댑터를 분리하면 기존 충전 제한으로 자동 복귀합니다.", locale: ko) == "배터리가 100%까지 충전되었습니다. 어댑터를 분리하면 기존 충전 제한으로 자동 복귀합니다.")
    }
```

- [ ] **Step 2: Run tests to verify failure (RED)**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryStatusTextTests -only-testing:WattlyTests/BatteryNotificationManagerTests -only-testing:WattlyTests/LocalizationTests -only-testing:WattlyTests/BatterySectionPresentationTests -only-testing:WattlyTests/BatteryControlStatusReasonTests
```
Expected: FAIL due to old "Top Up" string implementations.

- [ ] **Step 3: Update localized strings in Daemon, Core, and Localizable.xcstrings**

In `FanControlShared/BatteryControlStatusReason.swift`:
```swift
        case .topUpCharging: return "한 번만 완충 중 (100%까지 충전)"
        case .topUpComplete: return "한 번만 완충 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)"
```

In `Wattly/Core/BatteryStatusText.swift`:
```swift
        case .topUpCharging:
            return String(localized: "한 번만 완충 중 (100%까지 충전)", locale: locale)
        case .topUpComplete:
            return String(localized: "한 번만 완충 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)", locale: locale)
```

In `Wattly/Core/BatteryNotificationManager.swift`:
```swift
    public static func topUpCompleteTitle(locale: Locale) -> String {
        String(localized: "한 번만 완충 완료", locale: locale)
    }

    public static func topUpCompleteBody(locale: Locale) -> String {
        String(localized: "배터리가 100%까지 충전되었습니다. 어댑터를 분리하면 기존 충전 제한으로 자동 복귀합니다.", locale: locale)
    }
```

In `Wattly/Core/LegacyBatteryDetail.swift`:
```swift
        case "한 번만 완충 중 (100%까지 충전)", "Top Up 중 (100%까지 충전)": return .init(kind: .topUpCharging)
        case "한 번만 완충 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)", "Top Up 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)": return .init(kind: .topUpComplete)
```

In `Wattly/Resources/Localizable.xcstrings`, add / update translations:
- `"한 번만 완충"` -> ko: `"한 번만 완충"`, en: `"One-Time Full Charge"`
- `"한 번만 완충 중 (100%까지 충전)"` -> ko: `"한 번만 완충 중 (100%까지 충전)"`, en: `"One-time full charging (up to 100%)"`
- `"한 번만 완충 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)"` -> ko: `"한 번만 완충 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)"`, en: `"One-time full charge complete (holding at 100%, reverts to limit on disconnect)"`
- `"한 번만 완충 완료"` -> ko: `"한 번만 완충 완료"`, en: `"One-Time Full Charge Complete"`
- `"(활성화)"` -> ko: `"(활성화)"`, en: `"(Active)"`
- `"(비활성화)"` -> ko: `"(비활성화)"`, en: `"(Inactive)"`
- `"다음 외출이나 출장을 위해 배터리를 일회성으로 100%까지 완전 충전합니다. 어댑터를 분리하면 기존 충전 제한으로 자동 복귀합니다."` -> ko: `"다음 외출이나 출장을 위해 배터리를 일회성으로 100%까지 완전 충전합니다. 어댑터를 분리하면 기존 충전 제한으로 자동 복귀합니다."`, en: `"Charges to 100% once before heading out, then automatically restores your charge limit when unplugged."`

- [ ] **Step 4: Run tests to verify pass (GREEN)**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryStatusTextTests -only-testing:WattlyTests/BatteryNotificationManagerTests -only-testing:WattlyTests/LocalizationTests -only-testing:WattlyTests/BatterySectionPresentationTests -only-testing:WattlyTests/BatteryControlStatusReasonTests
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit localization changes**

```bash
git add FanControlShared/BatteryControlStatusReason.swift \
  Wattly/Resources/Localizable.xcstrings \
  Wattly/Core/BatteryStatusText.swift \
  Wattly/Core/BatteryNotificationManager.swift \
  Wattly/Core/LegacyBatteryDetail.swift \
  WattlyTests/BatteryStatusTextTests.swift \
  WattlyTests/BatteryNotificationManagerTests.swift \
  WattlyTests/LocalizationTests.swift \
  WattlyTests/BatterySectionPresentationTests.swift \
  WattlyTests/BatteryControlStatusReasonTests.swift
git commit -m "feat(battery): update Top Up copy and status reasons to '한 번만 완충'"
```

---

### Task 2: Implement Dedicated '한 번만 완충' Row in Popover Battery Card (`CardExpandRegion`)

**Files:**
- Modify: `Wattly/Views/CardExpandRegion.swift:250-300`

**Interfaces:**
- Consumes: `BatteryControlClient.startTopUp()`, `BatteryControlClient.cancelTopUp()`, `BatteryControlServiceStatus.activity`, `BatteryControlServiceStatus.desiredConfiguration`.
- Produces: `batteryTopUpRow` with Left label (`한 번만 완충`) and Right toggle (`(활성화)` / `(비활성화)`).

- [ ] **Step 1: Implement `batteryTopUpRow` in `CardExpandRegion.swift`**

In `Wattly/Views/CardExpandRegion.swift`:
```swift
    private func batteryExpand(_ s: BatterySample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let value = CardPresentation.batteryAverage1mText(s) {
                batteryDetailRow(label: CardPresentation.batteryAverage1mLabel, value: value)
            }
            if let value = CardPresentation.batteryRemainingCapacityText(s) {
                batteryDetailRow(label: CardPresentation.batteryRemainingCapacityLabel, value: value)
            }
            if showBatteryEfficiency, let value = CardPresentation.batteryEfficiencyText(s) {
                batteryDetailRow(label: CardPresentation.batteryEfficiencyLabel, value: value)
            }
            if let value = CardPresentation.batteryCycleText(s) {
                batteryDetailRow(label: CardPresentation.batteryCycleLabel, value: value)
            }
            if let value = CardPresentation.batteryTemperatureText(s) {
                batteryDetailRow(label: CardPresentation.batteryTemperatureLabel, value: value)
            }
            batteryDetailRow(label: "전류", value: CardPresentation.batteryCurrentText(s))
            batteryDetailRow(label: "전압", value: CardPresentation.batteryVoltageText(s))

            if let batteryControl {
                batteryTopUpRow(batteryControl, s)
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func batteryTopUpRow(_ batteryControl: BatteryControlClient, _ s: BatterySample) -> some View {
        let isConnected = s.charging || batteryControl.status.isPowerAdapterConnected
        let isTopUp = isConnected && (batteryControl.status.desiredConfiguration?.topUpActive == true || batteryControl.status.activity == .topUp)

        HStack(alignment: .center) {
            HStack(spacing: 4) {
                Text(LocalizedStringKey("한 번만 완충"))
                    .font(WattlyFont.at(10.5, weight: .medium))
                    .foregroundStyle(t.faint)
                if isTopUp {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Tokens.statusOrange)
                }
            }
            Spacer()
            Button {
                let limit = batteryLimitPercentage
                let delta = batterySailingEnabled ? batterySailingDelta : 2
                let heatEnabled = batteryHeatProtectionEnabled
                let heatThreshold = batteryHeatProtectionThreshold
                Task {
                    if isTopUp {
                        await batteryControl.cancelTopUp(
                            limitPercentage: limit,
                            lowerHysteresisDelta: delta,
                            heatProtectionEnabled: heatEnabled,
                            heatProtectionThresholdCelsius: heatThreshold)
                    } else {
                        await batteryControl.startTopUp(
                            limitPercentage: limit,
                            lowerHysteresisDelta: delta,
                            heatProtectionEnabled: heatEnabled,
                            heatProtectionThresholdCelsius: heatThreshold)
                    }
                }
            } label: {
                Text(LocalizedStringKey(isTopUp ? "(활성화)" : "(비활성화)"))
                    .font(WattlyFont.at(10.5, weight: .medium))
                    .foregroundStyle(isTopUp ? Tokens.statusOrange : (isConnected ? t.sub : t.faint.opacity(0.6)))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(isTopUp ? Tokens.statusOrange.opacity(0.15) : t.segTrack))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(isTopUp ? Tokens.statusOrange.opacity(0.4) : t.rowBorder, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isConnected)
        }
    }
```

- [ ] **Step 2: Run all tests to verify build**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Commit CardExpandRegion changes**

```bash
git add Wattly/Views/CardExpandRegion.swift
git commit -m "feat(battery): revamp CardExpandRegion Top Up to dedicated row with (활성화/비활성화) toggle"
```

---

### Task 3: Update Settings Battery Section Top Up Row (`SettingsBatterySection`)

**Files:**
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift:195-235`
- Modify: `WattlyTests/SettingsBatterySectionTests.swift`

**Interfaces:**
- Consumes: `BatteryControlClient.startTopUp()`, `BatteryControlClient.cancelTopUp()`.
- Produces: Updated settings row matching "한 번만 완충" and `(활성화)` / `(비활성화)` controls with unit tests.

- [ ] **Step 1: Update `SettingsBatterySectionTests.swift`**

In `WattlyTests/SettingsBatterySectionTests.swift`, update `topUpButtonStatePresentation`:
```swift
    @Test func topUpToggleStatePresentation() {
        let isTopUpActive = true
        let labelActive = isTopUpActive ? "(활성화)" : "(비활성화)"
        #expect(labelActive == "(활성화)")

        let isTopUpInactive = false
        let labelInactive = isTopUpInactive ? "(활성화)" : "(비활성화)"
        #expect(labelInactive == "(비활성화)")
    }
```

- [ ] **Step 2: Update `SettingsBatterySection.swift`**

In `Wattly/Views/Settings/SettingsBatterySection.swift`:
```swift
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            SettingsRowTitle("한 번만 완충")
                            Text(LocalizedStringKey("다음 외출이나 출장을 위해 배터리를 일회성으로 100%까지 완전 충전합니다. 어댑터를 분리하면 기존 충전 제한으로 자동 복귀합니다."))
                                .font(WattlyFont.at(10.5, weight: .regular))
                                .foregroundStyle(t.faint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        let isTopUp = batteryControl.status.desiredConfiguration?.topUpActive == true
                            || batteryControl.status.activity == .topUp
                        Button {
                            let limit = batteryLimitPercentage
                            let delta = effectiveDelta
                            let heatEnabled = batteryHeatProtectionEnabled
                            let heatThreshold = batteryHeatProtectionThreshold
                            Task {
                                if isTopUp {
                                    await batteryControl.cancelTopUp(
                                        limitPercentage: limit,
                                        lowerHysteresisDelta: delta,
                                        heatProtectionEnabled: heatEnabled,
                                        heatProtectionThresholdCelsius: heatThreshold)
                                } else {
                                    await batteryControl.startTopUp(
                                        limitPercentage: limit,
                                        lowerHysteresisDelta: delta,
                                        heatProtectionEnabled: heatEnabled,
                                        heatProtectionThresholdCelsius: heatThreshold)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if isTopUp {
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                Text(LocalizedStringKey(isTopUp ? "(활성화)" : "(비활성화)"))
                                    .font(WattlyFont.at(11.5, weight: .medium))
                            }
                            .foregroundStyle(isTopUp ? Tokens.statusOrange : t.text)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(isTopUp ? Tokens.statusOrange.opacity(0.15) : t.segTrack))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isTopUp ? Tokens.statusOrange.opacity(0.4) : t.rowBorder, lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!isToggleEnabled || isHardwareUnsupported)
                    }
```

- [ ] **Step 3: Run all test suites and verify full build**

Run:
```bash
xcodegen generate
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'
xcodebuild build -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'
```
Expected: `** TEST SUCCEEDED **` and `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit SettingsBatterySection changes**

```bash
git add Wattly/Views/Settings/SettingsBatterySection.swift WattlyTests/SettingsBatterySectionTests.swift
git commit -m "feat(battery): update SettingsBatterySection to use '한 번만 완충' and (활성화/비활성화) toggle"
```

---

## Self-Review

1. **Spec coverage**: Covers unified Korean naming "한 번만 완충", row-based layout in `CardExpandRegion`, and `(활성화)`/`(비활성화)` toggle buttons across both Popover and Settings, plus all 5 test suites.
2. **No Placeholders**: All tasks contain explicit file paths, exact code blocks, and test commands.
3. **Type Consistency**: `BatteryControlClient.startTopUp` and `cancelTopUp` signatures match across all views.
