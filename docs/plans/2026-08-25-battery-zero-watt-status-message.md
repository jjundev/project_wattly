# Battery Zero-Watt Status Message Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display intelligent status messages (e.g. "완충됨 (전원 어댑터 사용)", "80% 한도 유지 중", "전원 어댑터로 작동 중", "대기 모드") instead of ambiguous time estimates or blank spaces when battery net power is near 0W (|netW| <= 0.2W).

**Architecture:** Extend `CardPresentation` with a pure `batteryZeroWattStatusText` helper that evaluates `abs(s.netW) <= 0.2`, `s.externalConnected`, and `s.remainingWh`/`s.maxWh`/`s.targetPercentage`. Wire this into `CardPresentation.batteryRemainingTimeSummary` and provide full localization in `Wattly/Resources/Localizable.xcstrings` across all 5 supported languages (ko, en, ja, de, zh-Hans).

**Tech Stack:** Swift 6.0, SwiftUI, Foundation Localization, String Catalogs (`.xcstrings`), Swift Testing (`#expect`).

## Global Constraints

- Never mutate IOKit / SMC sampling pipelines; all presentation rules remain pure and testable in `CardPresentation`.
- 0W dead-zone threshold is strictly `abs(netW) <= 0.2` matching `BatteryPower.isCharging` and `BatteryPower.estimatedTimeRemainingMinutes`.
- All 5 languages (ko, en, ja, de, zh-Hans) must have matching localized strings in `Wattly/Resources/Localizable.xcstrings` and passing localization tests.

---

### Task 1: Add 0W Status Text Logic & Unit Tests in `CardPresentation`

**Files:**
- Modify: `Wattly/Core/CardPresentation.swift`
- Test: `WattlyTests/CardPresentationTests.swift`

**Interfaces:**
- Produces: `CardPresentation.batteryZeroWattStatusText(_ s: BatterySample, locale: Locale) -> String?`
- Modifies: `CardPresentation.batteryRemainingTimeSummary(_ s: BatterySample, locale: Locale) -> String?`

- [ ] **Step 1: Write failing unit tests in `WattlyTests/CardPresentationTests.swift` and update existing 0W assertion**

Update line 149 in `CardPresentationTests.swift` (`batteryValueAndCollapsedSummary` test) where `noDetail` previously expected `nil` (it should now expect `"완충됨 (전원 어댑터 사용)"`), and add `batteryZeroWattStatusMessages` test with boundary tests:

```swift
    @Test func batteryZeroWattStatusMessages() {
        let fullyChargedOnAC = BatterySample(
            netW: 0.0,
            milliamps: 0,
            volts: 12.0,
            charging: false,
            externalConnected: true,
            remainingWh: 60.0,
            maxWh: 60.0,
            targetPercentage: 100
        )
        #expect(CardPresentation.batteryRemainingTimeSummary(fullyChargedOnAC) == "완충됨 (전원 어댑터 사용)")

        let holdingAt80OnAC = BatterySample(
            netW: -0.1,
            milliamps: 8,
            volts: 12.0,
            charging: false,
            externalConnected: true,
            remainingWh: 48.0,
            maxWh: 60.0,
            targetPercentage: 80
        )
        #expect(CardPresentation.batteryRemainingTimeSummary(holdingAt80OnAC) == "80% 한도 유지 중")

        let passthroughOnAC = BatterySample(
            netW: 0.05,
            milliamps: 4,
            volts: 12.0,
            charging: false,
            externalConnected: true,
            remainingWh: 30.0,
            maxWh: 60.0,
            targetPercentage: 100
        )
        #expect(CardPresentation.batteryRemainingTimeSummary(passthroughOnAC) == "전원 어댑터로 작동 중")

        let standbyOnBattery = BatterySample(
            netW: 0.0,
            milliamps: 0,
            volts: 12.0,
            charging: false,
            externalConnected: false,
            remainingWh: 50.0,
            maxWh: 60.0,
            targetPercentage: 100
        )
        #expect(CardPresentation.batteryRemainingTimeSummary(standbyOnBattery) == "대기 모드")

        // Boundary checks for 0.2W threshold
        let boundaryInAt0_20 = BatterySample(
            netW: 0.20,
            milliamps: 16,
            volts: 12.0,
            charging: false,
            externalConnected: true,
            remainingWh: 30.0,
            maxWh: 60.0,
            targetPercentage: 100
        )
        #expect(CardPresentation.batteryRemainingTimeSummary(boundaryInAt0_20) == "전원 어댑터로 작동 중")

        let boundaryOutAt0_21 = BatterySample(
            netW: 0.21,
            milliamps: 17,
            volts: 12.0,
            charging: false,
            externalConnected: true,
            remainingWh: 30.0,
            maxWh: 60.0,
            targetPercentage: 100
        )
        // At 0.21W without projected minutes, returns nil
        #expect(CardPresentation.batteryZeroWattStatusText(boundaryOutAt0_21) == nil)
    }
```

- [ ] **Step 2: Run tests to verify failure**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'`
Expected: FAIL

- [ ] **Step 3: Implement `batteryZeroWattStatusText` and update `batteryRemainingTimeSummary` in `Wattly/Core/CardPresentation.swift`**

```swift
    static func batteryZeroWattStatusText(_ s: BatterySample, locale: Locale = Locale(identifier: "ko")) -> String? {
        guard abs(s.netW) <= 0.2 else { return nil }

        if s.externalConnected {
            let currentPct: Int? = {
                guard let rem = s.remainingWh, let maxWh = s.maxWh, maxWh > 0 else { return nil }
                return Int((rem / maxWh * 100.0).rounded())
            }()

            if let currentPct {
                if s.targetPercentage < 100 && currentPct >= s.targetPercentage {
                    return String(format: String(localized: "%lld%% 한도 유지 중", locale: locale),
                                  locale: locale, Int64(s.targetPercentage))
                } else if currentPct >= 99 || (s.remainingWh != nil && s.maxWh != nil && s.remainingWh! >= s.maxWh!) {
                    return String(localized: "완충됨 (전원 어댑터 사용)", locale: locale)
                }
            } else if s.targetPercentage == 100 {
                // If capacity numbers unavailable, default to fully charged when on AC and 0W
                return String(localized: "완충됨 (전원 어댑터 사용)", locale: locale)
            }
            return String(localized: "전원 어댑터로 작동 중", locale: locale)
        } else {
            return String(localized: "대기 모드", locale: locale)
        }
    }

    static func batteryRemainingTimeSummary(_ s: BatterySample, locale: Locale = Locale(identifier: "ko")) -> String? {
        if let zeroWattStatus = batteryZeroWattStatusText(s, locale: locale) {
            return zeroWattStatus
        }
        guard let totalMinutes = validatedTimeRemainingMinutes(s.projectedTimeRemainingMinutes)
        else { return nil }
        let duration = formatDuration(minutes: totalMinutes, locale: locale)
        if s.charging {
            if s.targetPercentage < 100 {
                return String(format: String(localized: "%lld%%까지 약 %@ 남음", locale: locale),
                              locale: locale, Int64(s.targetPercentage), duration)
            } else {
                return String(format: String(localized: "완충까지 약 %@ 남음", locale: locale),
                              locale: locale, duration)
            }
        } else {
            return String(format: String(localized: "약 %@ 남음", locale: locale),
                          locale: locale, duration)
        }
    }
```

- [ ] **Step 4: Run tests to verify pass**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/CardPresentation.swift WattlyTests/CardPresentationTests.swift
git commit -m "feat(battery): display intelligent status messages when power is near zero watts"
```

---

### Task 2: Add String Catalog Translations & Localization Tests

**Files:**
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Test: `WattlyTests/LocalizationTests.swift`

**Interfaces:**
- Verifies: `CardPresentation.batteryZeroWattStatusText` with `en`, `ja`, `de`, `zh-Hans`

- [ ] **Step 1: Write failing localization tests in `WattlyTests/LocalizationTests.swift`**

```swift
    @Test func batteryZeroWattStatusLocalization() {
        let ko = Locale(identifier: "ko")
        let en = Locale(identifier: "en")
        let ja = Locale(identifier: "ja")
        let de = Locale(identifier: "de")
        let zhHans = Locale(identifier: "zh-Hans")

        let fullyCharged = BatterySample(netW: 0.0, milliamps: 0, volts: 12.0, charging: false, externalConnected: true, remainingWh: 60.0, maxWh: 60.0, targetPercentage: 100)
        let limit80 = BatterySample(netW: 0.0, milliamps: 0, volts: 12.0, charging: false, externalConnected: true, remainingWh: 48.0, maxWh: 60.0, targetPercentage: 80)
        let passthrough = BatterySample(netW: 0.0, milliamps: 0, volts: 12.0, charging: false, externalConnected: true, remainingWh: 30.0, maxWh: 60.0, targetPercentage: 100)
        let standby = BatterySample(netW: 0.0, milliamps: 0, volts: 12.0, charging: false, externalConnected: false, remainingWh: 30.0, maxWh: 60.0, targetPercentage: 100)

        // Korean
        #expect(CardPresentation.batteryRemainingTimeSummary(fullyCharged, locale: ko) == "완충됨 (전원 어댑터 사용)")
        #expect(CardPresentation.batteryRemainingTimeSummary(limit80, locale: ko) == "80% 한도 유지 중")
        #expect(CardPresentation.batteryRemainingTimeSummary(passthrough, locale: ko) == "전원 어댑터로 작동 중")
        #expect(CardPresentation.batteryRemainingTimeSummary(standby, locale: ko) == "대기 모드")

        // English
        #expect(CardPresentation.batteryRemainingTimeSummary(fullyCharged, locale: en) == "Fully Charged (On AC Power)")
        #expect(CardPresentation.batteryRemainingTimeSummary(limit80, locale: en) == "Holding at 80% Limit")
        #expect(CardPresentation.batteryRemainingTimeSummary(passthrough, locale: en) == "Powered by Power Adapter")
        #expect(CardPresentation.batteryRemainingTimeSummary(standby, locale: en) == "Standby")

        // Japanese
        #expect(CardPresentation.batteryRemainingTimeSummary(fullyCharged, locale: ja) == "充電完了 (電源アダプタ使用)")
        #expect(CardPresentation.batteryRemainingTimeSummary(limit80, locale: ja) == "80%制限を維持中")
        #expect(CardPresentation.batteryRemainingTimeSummary(passthrough, locale: ja) == "電源アダプタで給電中")
        #expect(CardPresentation.batteryRemainingTimeSummary(standby, locale: ja) == "スタンバイ")

        // German
        #expect(CardPresentation.batteryRemainingTimeSummary(fullyCharged, locale: de) == "Vollständig geladen (Netzbetrieb)")
        #expect(CardPresentation.batteryRemainingTimeSummary(limit80, locale: de) == "80 %-Limit gehalten")
        #expect(CardPresentation.batteryRemainingTimeSummary(passthrough, locale: de) == "Stromversorgung über Netzteil")
        #expect(CardPresentation.batteryRemainingTimeSummary(standby, locale: de) == "Standby-Modus")

        // Chinese Simplified
        #expect(CardPresentation.batteryRemainingTimeSummary(fullyCharged, locale: zhHans) == "已充满 (使用电源适配器)")
        #expect(CardPresentation.batteryRemainingTimeSummary(limit80, locale: zhHans) == "保持在 80% 限制")
        #expect(CardPresentation.batteryRemainingTimeSummary(passthrough, locale: zhHans) == "由电源适配器供电")
        #expect(CardPresentation.batteryRemainingTimeSummary(standby, locale: zhHans) == "待机模式")
    }
```

- [ ] **Step 2: Run test to verify failure**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'`
Expected: FAIL (missing localizations in other languages)

- [ ] **Step 3: Add new localization keys to `Wattly/Resources/Localizable.xcstrings`**

Add strings for:
- `완충됨 (전원 어댑터 사용)`:
  - en: `Fully Charged (On AC Power)`
  - ja: `充電完了 (電源アダプタ使用)`
  - de: `Vollständig geladen (Netzbetrieb)`
  - zh-Hans: `已充满 (使用电源适配器)`
- `%lld%% 한도 유지 중`:
  - en: `Holding at %lld%% Limit`
  - ja: `%lld%%制限を維持中`
  - de: `%lld %%-Limit gehalten`
  - zh-Hans: `保持在 %lld%% 限制`
- `전원 어댑터로 작동 중`:
  - en: `Powered by Power Adapter`
  - ja: `電源アダプタで給電中`
  - de: `Stromversorgung über Netzteil`
  - zh-Hans: `由电源适配器供电`
- `대기 모드`:
  - en: `Standby`
  - ja: `スタンバイ`
  - de: `Standby-Modus`
  - zh-Hans: `待机模式`

- [ ] **Step 4: Run test to verify pass**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Resources/Localizable.xcstrings WattlyTests/LocalizationTests.swift
git commit -m "feat(i18n): localize battery near zero-watt status messages across all languages"
```
