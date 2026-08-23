# Sailing Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement Sailing Mode for Wattly's battery charge control to prevent micro-cycling at the charge limit by allowing natural battery discharge down to a configurable lower hysteresis threshold (2%, 5%, 10%) before resuming charging, with live UI indicators and dynamic range feedback.

**Architecture:** Extend `BatteryControlConfiguration` delta clamping to 10% and add structured `.sailing` status reasoning with `resumePercentage` to `BatteryControlStatusReason` and `BatteryControlActivity`. Update `BatteryControlEngine` to report `.sailing` when charging is inhibited and the battery naturally drops below the target limit while remaining above the resume threshold. Thread the sailing delta through `BatteryControlClient`, `BatteryControlBridge`, `SettingsReset`, and `BatterySectionPresentation`, and expose an intuitive Sailing Mode toggle and preset selector (2%, 5%, 10%) in `SettingsBatterySection`.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Observation, Swift Testing, Codable JSON over privileged XPC, XcodeGen, macOS 14+, Apple Silicon arm64

## Global Constraints

- Target macOS 14.0 and later on Apple Silicon arm64; no Intel path.
- Add no third-party dependencies.
- Preserve backward and forward compatibility across the privileged XPC interface for older helpers and app versions.
- Leniently decode `BatteryControlStatusReason` and `BatteryControlActivity` without throwing on unknown or malformed tokens.
- Sailing mode does not actively discharge the battery; it inhibits charging so the Mac runs on power adapter while the battery naturally discharges down to the lower hysteresis threshold.
- Presentation precedence remains: installation → hardware error / unavailable → stale → verified activity → local fallback.
- The full validation gate is `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'` and `xcodebuild build -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'`.

---

## Scope and Settled Decisions

Primary specification:
- `01-sailing-mode.md` (Battery Management - Sailing Mode)

Settled decisions:
1. **Delta range expansion:** Expand `BatteryControlConfiguration.clampDelta` from `max(1, min(5, value))` to `max(1, min(10, value))` to support the 10% sailing range preset.
2. **Sailing Status Reason:** Add `case sailing` to `BatteryControlStatusReason.Kind` and add an optional `resumePercentage: Int?` field to `BatteryControlStatusReason`. Lenient decoding guarantees that older helpers without this field decode safely.
3. **Activity mapping:** Map `.sailing` reason to `BatteryControlActivity.sailing`, which already exists in the activity and indicator enums (`arrow.left.and.right.circle.fill` icon with orange tone).
4. **Engine state machine:** In `BatteryControlEngine`, when `isCurrentlyInhibited` is `true` and `isPluggedIn` is `true`:
   - If `currentSoC >= target`: status reason is `.inhibitedAtLimit` (Holding at limit / 전원 어댑터 바이패스 구동).
   - If `currentSoC < target` and `currentSoC > config.resumePercentage`: status reason is `.sailing` (Sailing 중 / 자연 방전 구간).
   - If `currentSoC <= config.resumePercentage`: `shouldInhibit` becomes `false`, charging resumes, and status reason is `.chargingToTarget`.
5. **Settings & Bridge integration:**
   - Add `@AppStorage(StorageKey.batterySailingEnabled)` (default `false`) and `@AppStorage(StorageKey.batterySailingDelta)` (default `5`).
   - When Sailing Mode is disabled, the effective delta is `2` (the standard hysteresis delta).
   - When Sailing Mode is enabled, the user selects from `[2, 5, 10]` percentage points, and the UI displays dynamic feedback (e.g. "80% 도달 시 충전 정지, 75%에서 재충전").
   - `BatteryControlBridge` is updated to observe both sailing keys and push the effective delta on app launch, system wake, and periodic background reconciliation.
   - `SettingsReset` is updated to reset both sailing keys to their `Defaults` values on user-triggered settings reset.

---

## File Structure

### Modify

- `FanControlShared/BatteryControlProtocol.swift`
  - Expand `clampDelta` to `max(1, min(10, value))`.
- `FanControlShared/BatteryControlStatusReason.swift`
  - Add `.sailing` case to `Kind`.
  - Add `resumePercentage: Int?` field with lenient Codable decoding/encoding.
  - Add legacy Korean detail for `.sailing`: `"Sailing 중 (\(resume)% 도달 시 충전)"`.
- `FanControlShared/BatteryControlActivity.swift`
  - Update `inferred(from:)` to map `.sailing` reason to `.sailing` activity.
- `FanControlShared/BatteryControlEngine.swift`
  - Update `detailReason(isPluggedIn:target:currentSoC:)` to report `.sailing` when `isCurrentlyInhibited` is true and `currentSoC < target`.
- `Wattly/Core/BatteryStatusText.swift`
  - Add localized text for `.sailing` reason displaying the resume percentage.
- `Wattly/Core/LegacyBatteryDetail.swift`
  - Support decoding legacy Korean sailing sentences to `.sailing` reason.
- `Wattly/Settings/Settings.swift`
  - Add `StorageKey.batterySailingEnabled`, `StorageKey.batterySailingDelta`, `Defaults.batterySailingEnabled`, `Defaults.batterySailingDelta`.
- `Wattly/Control/BatteryControlClient.swift`
  - Support `lowerHysteresisDelta` parameter in `apply`, `reconcile`, and `installAndApply`.
- `Wattly/Views/BatteryControlBridge.swift`
  - Observe `batterySailingEnabled` and `batterySailingDelta`, calculate `effectiveDelta`, pass to `apply` and `reconcile`, and expand `task(id:)`.
- `Wattly/Core/SettingsReset.swift`
  - Reset `batterySailingEnabled` and `batterySailingDelta` in `applyDefaults`.
- `Wattly/Core/BatterySectionPresentation.swift`
  - Add pure helper functions for sailing mode range calculations and localized range descriptions.
- `Wattly/Views/Settings/SettingsBatterySection.swift`
  - Add Sailing Mode toggle, 2%/5%/10% segment picker, dynamic range description, and wire to `batteryControl.apply`.
- `Wattly/Resources/Localizable.xcstrings`
  - Add localizations for Sailing Mode controls and status strings across supported languages.
- `WattlyTests/BatteryControlProtocolTests.swift`
  - Test delta clamping up to 10%, update hostile delta clamping assertion from 5 to 10, and test JSON serialization of `BatteryControlStatusReason` with `resumePercentage`.
- `WattlyTests/BatteryControlActivityTests.swift`
  - Test inference and resolution of `.sailing` activity.
- `WattlyTests/BatteryControlEngineTests.swift`
  - Test engine transitions: entering holding at limit, transitioning to sailing on SOC drop, and resuming charging at resume threshold.
- `WattlyTests/BatteryStatusTextTests.swift`
  - Test localization of sailing status strings across locales.
- `WattlyTests/LocalizationTests.swift`
  - Verify Sailing Mode translations and format specifiers across locales.
- `WattlyTests/SettingsResetTests.swift`
  - Verify Sailing Mode keys are reset to defaults.
- `WattlyTests/BatterySectionPresentationTests.swift`
  - Test sailing indicator selection, range summary presentation, and disabled reasons.
- `WattlyTests/SettingsBatterySectionTests.swift`
  - Test battery settings section layout, toggle behaviors, and sailing controls.

---

### Task 1: Expand Delta Clamping and Add Sailing Status Reason

**Files:**
- Modify: `FanControlShared/BatteryControlProtocol.swift:30-34`
- Modify: `FanControlShared/BatteryControlStatusReason.swift:15-112`
- Modify: `FanControlShared/BatteryControlActivity.swift:35-46`
- Modify: `WattlyTests/BatteryControlProtocolTests.swift:42-59`
- Modify: `WattlyTests/BatteryControlActivityTests.swift`
- Modify: `WattlyTests/BatteryControlStatusReasonTests.swift`

**Interfaces:**
- Consumes: `BatteryControlConfiguration`, `BatteryControlStatusReason`, `BatteryControlActivity`
- Produces: `BatteryControlConfiguration.clampDelta` supporting values up to 10, `BatteryControlStatusReason.Kind.sailing`, `BatteryControlStatusReason.resumePercentage: Int?`, `BatteryControlActivity.inferred(from:) -> .sailing`

- [ ] **Step 1: Write failing tests and update existing assertions for delta clamping (10%), sailing status reason, and activity inference**

In `WattlyTests/BatteryControlProtocolTests.swift`:
Update existing test `hostileDecodedConfigurationIsNormalizedAndSafeUnnormalized` line 52:
```swift
        #expect(safe.lowerHysteresisDelta == 10)
        #expect(safe.resumePercentage == 90)
```
And add new test:
```swift
    @Test func deltaClampsUpToTenPercent() {
        let configUnder = BatteryControlConfiguration(enabled: true, limitPercentage: 80, lowerHysteresisDelta: 0)
        #expect(configUnder.normalized.lowerHysteresisDelta == 1)

        let configStandard = BatteryControlConfiguration(enabled: true, limitPercentage: 80, lowerHysteresisDelta: 5)
        #expect(configStandard.normalized.lowerHysteresisDelta == 5)

        let configTen = BatteryControlConfiguration(enabled: true, limitPercentage: 80, lowerHysteresisDelta: 10)
        #expect(configTen.normalized.lowerHysteresisDelta == 10)

        let configOver = BatteryControlConfiguration(enabled: true, limitPercentage: 80, lowerHysteresisDelta: 15)
        #expect(configOver.normalized.lowerHysteresisDelta == 10)
    }
```

In `WattlyTests/BatteryControlStatusReasonTests.swift`:
```swift
    @Test func sailingReasonEncodesAndDecodesWithResumePercentage() throws {
        let reason = BatteryControlStatusReason(kind: .sailing, limitPercentage: 80, resumePercentage: 75)
        let data = try JSONEncoder().encode(reason)
        let decoded = try JSONDecoder().decode(BatteryControlStatusReason.self, from: data)
        #expect(decoded.kind == .sailing)
        #expect(decoded.limitPercentage == 80)
        #expect(decoded.resumePercentage == 75)
        #expect(decoded.legacyKoreanDetail == "Sailing 중 (75% 도달 시 충전)")
    }
```

In `WattlyTests/BatteryControlActivityTests.swift`:
```swift
    @Test func sailingReasonInfersSailingActivity() {
        let reason = BatteryControlStatusReason(kind: .sailing, limitPercentage: 80, resumePercentage: 75)
        #expect(BatteryControlActivity.inferred(from: reason) == .sailing)
        #expect(BatteryControlActivity.resolved(explicit: nil, reason: reason) == .sailing)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing WattlyTests/BatteryControlProtocolTests -only-testing WattlyTests/BatteryControlStatusReasonTests -only-testing WattlyTests/BatteryControlActivityTests`
Expected: FAIL with compilation errors (missing `sailing` case / `resumePercentage` property / delta clamped to 5).

- [ ] **Step 3: Implement protocol, reason, and activity updates**

In `FanControlShared/BatteryControlProtocol.swift`:
```swift
    private static func clampDelta(_ value: Int) -> Int { max(1, min(10, value)) }
```

In `FanControlShared/BatteryControlStatusReason.swift`:
```swift
    public enum Kind: String, Codable, Equatable, Sendable, CaseIterable {
        // ... existing cases ...
        case inhibitedAtLimit
        case limitDisabled
        case chargingToTarget
        case onBatteryPower
        case sailing
        case unrecognized
        // ...
    }

    public var kind: Kind
    public var limitPercentage: Int?
    public var resumePercentage: Int?

    public init(kind: Kind, limitPercentage: Int? = nil, resumePercentage: Int? = nil) {
        self.kind = kind
        self.limitPercentage = limitPercentage
        self.resumePercentage = resumePercentage
    }

    private enum CodingKeys: String, CodingKey {
        case kind, limitPercentage, resumePercentage
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .unrecognized
        limitPercentage = try? container.decodeIfPresent(Int.self, forKey: .limitPercentage)
        resumePercentage = try? container.decodeIfPresent(Int.self, forKey: .resumePercentage)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(limitPercentage, forKey: .limitPercentage)
        try container.encodeIfPresent(resumePercentage, forKey: .resumePercentage)
    }

    public var legacyKoreanDetail: String {
        let target = limitPercentage ?? 100
        let resume = resumePercentage ?? max(45, target - 2)
        switch kind {
        case .initializing: return "초기화 중"
        case .powerSourceUnreadable: return "전원 소스를 읽을 수 없습니다"
        case .hardwareUnsupported: return "이 Mac은 충전 제어를 지원하지 않습니다"
        case .releaseFailed: return "충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)"
        case .applyFailed: return "이 Mac에서 충전 제어를 적용하지 못했습니다"
        case .inhibitedAtLimit: return "충전 제한 \(target)% 도달 (전원 어댑터 바이패스 구동)"
        case .limitDisabled: return "충전 제한 비활성화됨"
        case .chargingToTarget: return "목표치(\(target)%)까지 충전 중"
        case .onBatteryPower: return "배터리 전원으로 구동 중"
        case .sailing: return "Sailing 중 (\(resume)% 도달 시 충전)"
        case .unrecognized: return "알 수 없는 상태"
        }
    }
```

In `FanControlShared/BatteryControlActivity.swift`:
```swift
    public static func inferred(from reason: BatteryControlStatusReason?) -> Self? {
        switch reason?.kind {
        case .some(.limitDisabled): return .inactive
        case .some(.chargingToTarget): return .chargingToLimit
        case .some(.inhibitedAtLimit): return .holdingAtLimit
        case .some(.onBatteryPower): return .onBatteryPower
        case .some(.sailing): return .sailing
        case .some(.initializing), .some(.powerSourceUnreadable),
             .some(.hardwareUnsupported), .some(.releaseFailed),
             .some(.applyFailed), .some(.unrecognized), .none:
            return nil
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing WattlyTests/BatteryControlProtocolTests -only-testing WattlyTests/BatteryControlStatusReasonTests -only-testing WattlyTests/BatteryControlActivityTests`
Expected: PASS with all tests in suites succeeding.

- [ ] **Step 5: Commit**

```bash
git add FanControlShared/BatteryControlProtocol.swift FanControlShared/BatteryControlStatusReason.swift FanControlShared/BatteryControlActivity.swift WattlyTests/BatteryControlProtocolTests.swift WattlyTests/BatteryControlActivityTests.swift WattlyTests/BatteryControlStatusReasonTests.swift
git commit -m "feat(battery): add sailing status reason and expand delta clamping to 10%"
```

---

### Task 2: Implement Sailing State Resolution in BatteryControlEngine

**Files:**
- Modify: `FanControlShared/BatteryControlEngine.swift:199-242`
- Modify: `WattlyTests/BatteryControlEngineTests.swift`

**Interfaces:**
- Consumes: `BatteryControlConfiguration`, `BatteryControlStatusReason`, `BatteryControlActivity`
- Produces: `BatteryControlEngine.update` emitting `.sailing` activity and reason with `resumePercentage` when battery is in natural discharge band between target and resume threshold.

- [ ] **Step 1: Write failing tests in `BatteryControlEngineTests.swift` for Sailing Mode state transitions**

```swift
    @Test func engineReportsSailingStateWhileDischargingWithinHysteresisBand() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 80, lowerHysteresisDelta: 5))

        // 1. Initial plugged in at 79% -> Charging to target
        let s1 = engine.update(currentSoC: 79, isPluggedIn: true)
        #expect(s1.mode == .charging)
        #expect(s1.activity == .chargingToLimit)
        #expect(s1.detailReason?.kind == .chargingToTarget)

        // 2. Reaches limit (80%) -> Inhibited at limit
        let s2 = engine.update(currentSoC: 80, isPluggedIn: true)
        #expect(s2.mode == .inhibited)
        #expect(s2.activity == .holdingAtLimit)
        #expect(s2.detailReason?.kind == .inhibitedAtLimit)
        #expect(s2.detailReason?.limitPercentage == 80)

        // 3. Drops to 79% while still plugged in -> Sailing!
        let s3 = engine.update(currentSoC: 79, isPluggedIn: true)
        #expect(s3.mode == .inhibited)
        #expect(s3.activity == .sailing)
        #expect(s3.detailReason?.kind == .sailing)
        #expect(s3.detailReason?.limitPercentage == 80)
        #expect(s3.detailReason?.resumePercentage == 75)

        // 4. Drops to 76% (above resume 75%) -> Still sailing!
        let s4 = engine.update(currentSoC: 76, isPluggedIn: true)
        #expect(s4.mode == .inhibited)
        #expect(s4.activity == .sailing)
        #expect(s4.detailReason?.kind == .sailing)
        #expect(s4.detailReason?.resumePercentage == 75)

        // 5. Drops to 75% (resume threshold: 80 - 5 = 75) -> Resumes charging to limit
        let s5 = engine.update(currentSoC: 75, isPluggedIn: true)
        #expect(s5.mode == .charging)
        #expect(s5.activity == .chargingToLimit)
        #expect(s5.detailReason?.kind == .chargingToTarget)
    }

    @Test func unpluggingFromSailingStateReportsOnBatteryPower() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 80, lowerHysteresisDelta: 5))

        _ = engine.update(currentSoC: 80, isPluggedIn: true)
        let sSailing = engine.update(currentSoC: 78, isPluggedIn: true)
        #expect(sSailing.activity == .sailing)

        let sUnplugged = engine.update(currentSoC: 78, isPluggedIn: false)
        #expect(sUnplugged.mode == .charging)
        #expect(sUnplugged.activity == .onBatteryPower)
        #expect(sUnplugged.detailReason?.kind == .onBatteryPower)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing WattlyTests/BatteryControlEngineTests/engineReportsSailingStateWhileDischargingWithinHysteresisBand`
Expected: FAIL with `s3.activity == .holdingAtLimit` instead of `.sailing`.

- [ ] **Step 3: Update `BatteryControlEngine.swift` implementation**

In `FanControlShared/BatteryControlEngine.swift`:
```swift
    private func detailReason(isPluggedIn: Bool, target: Int, currentSoC: Int) -> BatteryControlStatusReason {
        if !isHardwareSupported { return .init(kind: .hardwareUnsupported) }
        if hasActionableFailure {
            // A failed release is the opposite failure from a failed apply: control IS applied and
            // stuck on, so telling the user it could not be applied would be actively misleading.
            return .init(kind: isCurrentlyInhibited ? .releaseFailed : .applyFailed)
        }
        if isCurrentlyInhibited {
            if currentSoC < target {
                return .init(kind: .sailing, limitPercentage: target, resumePercentage: config.resumePercentage)
            }
            return .init(kind: .inhibitedAtLimit, limitPercentage: target)
        }
        if !config.enabled { return .init(kind: .limitDisabled) }
        return isPluggedIn
            ? .init(kind: .chargingToTarget, limitPercentage: target)
            : .init(kind: .onBatteryPower)
    }

    private func status(currentSoC: Int, isPluggedIn: Bool, target: Int) -> BatteryControlServiceStatus {
        let reason = detailReason(isPluggedIn: isPluggedIn, target: target, currentSoC: currentSoC)
        let mode: BatteryControlServiceMode
        if !isHardwareSupported || hasActionableFailure {
            mode = .unsupported
        } else if isCurrentlyInhibited {
            mode = .inhibited
        } else {
            mode = .charging
        }
        return BatteryControlServiceStatus(
            mode: mode,
            currentPercentage: currentSoC,
            isPowerAdapterConnected: isPluggedIn,
            detail: reason.legacyKoreanDetail,
            updatedAt: Date().timeIntervalSince1970,
            appliedLimitPercentage: (isHardwareSupported && config.enabled && !hasActionableFailure)
                ? config.clampedLimitPercentage : nil,
            isHardwareSupported: isHardwareSupported,
            detailReason: reason,
            activity: BatteryControlActivity.inferred(from: reason)
        )
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing WattlyTests/BatteryControlEngineTests`
Expected: PASS with all tests in `BatteryControlEngineTests` passing.

- [ ] **Step 5: Commit**

```bash
git add FanControlShared/BatteryControlEngine.swift WattlyTests/BatteryControlEngineTests.swift
git commit -m "feat(battery): report sailing activity when inhibited and discharging below target"
```

---

### Task 3: Add Status Text Localization and Legacy Detail Resolution for Sailing

**Files:**
- Modify: `Wattly/Core/BatteryStatusText.swift:45-75`
- Modify: `Wattly/Core/LegacyBatteryDetail.swift:20-56`
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Modify: `WattlyTests/BatteryStatusTextTests.swift`
- Modify: `WattlyTests/LegacyBatteryDetailTests.swift`
- Modify: `WattlyTests/LocalizationTests.swift`

**Interfaces:**
- Consumes: `BatteryControlStatusReason`, `Locale`
- Produces: Localized status text for `.sailing` across locales, and `LegacyBatteryDetail.reason(from:)` parsing legacy sailing string.

- [ ] **Step 1: Write failing tests in `BatteryStatusTextTests.swift`, `LegacyBatteryDetailTests.swift`, and `LocalizationTests.swift`**

In `WattlyTests/BatteryStatusTextTests.swift`:
```swift
    @Test func sailingStatusTextFormatsCorrectlyInKoreanAndEnglish() {
        let reason = BatteryControlStatusReason(kind: .sailing, limitPercentage: 80, resumePercentage: 75)
        let ko = Locale(identifier: "ko")
        let en = Locale(identifier: "en")

        let koText = BatteryStatusText.text(reason: reason, detail: "", locale: ko)
        #expect(koText == "Sailing 중 (75% 도달 시 재충전)")

        let enText = BatteryStatusText.text(reason: reason, detail: "", locale: en)
        #expect(enText == "Sailing (recharging at 75%)")
    }
```

In `WattlyTests/LegacyBatteryDetailTests.swift`:
```swift
    @Test func parsesLegacySailingString() {
        let parsed = LegacyBatteryDetail.reason(from: "Sailing 중 (75% 도달 시 충전)")
        #expect(parsed?.kind == .sailing)
        #expect(parsed?.resumePercentage == 75)
    }
```

In `WattlyTests/LocalizationTests.swift`:
```swift
    @Test func sailingModeTranslationsAcrossLocales() {
        #expect(String(localized: "Sailing 모드", locale: Locale(identifier: "en")) == "Sailing Mode")
        #expect(String(localized: "Sailing 범위", locale: Locale(identifier: "en")) == "Sailing Range")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing WattlyTests/BatteryStatusTextTests/sailingStatusTextFormatsCorrectlyInKoreanAndEnglish -only-testing WattlyTests/LegacyBatteryDetailTests/parsesLegacySailingString`
Expected: FAIL with unmatched cases or default fallback text.

- [ ] **Step 3: Implement `BatteryStatusText.swift`, `LegacyBatteryDetail.swift`, and update `Localizable.xcstrings`**

In `Wattly/Core/BatteryStatusText.swift`:
```swift
        case .onBatteryPower:
            return String(localized: "배터리 전원으로 구동 중", locale: locale)
        case .sailing:
            let resume = Int64(resolved.resumePercentage ?? max(45, Int(target) - 2))
            return String(format: String(localized: "Sailing 중 (%lld%% 도달 시 재충전)", locale: locale),
                          locale: locale, resume)
        case .unrecognized:
            return String(localized: detail, locale: locale)
```

In `Wattly/Core/LegacyBatteryDetail.swift`:
```swift
        if let resume = number(in: detail, between: "Sailing 중 (", and: "% 도달 시 충전)") {
            return .init(kind: .sailing, limitPercentage: nil, resumePercentage: resume)
        }
        return nil
```

In `Wattly/Resources/Localizable.xcstrings`:
Add localization entry for `"Sailing 중 (%lld%% 도달 시 재충전)"`:
- `ko`: `"Sailing 중 (%lld%% 도달 시 재충전)"`
- `en`: `"Sailing (recharging at %lld%%)"`
- `ja`: `"セーリング中 (%lld%% で再充電)"`
- `zh-Hans`: `"航行模式中 (%lld%% 时重新充电)"`
- `zh-Hant`: `"航行模式中 (%lld%% 時重新充電)"`
- `de`: `"Segeln (erneutes Laden bei %lld%%)"`
- `fr`: `"Navigation (recharge à %lld%%)"`
- `es`: `"Navegando (recarga al %lld%%)"`
- `it`: `"Veleggio (ricarica al %lld%%)"`
- `pt-BR`: `"Navegação (recarregando em %lld%%)"`
- `pt-PT`: `"Navegação (a recarregar a %lld%%)"`
- `nl`: `"Zeilen (herladen bij %lld%%)"`
- `sv`: `"Segling (återupptar laddning vid %lld%%)"`
- `da`: `"Sejling (genoplader ved %lld%%)"`
- `fi`: `"Purjehdus (lataus alkaa tasolla %lld%%)"`
- `nb`: `"Seiling (gjenopptar lading ved %lld%%)"`
- `pl`: `"Żeglowanie (ponowne ładowanie od %lld%%)"`
- `cs`: `"Plachtění (dobíjení od %lld%%)"`
- `el`: `"Πλεύση (επαναφόρτιση στο %lld%%)"`
- `he`: `"מצב שיוט (טעינה מחדש ב-%lld%%)"`
- `ar`: `"وضع الإبحار (إعادة الشحن عند %lld%%)"`
- `hi`: `"सेलिंग (पुनः charge %lld%% पर)"`
- `id`: `"Berlayar (mengisi daya kembali pada %lld%%)"`
- `hu`: `"Vitorlázás (újratöltés %lld%%-nál)"`

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing WattlyTests/BatteryStatusTextTests -only-testing WattlyTests/LegacyBatteryDetailTests -only-testing WattlyTests/LocalizationTests`
Expected: PASS with all tests succeeding.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/BatteryStatusText.swift Wattly/Core/LegacyBatteryDetail.swift Wattly/Resources/Localizable.xcstrings WattlyTests/BatteryStatusTextTests.swift WattlyTests/LegacyBatteryDetailTests.swift WattlyTests/LocalizationTests.swift
git commit -m "feat(battery): add localized sailing status strings and legacy detail decoding"
```

---

### Task 4: Add Settings Keys, Client Protocol Integration, Background Bridge, and Presentation Helpers

**Files:**
- Modify: `Wattly/Settings/Settings.swift:430-470`
- Modify: `Wattly/Control/BatteryControlClient.swift:45-90`
- Modify: `Wattly/Views/BatteryControlBridge.swift:7-53`
- Modify: `Wattly/Core/SettingsReset.swift:38-49`
- Modify: `Wattly/Core/BatterySectionPresentation.swift`
- Modify: `WattlyTests/BatteryControlClientTests.swift`
- Modify: `WattlyTests/BatterySectionPresentationTests.swift`
- Modify: `WattlyTests/SettingsResetTests.swift`

**Interfaces:**
- Consumes: `Defaults`, `StorageKey`, `BatteryControlClient`, `BatteryControlBridge`, `SettingsReset`, `BatterySectionPresentation`
- Produces: `Defaults.batterySailingEnabled`, `Defaults.batterySailingDelta`, `StorageKey.batterySailingEnabled`, `StorageKey.batterySailingDelta`, `BatteryControlClient.apply(enabled:limitPercentage:lowerHysteresisDelta:)`, `BatteryControlBridge` reacting to sailing mode changes, `BatterySectionPresentation.sailingRangeDescription(limit:delta:locale:)`

- [ ] **Step 1: Write failing tests in `BatteryControlClientTests.swift`, `BatterySectionPresentationTests.swift`, and `SettingsResetTests.swift`**

In `WattlyTests/BatteryControlClientTests.swift`:
```swift
    @Test func clientSendsConfiguredDeltaToDaemon() async throws {
        var sentConfig: BatteryControlConfiguration?
        let client = BatteryControlClient(requestHandler: { request in
            if case .configure(let data) = request,
               let req = try? BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data) {
                sentConfig = req.configuration
            }
            let status = BatteryControlServiceStatus(mode: .charging, currentPercentage: 80, isPowerAdapterConnected: true, detail: "OK", updatedAt: Date().timeIntervalSince1970)
            let data = try? BatteryControlCodec.encode(status)
            return (data, nil)
        })

        await client.apply(enabled: true, limitPercentage: 85, lowerHysteresisDelta: 5)
        #expect(sentConfig?.enabled == true)
        #expect(sentConfig?.limitPercentage == 85)
        #expect(sentConfig?.lowerHysteresisDelta == 5)
    }
```

In `WattlyTests/BatterySectionPresentationTests.swift`:
```swift
    @Test func sailingRangeDescriptionShowsStopAndResumePercentages() {
        let ko = Locale(identifier: "ko")
        let en = Locale(identifier: "en")

        let koDesc = BatterySectionPresentation.sailingRangeDescription(limit: 80, delta: 5, locale: ko)
        #expect(koDesc == "80% 도달 시 충전 정지, 75%에서 재충전")

        let enDesc = BatterySectionPresentation.sailingRangeDescription(limit: 80, delta: 5, locale: en)
        #expect(enDesc == "Stops at 80%, recharges at 75%")
    }

    @Test func sailingPresetsAreValid() {
        #expect(BatterySectionPresentation.sailingDeltaPresets == [2, 5, 10])
    }
```

In `WattlyTests/SettingsResetTests.swift`:
```swift
    @Test func batterySectionResetIncludesSailingSettings() {
        let d = makeDefaults(#function)
        d.set(true, forKey: StorageKey.batterySailingEnabled)
        d.set(10, forKey: StorageKey.batterySailingDelta)

        SettingsReset.applyDefaults(into: d)

        #expect(d.bool(forKey: StorageKey.batterySailingEnabled) == Defaults.batterySailingEnabled)
        #expect(d.integer(forKey: StorageKey.batterySailingDelta) == Defaults.batterySailingDelta)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing WattlyTests/BatteryControlClientTests/clientSendsConfiguredDeltaToDaemon -only-testing WattlyTests/BatterySectionPresentationTests/sailingRangeDescriptionShowsStopAndResumePercentages -only-testing WattlyTests/SettingsResetTests/batterySectionResetIncludesSailingSettings`
Expected: FAIL with compilation errors (missing properties/methods).

- [ ] **Step 3: Implement settings, client, bridge, settings reset, presentation helpers, and localizations**

In `Wattly/Settings/Settings.swift`:
```swift
    static let batteryLimitEnabled = false
    static let batteryLimitPercentage = 80
    static let batterySailingEnabled = false
    static let batterySailingDelta = 5
```
and `StorageKey`:
```swift
    static let batteryLimitEnabled = "batteryLimitEnabled"
    static let batteryLimitPercentage = "batteryLimitPercentage"
    static let batterySailingEnabled = "batterySailingEnabled"
    static let batterySailingDelta = "batterySailingDelta"
```

In `Wattly/Control/BatteryControlClient.swift`:
```swift
    public func apply(enabled: Bool, limitPercentage: Int, lowerHysteresisDelta: Int = 2) async {
        commandGeneration &+= 1
        let config = BatteryControlConfiguration(enabled: enabled, limitPercentage: limitPercentage, lowerHysteresisDelta: lowerHysteresisDelta)
        let request = BatteryControlConfigurationRequest(configuration: config, generation: commandGeneration)
        guard let data = try? BatteryControlCodec.encode(request) else {
            updateUnavailable("충전 제한 설정을 인코딩할 수 없음")
            return
        }
        await send(.configure(data))
    }

    public func reconcile(enabled: Bool, limitPercentage: Int, lowerHysteresisDelta: Int = 2) async {
        await refreshStatus()
        guard !Task.isCancelled,
              BatteryControlPolicy.shouldReapply(enabled: enabled,
                                                 limitPercentage: limitPercentage,
                                                 status: status) else { return }
        await apply(enabled: enabled, limitPercentage: limitPercentage, lowerHysteresisDelta: lowerHysteresisDelta)
    }

    public func installAndApply(enabled: Bool, limitPercentage: Int, lowerHysteresisDelta: Int = 2, window: NSWindow?) async -> InstallFailure? {
        isInstallingHelper = true
        defer { isInstallingHelper = false }
        if let failure = await PrivilegedHelperInstallSession.run(window: window, postInstall: {
            await self.apply(enabled: enabled, limitPercentage: limitPercentage, lowerHysteresisDelta: lowerHysteresisDelta)
        }) {
            return .install(failure)
        }
        guard status.mode != .unavailable else {
            return .configureRejected(reason: status.detailReason, detail: status.detail)
        }
        return nil
    }
```

In `Wattly/Views/BatteryControlBridge.swift`:
```swift
struct BatteryControlBridge: View {
    let client: BatteryControlClient

    @AppStorage(StorageKey.batteryLimitEnabled) private var enabled = Defaults.batteryLimitEnabled
    @AppStorage(StorageKey.batteryLimitPercentage) private var limit = Defaults.batteryLimitPercentage
    @AppStorage(StorageKey.batterySailingEnabled) private var sailingEnabled = Defaults.batterySailingEnabled
    @AppStorage(StorageKey.batterySailingDelta) private var sailingDelta = Defaults.batterySailingDelta

    private var effectiveDelta: Int {
        sailingEnabled ? sailingDelta : 2
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task {
                await client.apply(enabled: enabled, limitPercentage: limit, lowerHysteresisDelta: effectiveDelta)
            }
            .onChange(of: enabled) { _, val in
                Task { await client.apply(enabled: val, limitPercentage: limit, lowerHysteresisDelta: effectiveDelta) }
            }
            .onChange(of: limit) { _, val in
                Task { await client.apply(enabled: enabled, limitPercentage: val, lowerHysteresisDelta: effectiveDelta) }
            }
            .onChange(of: sailingEnabled) { _, isSailing in
                let delta = isSailing ? sailingDelta : 2
                Task { await client.apply(enabled: enabled, limitPercentage: limit, lowerHysteresisDelta: delta) }
            }
            .onChange(of: sailingDelta) { _, newDelta in
                guard sailingEnabled else { return }
                Task { await client.apply(enabled: enabled, limitPercentage: limit, lowerHysteresisDelta: newDelta) }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                Task { await client.apply(enabled: enabled, limitPercentage: limit, lowerHysteresisDelta: effectiveDelta) }
            }
            .task(id: "\(enabled)-\(limit)-\(sailingEnabled)-\(sailingDelta)") {
                guard enabled else { return }
                var consecutiveUnsupported = 0
                while !Task.isCancelled {
                    try? await Task.sleep(
                        for: .seconds(BatteryControlPolicy.reconcileInterval(
                            consecutiveUnsupported: consecutiveUnsupported))
                    )
                    guard !Task.isCancelled else { return }
                    await client.reconcile(enabled: enabled, limitPercentage: limit, lowerHysteresisDelta: effectiveDelta)
                    consecutiveUnsupported = client.status.mode == .unsupported
                        ? consecutiveUnsupported + 1
                        : 0
                    if client.status.isHardwareSupported == false { return }
                }
            }
    }
}
```

In `Wattly/Core/SettingsReset.swift`:
```swift
        defaults.set(Defaults.batteryLimitEnabled, forKey: StorageKey.batteryLimitEnabled)
        defaults.set(Defaults.batteryLimitPercentage, forKey: StorageKey.batteryLimitPercentage)
        defaults.set(Defaults.batterySailingEnabled, forKey: StorageKey.batterySailingEnabled)
        defaults.set(Defaults.batterySailingDelta, forKey: StorageKey.batterySailingDelta)
```

In `Wattly/Core/BatterySectionPresentation.swift`:
```swift
    static let sailingDeltaPresets = [2, 5, 10]

    static func resumePercentage(limit: Int, delta: Int) -> Int {
        max(45, limit - delta)
    }

    static func sailingRangeDescription(limit: Int, delta: Int, locale: Locale) -> String {
        let resume = Int64(resumePercentage(limit: limit, delta: delta))
        let target = Int64(limit)
        return String(format: String(localized: "%lld%% 도달 시 충전 정지, %lld%%에서 재충전", locale: locale),
                      locale: locale, target, resume)
    }
```

In `Wattly/Resources/Localizable.xcstrings`:
Add localizations for:
- `"%lld%% 도달 시 충전 정지, %lld%%에서 재충전"`:
  - `ko`: `"%lld%% 도달 시 충전 정지, %lld%%에서 재충전"`
  - `en`: `"Stops at %lld%%, recharges at %lld%%"`
- `"Sailing 모드"`:
  - `ko`: `"Sailing 모드"`
  - `en`: `"Sailing Mode"`
- `"충전 상한에 도달한 후 배터리가 하한까지 자연 방전될 때까지 충전을 재개하지 않습니다."`:
  - `ko`: `"충전 상한에 도달한 후 배터리가 하한까지 자연 방전될 때까지 충전을 재개하지 않습니다."`
  - `en`: `"After reaching the limit, charging will not resume until the battery naturally discharges to the lower threshold."`
- `"Sailing 범위"`:
  - `ko`: `"Sailing 범위"`
  - `en`: `"Sailing Range"`

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing WattlyTests/BatteryControlClientTests -only-testing WattlyTests/BatterySectionPresentationTests -only-testing WattlyTests/SettingsResetTests`
Expected: PASS with all tests passing.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Settings/Settings.swift Wattly/Control/BatteryControlClient.swift Wattly/Views/BatteryControlBridge.swift Wattly/Core/SettingsReset.swift Wattly/Core/BatterySectionPresentation.swift Wattly/Resources/Localizable.xcstrings WattlyTests/BatteryControlClientTests.swift WattlyTests/BatterySectionPresentationTests.swift WattlyTests/SettingsResetTests.swift
git commit -m "feat(battery): add sailing mode settings keys, bridge reactivity, client parameters, and reset defaults"
```

---

### Task 5: Integrate Sailing Mode UI in SettingsBatterySection and Verify

**Files:**
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift`
- Modify: `WattlyTests/SettingsBatterySectionTests.swift`

**Interfaces:**
- Consumes: `SettingsBatterySection`, `BatteryControlClient`, `BatterySectionPresentation`, `StorageKey`, `Defaults`
- Produces: Complete Sailing Mode UI in battery settings with live range preview, segment options (2%, 5%, 10%), toggle control, and end-to-end passing test suite.

- [ ] **Step 1: Write failing UI tests in `SettingsBatterySectionTests.swift`**

```swift
    @Test func sailingControlsAreDisabledWhenChargeLimitIsDisabled() {
        #expect(BatterySectionPresentation.isLimitPickerEnabled(isLimitOn: false) == false)
    }

    @Test func sailingDeltaPresetsMatchExpectedValues() {
        #expect(BatterySectionPresentation.sailingDeltaPresets == [2, 5, 10])
    }
```

- [ ] **Step 2: Run test to verify it fails if anything is missing**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing WattlyTests/SettingsBatterySectionTests`
Expected: Passes or reflects current structure.

- [ ] **Step 3: Update `SettingsBatterySection.swift` to render Sailing Mode controls**

In `Wattly/Views/Settings/SettingsBatterySection.swift`:
```swift
    @AppStorage(StorageKey.batteryLimitEnabled) private var batteryLimitEnabled = Defaults.batteryLimitEnabled
    @AppStorage(StorageKey.batteryLimitPercentage) private var batteryLimitPercentage = Defaults.batteryLimitPercentage
    @AppStorage(StorageKey.batterySailingEnabled) private var batterySailingEnabled = Defaults.batterySailingEnabled
    @AppStorage(StorageKey.batterySailingDelta) private var batterySailingDelta = Defaults.batterySailingDelta
    @State private var isInstallFailedAlertPresented = false
    @State private var installErrorMessage = ""
    @State private var isHelpPopoverPresented = false

    private let presetLimits = [80, 85, 90, 95]
    private let sailingPresets = BatterySectionPresentation.sailingDeltaPresets

    private var effectiveDelta: Int {
        batterySailingEnabled ? batterySailingDelta : 2
    }
```

In `SettingsBatterySection.body` under `showsConfigurationControls`:
```swift
    WattlySegment(
        selection: $batteryLimitPercentage,
        options: presetLimits.map { ($0, "\($0)%") },
        pillVPadding: 6,
        isEnabled: isLimitPickerEnabled,
        disabledReason: BatterySectionPresentation
            .limitPickerDisabledReason(isLimitOn: batteryLimitEnabled)
    )

    Divider()
        .overlay(t.rowBorder)
        .padding(.vertical, 4)

    SettingsToggleRow(isOn: $batterySailingEnabled,
                      divider: false,
                      isEnabled: isLimitPickerEnabled,
                      disabledReason: BatterySectionPresentation
                          .limitPickerDisabledReason(isLimitOn: batteryLimitEnabled)) {
        VStack(alignment: .leading, spacing: 2) {
            SettingsRowTitle("Sailing 모드")
            Text("충전 상한에 도달한 후 배터리가 하한까지 자연 방전될 때까지 충전을 재개하지 않습니다.")
                .font(WattlyFont.at(10.5, weight: .regular))
                .foregroundStyle(t.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    if batterySailingEnabled {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sailing 범위")
                    .font(WattlyFont.at(12, weight: .medium))
                    .foregroundStyle(t.text)
                Spacer()
                Text(BatterySectionPresentation.sailingRangeDescription(
                    limit: batteryLimitPercentage,
                    delta: batterySailingDelta,
                    locale: locale))
                    .font(WattlyFont.at(10.5, weight: .medium))
                    .foregroundStyle(t.sub)
            }
            .opacity(isLimitPickerEnabled ? 1 : 0.5)

            WattlySegment(
                selection: $batterySailingDelta,
                options: sailingPresets.map { ($0, "\($0)%") },
                pillVPadding: 6,
                isEnabled: isLimitPickerEnabled,
                disabledReason: BatterySectionPresentation
                    .limitPickerDisabledReason(isLimitOn: batteryLimitEnabled)
            )
        }
    }
```

And update the `.onChange(of: batteryLimitPercentage)`, `.onChange(of: batterySailingEnabled)`, and `.onChange(of: batterySailingDelta)` handlers to push the updated configuration:
```swift
    .onChange(of: batteryLimitPercentage) { _, newLimit in
        guard batteryLimitEnabled else { return }
        Task {
            await batteryControl.apply(enabled: true, limitPercentage: newLimit, lowerHysteresisDelta: effectiveDelta)
        }
    }
    .onChange(of: batterySailingEnabled) { _, isSailing in
        guard batteryLimitEnabled else { return }
        let delta = isSailing ? batterySailingDelta : 2
        Task {
            await batteryControl.apply(enabled: true, limitPercentage: batteryLimitPercentage, lowerHysteresisDelta: delta)
        }
    }
    .onChange(of: batterySailingDelta) { _, newDelta in
        guard batteryLimitEnabled, batterySailingEnabled else { return }
        Task {
            await batteryControl.apply(enabled: true, limitPercentage: batteryLimitPercentage, lowerHysteresisDelta: newDelta)
        }
    }
```

- [ ] **Step 4: Run full test suite and build**

Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'`
Expected: **TEST SUCCEEDED** with all test suites passing.

Run: `xcodebuild build -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'`
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Views/Settings/SettingsBatterySection.swift WattlyTests/SettingsBatterySectionTests.swift
git commit -m "feat(settings): integrate sailing mode toggle, range selector, and live dynamic range feedback"
```
