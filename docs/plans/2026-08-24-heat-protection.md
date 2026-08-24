# Battery Heat Protection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement battery heat protection for Wattly to prevent battery degradation and swelling by automatically inhibiting charging (adapter bypass mode) when the battery temperature exceeds a configurable threshold (e.g. 36°C), and resuming charging only when the battery has cooled down (e.g. <= 34°C) and a minimum cooldown duration (5 minutes) has elapsed.

**Architecture:** Extend `BatteryControlConfiguration` with `heatProtectionEnabled`, `heatProtectionThresholdCelsius`, `heatProtectionResumeDeltaCelsius`, `heatProtectionMinCooldownSeconds`, and an `isActive` computed property (`enabled || heatProtectionEnabled`). In `BatteryControlEngine` and `BatteryControlCoordinator`, evaluate heat protection with top precedence over charge limits, ensuring hardware control is retained, actionable failure detection checks `config.isActive`, and `needsSampling` stays active whenever heat protection is enabled. In `WattlyFanDaemon`, read `AppleSmartBattery`'s `Temperature` in IOKit and thread it through `BatteryPowerSourceReading`. Expose user controls in `SettingsBatterySection` (toggle with helper installation auto-prompt and [34°C, 36°C, 38°C, 40°C] segment picker) with active polling and localized status feedback across all supported languages.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Observation, Swift Testing, IOKit (`AppleSmartBattery`), Codable JSON over privileged XPC, macOS 14+, Apple Silicon arm64

## Global Constraints

- Target macOS 14.0 and later on Apple Silicon arm64; no Intel path.
- Add no third-party dependencies.
- Preserve backward and forward compatibility across the privileged XPC interface for older helpers and app versions.
- Leniently decode `BatteryControlStatusReason`, `BatteryControlActivity`, and `BatteryControlConfiguration` without throwing on unknown or malformed tokens.
- Heat protection takes top precedence over charge limits: when heat protection is active, `shouldInhibit` is `true` (adapter bypass mode).
- Dual exit condition: temperature must drop to `threshold - resumeDelta` AND cooldown time (`minCooldownSeconds`, default 300s) must elapse before charging can resume.
- Fail-Closed Safety: if battery temperature sensor is unreadable or fails while heat protection is active, charging remains inhibited and `heatProtectionTriggeredAt` timestamp is preserved across dropouts.
- The full validation gate is `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData` and `xcodebuild build -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData`.

---

## Scope and Settled Decisions

Primary specification:
- `docs/features/battery-management/05-heat-protection.md`

Settled decisions:
1. **Configuration fields & `isActive` property:** Add `heatProtectionEnabled` (default `false`), `heatProtectionThresholdCelsius` (default `36`, clamped `30...45`), `heatProtectionResumeDeltaCelsius` (default `2`, clamped `1...5`), and `heatProtectionMinCooldownSeconds` (default `300.0`, clamped `60...1800`) to `BatteryControlConfiguration`. Add `public var isActive: Bool { enabled || heatProtectionEnabled }`.
2. **Coordinator & Engine Hardware Control:** `BatteryControlCoordinator` branches on `!normalized.isActive` rather than `!normalized.enabled` before calling `releaseVerified()`, and uses `engine.configuration.isActive` in `hardwareFailureReason`. `BatteryControlEngine.needsSampling` returns true when `config.isActive` is true.
3. **Policy Acceptance & Reapply:** Update `BatteryControlPolicy.accepted` and `shouldReapply` to evaluate normalized `isActive` and configuration equality rather than assuming `!enabled` always implies gate `.allowed`.
4. **IOKit Temperature Telemetry:** Root daemon reads `AppleSmartBattery`'s `Temperature` property (centi-°C, divided by 100.0) in `FanControlDaemon.readPowerSourceState()`, passed in `BatteryPowerSourceReading`.
5. **Reason & Activity:** Add `.heatProtectionActive`, `.heatProtectionCooldown`, and `.batterySensorUnreadable` to `BatteryControlStatusReason.Kind`, mapping to `BatteryControlActivity.heatProtection`.
6. **Settings & UI Integration:**
   - Add `@AppStorage(StorageKey.batteryHeatProtectionEnabled)` (default `false`) and `@AppStorage(StorageKey.batteryHeatProtectionThreshold)` (default `36`).
   - UI Segment picker options: `[34, 36, 38, 40]` °C.
   - Turning on Heat Protection when helper is uninstalled (`mode == .unavailable`) prompts for helper installation via `installAndApply`.
   - Update `BatterySectionPresentation.shouldPollStatus` and `SettingsBatterySection` task to take `isFeatureActive` (`batteryLimitEnabled || batteryHeatProtectionEnabled`) into account.
   - Live status row displays `"발열 보호 중 (배터리 37.2°C, 34°C 도달 및 쿨다운 후 재개)"`.
   - Fully localized across 24 languages in `Localizable.xcstrings`.

---

## File Structure

### Modify
- `FanControlShared/BatteryControlProtocol.swift`
  - Add heat protection configuration fields, clamping, normalization, `resumeTemperatureCelsius`, and `isActive` computed property.
  - Add `batteryTemperatureCelsius: Double?` to `BatteryControlServiceStatus`.
- `FanControlShared/BatteryDaemonControlService.swift`
  - Update `BatteryPowerSourceReading` in place to include `temperatureCelsius: Double? = nil`.
  - Pass `temperatureCelsius` to coordinator methods.
- `FanControlShared/BatteryControlStatusReason.swift`
  - Add `.heatProtectionActive`, `.heatProtectionCooldown`, `.batterySensorUnreadable` to `Kind`.
  - Add `currentTemperatureCelsius: Double?`, `thresholdTemperatureCelsius: Int?`, `cooldownRemainingSeconds: Int?` fields with lenient Codable encoding/decoding.
  - Add legacy Korean descriptions for new status reasons.
- `FanControlShared/BatteryControlActivity.swift`
  - Map new heat protection status reason kinds to `BatteryControlActivity.heatProtection`.
- `FanControlShared/BatteryControlPolicy.swift`
  - Update `shouldReapply` and `accepted` to respect `configuration.isActive` and heat protection state.
- `FanControlShared/BatteryControlEngine.swift`
  - Implement heat protection state tracking, dual exit conditions, priority over charge limits, `needsSampling` with `config.isActive`, timestamp preservation on dropouts, and detail reason emission.
- `FanControlShared/BatteryControlCoordinator.swift`
  - Check `!desired.isActive` instead of `!desired.enabled` in `restore`, `configure`, and `reconcile`.
  - Check `engine.configuration.isActive` in `hardwareFailureReason(in:)`.
  - Pass `temperatureCelsius` to `engine.update` and status publication.
- `WattlyFanDaemon/FanControlDaemon.swift`
  - In `readPowerSourceState()`, read `AppleSmartBattery` `Temperature` property and pass to `BatteryPowerSourceReading`.
- `Wattly/Settings/Settings.swift`
  - Add `StorageKey.batteryHeatProtectionEnabled`, `StorageKey.batteryHeatProtectionThreshold`, and default values.
- `Wattly/Control/BatteryControlClient.swift`
  - Thread heat protection parameters through `apply`, `reconcile`, `disableAndConfirm`, and `installAndApply`.
- `Wattly/Views/BatteryControlBridge.swift`
  - Observe heat protection `@AppStorage` keys, calculate configuration, and pass to client. Only call full release when `!configuration.isActive`.
- `Wattly/Core/SettingsReset.swift`
  - Reset heat protection keys in `applyDefaults`.
- `Wattly/Core/BatterySectionPresentation.swift`
  - Add `heatProtectionThresholdPresets = [34, 36, 38, 40]`, helper formatting for heat protection descriptions, `shouldPollStatus` accepting `isFeatureActive`, and indicator mapping.
- `Wattly/Core/BatteryStatusText.swift`
  - Add localized text formatting for `.heatProtectionActive`, `.heatProtectionCooldown`, `.batterySensorUnreadable`.
- `Wattly/Core/LegacyBatteryDetail.swift`
  - Add parser for legacy heat protection strings.
- `Wattly/Views/Settings/SettingsBatterySection.swift`
  - Add Heat Protection toggle (with helper installer trigger), segmented threshold picker, help popover, and wired handlers.
- `Wattly/Resources/Localizable.xcstrings`
  - Add all localized strings for heat protection controls and statuses.

### Test Files
- `WattlyTests/BatteryControlProtocolTests.swift`
- `WattlyTests/BatteryControlStatusReasonTests.swift`
- `WattlyTests/BatteryControlActivityTests.swift`
- `WattlyTests/BatteryControlPolicyTests.swift`
- `WattlyTests/BatteryControlEngineTests.swift`
- `WattlyTests/BatteryControlCoordinatorTests.swift`
- `WattlyTests/BatteryDaemonControlServiceTests.swift`
- `WattlyTests/BatteryStatusTextTests.swift`
- `WattlyTests/LegacyBatteryDetailTests.swift`
- `WattlyTests/BatteryControlClientTests.swift`
- `WattlyTests/BatterySectionPresentationTests.swift`
- `WattlyTests/SettingsResetTests.swift`
- `WattlyTests/SettingsBatterySectionTests.swift`
- `WattlyTests/LocalizationTests.swift`

---

## Tasks

### Task 1: Protocol, Configuration Model & Status Reasoning Extension

**Files:**
- Modify: `FanControlShared/BatteryControlProtocol.swift`
- Modify: `FanControlShared/BatteryDaemonControlService.swift:3-12`
- Modify: `FanControlShared/BatteryControlStatusReason.swift`
- Modify: `FanControlShared/BatteryControlActivity.swift`
- Modify: `WattlyTests/BatteryControlProtocolTests.swift`
- Modify: `WattlyTests/BatteryControlStatusReasonTests.swift`
- Modify: `WattlyTests/BatteryControlActivityTests.swift`

**Interfaces:**
- Consumes: `BatteryControlConfiguration`, `BatteryControlStatusReason`, `BatteryControlActivity`
- Produces: `BatteryControlConfiguration` with `heatProtectionEnabled`, `heatProtectionThresholdCelsius`, `heatProtectionResumeDeltaCelsius`, `heatProtectionMinCooldownSeconds`, `resumeTemperatureCelsius`, and `isActive`. `BatteryPowerSourceReading` (in `BatteryDaemonControlService.swift`) and `BatteryControlServiceStatus` with `temperatureCelsius: Double?` / `batteryTemperatureCelsius: Double?`. `BatteryControlStatusReason.Kind` with `.heatProtectionActive`, `.heatProtectionCooldown`, `.batterySensorUnreadable`.

- [ ] **Step 1: Write failing tests for configuration normalization, `isActive`, status reason serialization, and activity mapping**

In `WattlyTests/BatteryControlProtocolTests.swift`:
```swift
    @Test func heatProtectionConfigurationClampingAndNormalization() {
        let configUnder = BatteryControlConfiguration(
            enabled: true,
            limitPercentage: 80,
            lowerHysteresisDelta: 2,
            heatProtectionEnabled: true,
            heatProtectionThresholdCelsius: 25,
            heatProtectionResumeDeltaCelsius: 0,
            heatProtectionMinCooldownSeconds: 30
        )
        #expect(configUnder.normalized.heatProtectionThresholdCelsius == 30)
        #expect(configUnder.normalized.heatProtectionResumeDeltaCelsius == 1)
        #expect(configUnder.normalized.heatProtectionMinCooldownSeconds == 60)
        #expect(configUnder.normalized.resumeTemperatureCelsius == 29)
        #expect(configUnder.isActive == true)

        let configOver = BatteryControlConfiguration(
            enabled: false,
            limitPercentage: 80,
            lowerHysteresisDelta: 2,
            heatProtectionEnabled: true,
            heatProtectionThresholdCelsius: 55,
            heatProtectionResumeDeltaCelsius: 10,
            heatProtectionMinCooldownSeconds: 3600
        )
        #expect(configOver.normalized.heatProtectionThresholdCelsius == 45)
        #expect(configOver.normalized.heatProtectionResumeDeltaCelsius == 5)
        #expect(configOver.normalized.heatProtectionMinCooldownSeconds == 1800)
        #expect(configOver.normalized.resumeTemperatureCelsius == 40)
        #expect(configOver.isActive == true)

        let configOff = BatteryControlConfiguration(enabled: false, heatProtectionEnabled: false)
        #expect(configOff.isActive == false)
    }

    @Test func batteryPowerSourceReadingCarriesTemperature() {
        let reading = BatteryPowerSourceReading(stateOfCharge: 80, isPluggedIn: true, temperatureCelsius: 34.5)
        #expect(reading.stateOfCharge == 80)
        #expect(reading.isPluggedIn == true)
        #expect(reading.temperatureCelsius == 34.5)
    }
```

In `WattlyTests/BatteryControlStatusReasonTests.swift`:
```swift
    @Test func heatProtectionStatusReasonsEncodeAndDecode() throws {
        let activeReason = BatteryControlStatusReason(
            kind: .heatProtectionActive,
            currentTemperatureCelsius: 37.5,
            thresholdTemperatureCelsius: 36,
            resumeTemperatureCelsius: 34
        )
        let activeData = try JSONEncoder().encode(activeReason)
        let decodedActive = try JSONDecoder().decode(BatteryControlStatusReason.self, from: activeData)
        #expect(decodedActive.kind == .heatProtectionActive)
        #expect(decodedActive.currentTemperatureCelsius == 37.5)
        #expect(decodedActive.thresholdTemperatureCelsius == 36)
        #expect(decodedActive.resumeTemperatureCelsius == 34)

        let cooldownReason = BatteryControlStatusReason(
            kind: .heatProtectionCooldown,
            currentTemperatureCelsius: 33.2,
            cooldownRemainingSeconds: 120
        )
        let cooldownData = try JSONEncoder().encode(cooldownReason)
        let decodedCooldown = try JSONDecoder().decode(BatteryControlStatusReason.self, from: cooldownData)
        #expect(decodedCooldown.kind == .heatProtectionCooldown)
        #expect(decodedCooldown.currentTemperatureCelsius == 33.2)
        #expect(decodedCooldown.cooldownRemainingSeconds == 120)

        let unreadableReason = BatteryControlStatusReason(kind: .batterySensorUnreadable)
        let unreadableData = try JSONEncoder().encode(unreadableReason)
        let decodedUnreadable = try JSONDecoder().decode(BatteryControlStatusReason.self, from: unreadableData)
        #expect(decodedUnreadable.kind == .batterySensorUnreadable)
    }
```

In `WattlyTests/BatteryControlActivityTests.swift`:
```swift
    @Test func heatProtectionReasonsInferHeatProtectionActivity() {
        let activeReason = BatteryControlStatusReason(kind: .heatProtectionActive)
        #expect(BatteryControlActivity.inferred(from: activeReason) == .heatProtection)

        let cooldownReason = BatteryControlStatusReason(kind: .heatProtectionCooldown)
        #expect(BatteryControlActivity.inferred(from: cooldownReason) == .heatProtection)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing WattlyTests/BatteryControlProtocolTests -only-testing WattlyTests/BatteryControlStatusReasonTests -only-testing WattlyTests/BatteryControlActivityTests`
Expected: FAIL with compilation errors.

- [ ] **Step 3: Implement data structures in `BatteryControlProtocol.swift`, `BatteryDaemonControlService.swift`, `BatteryControlStatusReason.swift`, and `BatteryControlActivity.swift`**

In `FanControlShared/BatteryControlProtocol.swift`:
```swift
public struct BatteryControlConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var limitPercentage: Int
    public var lowerHysteresisDelta: Int
    public var heatProtectionEnabled: Bool
    public var heatProtectionThresholdCelsius: Int
    public var heatProtectionResumeDeltaCelsius: Int
    public var heatProtectionMinCooldownSeconds: TimeInterval

    public init(
        enabled: Bool = false,
        limitPercentage: Int = 80,
        lowerHysteresisDelta: Int = 2,
        heatProtectionEnabled: Bool = false,
        heatProtectionThresholdCelsius: Int = 36,
        heatProtectionResumeDeltaCelsius: Int = 2,
        heatProtectionMinCooldownSeconds: TimeInterval = 300.0
    ) {
        self.enabled = enabled
        self.limitPercentage = limitPercentage
        self.lowerHysteresisDelta = lowerHysteresisDelta
        self.heatProtectionEnabled = heatProtectionEnabled
        self.heatProtectionThresholdCelsius = heatProtectionThresholdCelsius
        self.heatProtectionResumeDeltaCelsius = heatProtectionResumeDeltaCelsius
        self.heatProtectionMinCooldownSeconds = heatProtectionMinCooldownSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, limitPercentage, lowerHysteresisDelta
        case heatProtectionEnabled, heatProtectionThresholdCelsius, heatProtectionResumeDeltaCelsius, heatProtectionMinCooldownSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? false
        limitPercentage = (try? container.decode(Int.self, forKey: .limitPercentage)) ?? 80
        lowerHysteresisDelta = (try? container.decode(Int.self, forKey: .lowerHysteresisDelta)) ?? 2
        heatProtectionEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .heatProtectionEnabled)) ?? false
        heatProtectionThresholdCelsius = (try? container.decodeIfPresent(Int.self, forKey: .heatProtectionThresholdCelsius)) ?? 36
        heatProtectionResumeDeltaCelsius = (try? container.decodeIfPresent(Int.self, forKey: .heatProtectionResumeDeltaCelsius)) ?? 2
        heatProtectionMinCooldownSeconds = (try? container.decodeIfPresent(TimeInterval.self, forKey: .heatProtectionMinCooldownSeconds)) ?? 300.0
    }

    public var normalized: BatteryControlConfiguration {
        var copy = self
        copy.limitPercentage = Self.clampLimit(limitPercentage)
        copy.lowerHysteresisDelta = Self.clampDelta(lowerHysteresisDelta)
        copy.heatProtectionThresholdCelsius = Self.clampThreshold(heatProtectionThresholdCelsius)
        copy.heatProtectionResumeDeltaCelsius = Self.clampResumeDelta(heatProtectionResumeDeltaCelsius)
        copy.heatProtectionMinCooldownSeconds = Self.clampCooldown(heatProtectionMinCooldownSeconds)
        return copy
    }

    public var isActive: Bool {
        enabled || heatProtectionEnabled
    }

    public var clampedLimitPercentage: Int { Self.clampLimit(limitPercentage) }
    public var clampedHeatProtectionThresholdCelsius: Int { Self.clampThreshold(heatProtectionThresholdCelsius) }
    public var clampedHeatProtectionResumeDeltaCelsius: Int { Self.clampResumeDelta(heatProtectionResumeDeltaCelsius) }
    public var clampedHeatProtectionMinCooldownSeconds: TimeInterval { Self.clampCooldown(heatProtectionMinCooldownSeconds) }

    public var resumePercentage: Int {
        max(45, clampedLimitPercentage - Self.clampDelta(lowerHysteresisDelta))
    }

    public var resumeTemperatureCelsius: Int {
        max(20, clampedHeatProtectionThresholdCelsius - clampedHeatProtectionResumeDeltaCelsius)
    }

    private static func clampLimit(_ value: Int) -> Int { max(50, min(100, value)) }
    private static func clampDelta(_ value: Int) -> Int { max(1, min(10, value)) }
    private static func clampThreshold(_ value: Int) -> Int { max(30, min(45, value)) }
    private static func clampResumeDelta(_ value: Int) -> Int { max(1, min(5, value)) }
    private static func clampCooldown(_ value: TimeInterval) -> TimeInterval { max(60, min(1800, value)) }
}
```
Add `public var batteryTemperatureCelsius: Double? = nil` to `BatteryControlServiceStatus`.

In `FanControlShared/BatteryDaemonControlService.swift`:
Update existing struct definition in place:
```swift
public struct BatteryPowerSourceReading: Equatable, Sendable {
    public let stateOfCharge: Int
    public let isPluggedIn: Bool
    public let temperatureCelsius: Double?

    public init(stateOfCharge: Int, isPluggedIn: Bool, temperatureCelsius: Double? = nil) {
        self.stateOfCharge = stateOfCharge
        self.isPluggedIn = isPluggedIn
        self.temperatureCelsius = temperatureCelsius
    }
}
```

In `FanControlShared/BatteryControlStatusReason.swift`:
```swift
    public enum Kind: String, Codable, Equatable, Sendable, CaseIterable {
        // ... existing cases ...
        case sailing
        case heatProtectionActive
        case heatProtectionCooldown
        case batterySensorUnreadable
        case persistenceReadFailed
        // ...
    }

    public var kind: Kind
    public var limitPercentage: Int?
    public var resumePercentage: Int?
    public var currentTemperatureCelsius: Double?
    public var thresholdTemperatureCelsius: Int?
    public var resumeTemperatureCelsius: Int?
    public var cooldownRemainingSeconds: Int?

    public init(
        kind: Kind,
        limitPercentage: Int? = nil,
        resumePercentage: Int? = nil,
        currentTemperatureCelsius: Double? = nil,
        thresholdTemperatureCelsius: Int? = nil,
        resumeTemperatureCelsius: Int? = nil,
        cooldownRemainingSeconds: Int? = nil
    ) {
        self.kind = kind
        self.limitPercentage = limitPercentage
        self.resumePercentage = resumePercentage
        self.currentTemperatureCelsius = currentTemperatureCelsius
        self.thresholdTemperatureCelsius = thresholdTemperatureCelsius
        self.resumeTemperatureCelsius = resumeTemperatureCelsius
        self.cooldownRemainingSeconds = cooldownRemainingSeconds
    }
```
Update `CodingKeys`, `init(from decoder:)`, `encode(to encoder:)`, and `legacyKoreanDetail`:
```swift
        case .heatProtectionActive:
            let tempStr = currentTemperatureCelsius.map { String(format: "%.1f", $0) } ?? "?"
            let resume = resumeTemperatureCelsius ?? 34
            return "발열 보호 중 (배터리 \(tempStr)°C / \(resume)°C 이하 시 재개)"
        case .heatProtectionCooldown:
            let remaining = cooldownRemainingSeconds ?? 0
            return "발열 보호 쿨다운 중 (\(remaining)초 후 충전 재개)"
        case .batterySensorUnreadable:
            return "배터리 온도 센서를 읽을 수 없습니다"
```

In `FanControlShared/BatteryControlActivity.swift`:
```swift
        case .some(.heatProtectionActive), .some(.heatProtectionCooldown):
            return .heatProtection
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing WattlyTests/BatteryControlProtocolTests -only-testing WattlyTests/BatteryControlStatusReasonTests -only-testing WattlyTests/BatteryControlActivityTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FanControlShared/BatteryControlProtocol.swift FanControlShared/BatteryDaemonControlService.swift FanControlShared/BatteryControlStatusReason.swift FanControlShared/BatteryControlActivity.swift WattlyTests/BatteryControlProtocolTests.swift WattlyTests/BatteryControlStatusReasonTests.swift WattlyTests/BatteryControlActivityTests.swift
git commit -m "feat(battery): add heat protection protocol fields, isActive property, and status reasons"
```

---

### Task 2: Engine, Coordinator & Policy Heat Protection Logic

**Files:**
- Modify: `FanControlShared/BatteryControlPolicy.swift`
- Modify: `FanControlShared/BatteryControlEngine.swift`
- Modify: `FanControlShared/BatteryControlCoordinator.swift`
- Modify: `WattlyTests/BatteryControlPolicyTests.swift`
- Modify: `WattlyTests/BatteryControlEngineTests.swift`
- Modify: `WattlyTests/BatteryControlCoordinatorTests.swift`

**Interfaces:**
- Consumes: `BatteryControlConfiguration`, `BatteryControlStatusReason`, `BatteryControlActivity`
- Produces:
  - `BatteryControlEngine.needsSampling` returning true when `config.isActive` is true.
  - `BatteryControlEngine.update` evaluating heat protection with top precedence, dual exit conditions, timestamp preservation across dropouts, and fail-closed unreadable sensor handling.
  - `BatteryControlCoordinator` checking `!desired.isActive` / `!normalized.isActive` before releasing hardware control, and using `engine.configuration.isActive` in `hardwareFailureReason`.
  - `BatteryControlPolicy.accepted` acknowledging active heat protection policies even when charge limit is off.

- [ ] **Step 1: Write failing tests for Engine, Coordinator, and Policy heat protection handling**

In `WattlyTests/BatteryControlPolicyTests.swift`:
```swift
    @Test func policyAcceptsHeatProtectionWithoutChargeLimit() {
        let config = BatteryControlConfiguration(
            enabled: false,
            heatProtectionEnabled: true,
            heatProtectionThresholdCelsius: 36
        )
        var status = BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 80,
            isPowerAdapterConnected: true,
            detail: "OK",
            updatedAt: 1000,
            desiredConfiguration: config,
            actualGate: .inhibited(appliedLimitPercentage: nil),
            lastMaintenance: .init(trigger: .clientConfiguration, result: .applied, occurredAt: 1000, reason: nil)
        )
        #expect(BatteryControlPolicy.accepted(configuration: config, by: status) == true)
    }
```

In `WattlyTests/BatteryControlEngineTests.swift`:
```swift
    @Test func heatProtectionTriggersAndInhibitsChargingRegardlessOfLimit() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(
            enabled: false, // Charge limit disabled
            heatProtectionEnabled: true,
            heatProtectionThresholdCelsius: 36,
            heatProtectionResumeDeltaCelsius: 2,
            heatProtectionMinCooldownSeconds: 300
        ))

        #expect(engine.needsSampling == true)

        // 1. Temperature normal (34°C) -> Charging allowed
        let s1 = engine.update(currentSoC: 50, isPluggedIn: true, temperatureCelsius: 34.0, now: 1000)
        #expect(s1.mode == .charging)
        #expect(s1.activity == .inactive)

        // 2. Temperature exceeds threshold (36.5°C) -> Heat protection inhibits charging!
        let s2 = engine.update(currentSoC: 50, isPluggedIn: true, temperatureCelsius: 36.5, now: 1010)
        #expect(s2.mode == .inhibited)
        #expect(s2.activity == .heatProtection)
        #expect(s2.detailReason?.kind == .heatProtectionActive)
        #expect(s2.detailReason?.currentTemperatureCelsius == 36.5)

        // 3. Temperature drops to 33.5°C (below resume 34°C), but cooldown timer not elapsed (elapsed 60s < 300s) -> Stays inhibited in cooldown!
        let s3 = engine.update(currentSoC: 50, isPluggedIn: true, temperatureCelsius: 33.5, now: 1070)
        #expect(s3.mode == .inhibited)
        #expect(s3.activity == .heatProtection)
        #expect(s3.detailReason?.kind == .heatProtectionCooldown)
        #expect(s3.detailReason?.cooldownRemainingSeconds == 240)

        // 4. Cooldown elapsed (310s >= 300s) and temperature still cool (33.0°C) -> Exits heat protection and resumes charging!
        let s4 = engine.update(currentSoC: 50, isPluggedIn: true, temperatureCelsius: 33.0, now: 1320)
        #expect(s4.mode == .charging)
        #expect(s4.activity == .inactive)

        // 5. If sensor fails while in heat protection -> stays inhibited (fail-closed) and preserves trigger timestamp
        _ = engine.update(currentSoC: 50, isPluggedIn: true, temperatureCelsius: 37.0, now: 1400)
        let sFail = engine.update(currentSoC: 50, isPluggedIn: true, temperatureCelsius: nil, now: 1410)
        #expect(sFail.mode == .inhibited)
        #expect(sFail.detailReason?.kind == .batterySensorUnreadable)
    }
```

In `WattlyTests/BatteryControlCoordinatorTests.swift`:
```swift
    @Test func coordinatorDoesNotReleaseHardwareWhenHeatProtectionIsActiveWithoutChargeLimit() {
        let store = MockBatteryPolicyStore()
        let hw = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: hw)
        let coordinator = BatteryControlCoordinator(ownerUID: 501, store: store, engine: engine, now: { 1000 })

        let config = BatteryControlConfiguration(enabled: false, heatProtectionEnabled: true)
        let status = coordinator.configure(config, trigger: .clientConfiguration, currentSoC: 50, isPluggedIn: true, temperatureCelsius: 37.0)

        #expect(status.mode == .inhibited)
        #expect(status.activity == .heatProtection)
        #expect(hw.lastInhibited == true)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing WattlyTests/BatteryControlPolicyTests -only-testing WattlyTests/BatteryControlEngineTests -only-testing WattlyTests/BatteryControlCoordinatorTests`
Expected: FAIL.

- [ ] **Step 3: Implement changes in `BatteryControlPolicy.swift`, `BatteryControlEngine.swift`, and `BatteryControlCoordinator.swift`**

In `FanControlShared/BatteryControlPolicy.swift`:
```swift
    public static func accepted(
        configuration: BatteryControlConfiguration,
        by status: BatteryControlServiceStatus
    ) -> Bool {
        guard status.desiredConfiguration?.normalized == configuration.normalized,
              let maintenance = status.lastMaintenance,
              maintenance.result != .failed else { return false }
        if !configuration.isActive {
            return status.actualGate?.state == .allowed
                || status.releaseVerification?.isSafeToRemove == true
        }
        guard maintenance.trigger == .clientConfiguration,
              maintenance.result == .applied || maintenance.result == .verified else { return false }
        guard let gate = status.actualGate else { return false }
        return gate.state != .unreadable && gate.state != .unrecognized
    }
```

In `FanControlShared/BatteryControlEngine.swift`:
```swift
    private var isInHeatProtection: Bool = false
    private var heatProtectionTriggeredAt: TimeInterval?

    public var needsSampling: Bool {
        guard isHardwareSupported else { return false }
        return config.isActive || isCurrentlyInhibited || (!hasInitializedState && !isWriteLatched)
    }

    public func update(
        currentSoC: Int,
        isPluggedIn: Bool,
        temperatureCelsius: Double? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> BatteryControlServiceStatus {
        guard isHardwareSupported else {
            return status(currentSoC: currentSoC, isPluggedIn: isPluggedIn,
                          target: config.clampedLimitPercentage, temperatureCelsius: temperatureCelsius, now: now)
        }
        guard normalizeOnFirstUpdate() else {
            return status(currentSoC: currentSoC, isPluggedIn: isPluggedIn,
                          target: config.clampedLimitPercentage, temperatureCelsius: temperatureCelsius, now: now)
        }

        // 1. Evaluate Heat Protection
        if config.heatProtectionEnabled && isPluggedIn {
            if let temp = temperatureCelsius {
                let threshold = Double(config.clampedHeatProtectionThresholdCelsius)
                let resumeTemp = Double(config.resumeTemperatureCelsius)
                let minCooldown = config.clampedHeatProtectionMinCooldownSeconds

                if !isInHeatProtection && temp >= threshold {
                    isInHeatProtection = true
                    heatProtectionTriggeredAt = now
                } else if isInHeatProtection {
                    let elapsed = now - (heatProtectionTriggeredAt ?? now)
                    let cooledDown = temp <= resumeTemp
                    let cooldownElapsed = elapsed >= minCooldown
                    if cooledDown && cooldownElapsed {
                        isInHeatProtection = false
                        heatProtectionTriggeredAt = nil
                    }
                }
            } else if isInHeatProtection {
                // Fail-Closed: keep heat protection active, preserve heatProtectionTriggeredAt
                isInHeatProtection = true
            }
        } else {
            isInHeatProtection = false
            heatProtectionTriggeredAt = nil
        }

        // 2. Evaluate shouldInhibit
        let target = config.clampedLimitPercentage
        let shouldInhibit: Bool
        if isInHeatProtection {
            shouldInhibit = true
        } else if config.enabled && isPluggedIn {
            shouldInhibit = isCurrentlyInhibited
                ? currentSoC > config.resumePercentage
                : currentSoC >= target
        } else {
            shouldInhibit = false
        }

        if shouldInhibit != isCurrentlyInhibited {
            if attemptWrite(inhibited: shouldInhibit, targetLimit: shouldInhibit ? target : 100) {
                isCurrentlyInhibited = shouldInhibit
            }
        } else {
            if failureProvenance != .verifiedRelease {
                beginRecoveryWindow()
            }
        }

        return status(currentSoC: currentSoC, isPluggedIn: isPluggedIn, target: target, temperatureCelsius: temperatureCelsius, now: now)
    }

    private func detailReason(
        isPluggedIn: Bool,
        target: Int,
        currentSoC: Int,
        temperatureCelsius: Double?,
        now: TimeInterval
    ) -> BatteryControlStatusReason {
        if !isHardwareSupported { return .init(kind: .hardwareUnsupported) }
        if hasActionableFailure {
            return .init(kind: isCurrentlyInhibited ? .releaseFailed : .applyFailed)
        }
        if isInHeatProtection {
            guard let temp = temperatureCelsius else {
                return .init(kind: .batterySensorUnreadable)
            }
            let threshold = config.clampedHeatProtectionThresholdCelsius
            let resume = config.resumeTemperatureCelsius
            let elapsed = now - (heatProtectionTriggeredAt ?? now)
            let remainingCooldown = max(0, Int((config.clampedHeatProtectionMinCooldownSeconds - elapsed).rounded()))

            if temp <= Double(resume) && remainingCooldown > 0 {
                return .init(
                    kind: .heatProtectionCooldown,
                    currentTemperatureCelsius: temp,
                    cooldownRemainingSeconds: remainingCooldown
                )
            }
            return .init(
                kind: .heatProtectionActive,
                currentTemperatureCelsius: temp,
                thresholdTemperatureCelsius: threshold,
                resumeTemperatureCelsius: resume
            )
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

    private func status(
        currentSoC: Int,
        isPluggedIn: Bool,
        target: Int,
        temperatureCelsius: Double?,
        now: TimeInterval
    ) -> BatteryControlServiceStatus {
        let reason = detailReason(isPluggedIn: isPluggedIn, target: target, currentSoC: currentSoC, temperatureCelsius: temperatureCelsius, now: now)
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
            activity: BatteryControlActivity.inferred(from: reason),
            actualGate: lastVerifiedGate,
            batteryTemperatureCelsius: temperatureCelsius
        )
    }
```

In `FanControlShared/BatteryControlCoordinator.swift`:
Replace `!desired.enabled` / `!normalized.enabled` with `!desired.isActive` / `!normalized.isActive` in `restore`, `restoreWithoutPowerReading`, `configure`, and `configureWithoutPowerReading`.
In `hardwareFailureReason(in:)`, check `engine.configuration.isActive` instead of `engine.configuration.enabled`. Thread `temperatureCelsius` to `engine.update` and coordinator status.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing WattlyTests/BatteryControlPolicyTests -only-testing WattlyTests/BatteryControlEngineTests -only-testing WattlyTests/BatteryControlCoordinatorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FanControlShared/BatteryControlPolicy.swift FanControlShared/BatteryControlEngine.swift FanControlShared/BatteryControlCoordinator.swift WattlyTests/BatteryControlPolicyTests.swift WattlyTests/BatteryControlEngineTests.swift WattlyTests/BatteryControlCoordinatorTests.swift
git commit -m "feat(battery): implement heat protection state machine, isActive handling, and policy acceptance"
```

---

### Task 3: Daemon IOKit Telemetry Ingestion & Control Service

**Files:**
- Modify: `WattlyFanDaemon/FanControlDaemon.swift`
- Modify: `FanControlShared/BatteryDaemonControlService.swift`
- Modify: `WattlyTests/BatteryDaemonControlServiceTests.swift`

**Interfaces:**
- Consumes: `IOServiceMatching("AppleSmartBattery")`, `BatteryPowerSourceReading`
- Produces: `FanControlDaemon.readPowerSourceState()` returning live `temperatureCelsius: Double?` in `BatteryPowerSourceReading`, threaded through `BatteryDaemonControlService.sample` and `configure`.

- [ ] **Step 1: Write failing tests in `BatteryDaemonControlServiceTests.swift` for temperature ingestion**

```swift
    @Test func daemonControlServicePassesTemperatureReadingToCoordinator() {
        let store = MockBatteryPolicyStore()
        let hw = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: hw)
        let coordinator = BatteryControlCoordinator(ownerUID: 501, store: store, engine: engine, now: { 1000 })
        let service = BatteryDaemonControlService(coordinator: coordinator)

        let reading = BatteryPowerSourceReading(stateOfCharge: 80, isPluggedIn: true, temperatureCelsius: 38.5)
        let status = service.sample(currentReading: reading, force: true)

        #expect(status.batteryTemperatureCelsius == 38.5)
    }
```

- [ ] **Step 2: Run test to verify it fails if not wired**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing WattlyTests/BatteryDaemonControlServiceTests`
Expected: Passes once wired.

- [ ] **Step 3: Implement temperature reading in `FanControlDaemon.swift` and `BatteryDaemonControlService.swift`**

In `WattlyFanDaemon/FanControlDaemon.swift`:
```swift
    private func readPowerSourceState() -> BatteryPowerSourceReading? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        let descriptions = list.compactMap {
            IOPSGetPowerSourceDescription(snapshot, $0)?.takeUnretainedValue() as? [String: Any]
        }
        let battery = descriptions.first { ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType }
        guard let desc = battery ?? descriptions.first else { return nil }

        let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maxCap = desc[kIOPSMaxCapacityKey] as? Int ?? 100
        let soc = maxCap > 0 ? Int((Double(current) / Double(maxCap) * 100.0).rounded()) : current
        let isPlugged = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue

        let tempC = readBatteryTemperatureFromRegistry()
        return BatteryPowerSourceReading(
            stateOfCharge: soc,
            isPluggedIn: isPlugged,
            temperatureCelsius: tempC)
    }

    private func readBatteryTemperatureFromRegistry() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let rawNumber = IORegistryEntryCreateCFProperty(service, "Temperature" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else {
            return nil
        }
        let centiCelsius = rawNumber.intValue
        guard (0...8000).contains(centiCelsius) else { return nil }
        return Double(centiCelsius) / 100.0
    }
```
In `FanControlShared/BatteryDaemonControlService.swift`:
Pass `reading.temperatureCelsius` to `coordinator.sample(currentSoC:isPluggedIn:temperatureCelsius:)`, `coordinator.configure(...)`, and `coordinator.restore(...)`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing WattlyTests/BatteryDaemonControlServiceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add WattlyFanDaemon/FanControlDaemon.swift FanControlShared/BatteryDaemonControlService.swift WattlyTests/BatteryDaemonControlServiceTests.swift
git commit -m "feat(daemon): read battery temperature from AppleSmartBattery and thread through daemon service"
```

---

### Task 4: Client, Bridge, Settings Persistence, Presentation & Status Text

**Files:**
- Modify: `Wattly/Settings/Settings.swift`
- Modify: `Wattly/Control/BatteryControlClient.swift`
- Modify: `Wattly/Views/BatteryControlBridge.swift`
- Modify: `Wattly/Core/SettingsReset.swift`
- Modify: `Wattly/Core/BatterySectionPresentation.swift`
- Modify: `Wattly/Core/BatteryStatusText.swift`
- Modify: `Wattly/Core/LegacyBatteryDetail.swift`
- Modify: `WattlyTests/BatteryStatusTextTests.swift`
- Modify: `WattlyTests/BatterySectionPresentationTests.swift`
- Modify: `WattlyTests/BatteryControlClientTests.swift`
- Modify: `WattlyTests/SettingsResetTests.swift`

**Interfaces:**
- Consumes: `Defaults`, `StorageKey`, `BatteryControlClient`, `BatteryControlBridge`, `BatterySectionPresentation`, `BatteryStatusText`
- Produces: `StorageKey.batteryHeatProtectionEnabled`, `StorageKey.batteryHeatProtectionThreshold`, `Defaults.batteryHeatProtectionEnabled`, `Defaults.batteryHeatProtectionThreshold`, `BatterySectionPresentation.heatProtectionThresholdPresets`, `BatterySectionPresentation.shouldPollStatus` taking `isFeatureActive`, localized heat protection text rendering in `BatteryStatusText`.

- [ ] **Step 1: Write failing tests for client, bridge, reset, and presentation helpers**

In `WattlyTests/BatterySectionPresentationTests.swift`:
```swift
    @Test func heatProtectionThresholdPresetsAreValid() {
        #expect(BatterySectionPresentation.heatProtectionThresholdPresets == [34, 36, 38, 40])
    }

    @Test func shouldPollStatusWhenHeatProtectionIsEnabledEvenIfLimitIsOff() {
        #expect(BatterySectionPresentation.shouldPollStatus(
            isLimitOn: false,
            isHeatProtectionOn: true,
            mode: .charging,
            isHardwareSupported: true
        ) == true)
    }

    @Test func heatProtectionStatusTextFormatting() {
        let ko = Locale(identifier: "ko")
        let en = Locale(identifier: "en")

        let activeReason = BatteryControlStatusReason(
            kind: .heatProtectionActive,
            currentTemperatureCelsius: 37.2,
            thresholdTemperatureCelsius: 36,
            resumeTemperatureCelsius: 34
        )
        #expect(BatteryStatusText.text(reason: activeReason, detail: "", locale: ko) == "발열 보호 중 (배터리 37.2°C, 34°C 도달 시 재충전)")
        #expect(BatteryStatusText.text(reason: activeReason, detail: "", locale: en) == "Heat Protection active (Battery 37.2°C, recharges at 34°C)")

        let cooldownReason = BatteryControlStatusReason(
            kind: .heatProtectionCooldown,
            currentTemperatureCelsius: 33.5,
            cooldownRemainingSeconds: 120
        )
        #expect(BatteryStatusText.text(reason: cooldownReason, detail: "", locale: ko) == "발열 보호 쿨다운 중 (120초 후 충전 재개)")
        #expect(BatteryStatusText.text(reason: cooldownReason, detail: "", locale: en) == "Heat Protection cooling down (recharging in 120s)")
    }
```

In `WattlyTests/SettingsResetTests.swift`:
```swift
    @Test func resetIncludesHeatProtectionKeys() {
        let d = makeDefaults(#function)
        d.set(true, forKey: StorageKey.batteryHeatProtectionEnabled)
        d.set(40, forKey: StorageKey.batteryHeatProtectionThreshold)

        SettingsReset.applyDefaults(into: d)

        #expect(d.bool(forKey: StorageKey.batteryHeatProtectionEnabled) == Defaults.batteryHeatProtectionEnabled)
        #expect(d.integer(forKey: StorageKey.batteryHeatProtectionThreshold) == Defaults.batteryHeatProtectionThreshold)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing WattlyTests/BatterySectionPresentationTests -only-testing WattlyTests/SettingsResetTests`
Expected: FAIL.

- [ ] **Step 3: Implement settings, client, bridge, reset, and presentation logic**

In `Wattly/Settings/Settings.swift`:
```swift
    static let batteryHeatProtectionEnabled = false
    static let batteryHeatProtectionThreshold = 36
```
and `StorageKey`:
```swift
    static let batteryHeatProtectionEnabled = "batteryHeatProtectionEnabled"
    static let batteryHeatProtectionThreshold = "batteryHeatProtectionThreshold"
```

In `Wattly/Control/BatteryControlClient.swift`:
Expand `apply`, `reconcile`, and `installAndApply` to accept `heatProtectionEnabled: Bool = false`, `heatProtectionThresholdCelsius: Int = 36`.
In `disableAndConfirm`, call `apply(enabled: false, limitPercentage: limitPercentage, lowerHysteresisDelta: lowerHysteresisDelta, heatProtectionEnabled: false, ...)`.

In `Wattly/Views/BatteryControlBridge.swift`:
Observe `batteryHeatProtectionEnabled` and `batteryHeatProtectionThreshold`.
Compute `configuration`:
```swift
    private var configuration: BatteryControlConfiguration {
        BatteryControlConfiguration(
            enabled: enabled,
            limitPercentage: limit,
            lowerHysteresisDelta: effectiveDelta,
            heatProtectionEnabled: heatProtectionEnabled,
            heatProtectionThresholdCelsius: heatProtectionThreshold)
    }
```
Update `task(id:)` with `\(enabled)-\(limit)-\(sailingEnabled)-\(sailingDelta)-\(heatProtectionEnabled)-\(heatProtectionThreshold)` and call `client.apply(configuration:)`.

In `Wattly/Core/BatterySectionPresentation.swift`:
```swift
    static let heatProtectionThresholdPresets = [34, 36, 38, 40]

    static func shouldPollStatus(
        isLimitOn: Bool,
        isHeatProtectionOn: Bool = false,
        mode: BatteryControlServiceMode,
        isHardwareSupported: Bool?
    ) -> Bool {
        if isHardwareSupported == false { return false }
        if isLimitOn || isHeatProtectionOn { return true }
        switch mode {
        case .inhibited, .unsupported: return true
        case .charging, .unavailable: return false
        }
    }
```

In `Wattly/Core/BatteryStatusText.swift`:
```swift
        case .heatProtectionActive:
            let tempStr = resolved.currentTemperatureCelsius.map { String(format: "%.1f", $0) } ?? "?"
            let resume = Int64(resolved.resumeTemperatureCelsius ?? 34)
            return String(format: String(localized: "발열 보호 중 (배터리 %@°C, %lld°C 도달 시 재충전)", locale: locale),
                          locale: locale, tempStr, resume)
        case .heatProtectionCooldown:
            let remaining = Int64(resolved.cooldownRemainingSeconds ?? 0)
            return String(format: String(localized: "발열 보호 쿨다운 중 (%lld초 후 충전 재개)", locale: locale),
                          locale: locale, remaining)
        case .batterySensorUnreadable:
            return String(localized: "배터리 온도 센서를 읽을 수 없습니다", locale: locale)
```

In `Wattly/Core/SettingsReset.swift`:
Reset `batteryHeatProtectionEnabled` and `batteryHeatProtectionThreshold`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing WattlyTests/BatterySectionPresentationTests -only-testing WattlyTests/SettingsResetTests -only-testing WattlyTests/BatteryControlClientTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Settings/Settings.swift Wattly/Control/BatteryControlClient.swift Wattly/Views/BatteryControlBridge.swift Wattly/Core/SettingsReset.swift Wattly/Core/BatterySectionPresentation.swift Wattly/Core/BatteryStatusText.swift Wattly/Core/LegacyBatteryDetail.swift WattlyTests/BatterySectionPresentationTests.swift WattlyTests/SettingsResetTests.swift WattlyTests/BatteryControlClientTests.swift
git commit -m "feat(battery): add heat protection settings, client, bridge reactivity, and status text formatting"
```

---

### Task 5: UI Integration in SettingsBatterySection & Complete Localizations

**Files:**
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift`
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Modify: `WattlyTests/SettingsBatterySectionTests.swift`
- Modify: `WattlyTests/LocalizationTests.swift`

**Interfaces:**
- Consumes: `SettingsBatterySection`, `BatteryControlClient`, `BatterySectionPresentation`, `Localizable.xcstrings`
- Produces: Complete Heat Protection UI card row with toggle (handling installer prompts), threshold segment options (34°C, 36°C, 38°C, 40°C), popover explanation, dynamic status updates, and all test suites passing.

- [ ] **Step 1: Write failing UI & localization tests**

In `WattlyTests/SettingsBatterySectionTests.swift`:
```swift
    @Test func heatProtectionPresetsMatchExpectedValues() {
        #expect(BatterySectionPresentation.heatProtectionThresholdPresets == [34, 36, 38, 40])
    }
```

In `WattlyTests/LocalizationTests.swift`:
```swift
    @Test func heatProtectionTranslationsAcrossLocales() {
        #expect(String(localized: "발열 보호 (Heat Protection)", locale: Locale(identifier: "en")) == "Heat Protection")
        #expect(String(localized: "배터리 온도가 설정값을 초과하면 충전을 일시 중단하여 배터리 수명을 보호합니다.", locale: Locale(identifier: "en")) != "")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing WattlyTests/SettingsBatterySectionTests -only-testing WattlyTests/LocalizationTests`
Expected: FAIL.

- [ ] **Step 3: Update `SettingsBatterySection.swift` and `Localizable.xcstrings`**

In `Wattly/Views/Settings/SettingsBatterySection.swift`:
Add `@AppStorage(StorageKey.batteryHeatProtectionEnabled)` and `@AppStorage(StorageKey.batteryHeatProtectionThreshold)`.
In `showsConfigurationControls`:
```swift
    Rectangle().fill(t.line).frame(height: 1)

    SettingsToggleRow(isOn: $batteryHeatProtectionEnabled,
                      divider: false,
                      isEnabled: isToggleEnabled) {
        VStack(alignment: .leading, spacing: 2) {
            SettingsRowTitle("발열 보호 (Heat Protection)")
            Text("배터리 온도가 설정값을 초과하면 충전을 일시 중단하여 배터리 수명을 보호합니다.")
                .font(WattlyFont.at(10.5, weight: .regular))
                .foregroundStyle(t.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    if batteryHeatProtectionEnabled {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("보호 시작 온도")
                    .font(WattlyFont.at(12, weight: .medium))
                    .foregroundStyle(t.text)
                Spacer()
                Text(String(format: String(localized: "%lld°C 초과 시 정지, %lld°C 이하 시 재개", locale: locale),
                            locale: locale, Int64(batteryHeatProtectionThreshold), Int64(batteryHeatProtectionThreshold - 2)))
                    .font(WattlyFont.at(10.5, weight: .medium))
                    .foregroundStyle(t.sub)
            }

            WattlySegment(
                selection: $batteryHeatProtectionThreshold,
                options: BatterySectionPresentation.heatProtectionThresholdPresets.map { ($0, "\($0)°C") },
                pillVPadding: 6,
                isEnabled: true
            )
        }
        .padding(EdgeInsets(top: 0, leading: 14, bottom: 14, trailing: 14))
    }
```
Connect `.onChange(of: batteryHeatProtectionEnabled)` with helper installation check:
```swift
    .onChange(of: batteryHeatProtectionEnabled) { _, isEnabled in
        guard isEnabled, !batteryControl.isInstallingHelper else {
            Task {
                await batteryControl.apply(
                    enabled: batteryLimitEnabled,
                    limitPercentage: batteryLimitPercentage,
                    lowerHysteresisDelta: effectiveDelta,
                    heatProtectionEnabled: isEnabled,
                    heatProtectionThresholdCelsius: batteryHeatProtectionThreshold)
            }
            return
        }
        let window = NSApp.keyWindow
        Task {
            let mode = await batteryControl.refreshStatus()?.mode ?? .unavailable
            if BatteryControlPolicy.shouldRunInstaller(mode: mode) {
                if let failure = await batteryControl.installAndApply(
                    enabled: batteryLimitEnabled,
                    limitPercentage: batteryLimitPercentage,
                    lowerHysteresisDelta: effectiveDelta,
                    heatProtectionEnabled: true,
                    heatProtectionThresholdCelsius: batteryHeatProtectionThreshold,
                    window: window) {
                    installErrorMessage = Self.message(for: failure, locale: locale)
                    isInstallFailedAlertPresented = true
                    batteryHeatProtectionEnabled = false
                }
            } else {
                await batteryControl.apply(
                    enabled: batteryLimitEnabled,
                    limitPercentage: batteryLimitPercentage,
                    lowerHysteresisDelta: effectiveDelta,
                    heatProtectionEnabled: true,
                    heatProtectionThresholdCelsius: batteryHeatProtectionThreshold)
            }
        }
    }
```
Connect `.onChange(of: batteryHeatProtectionThreshold)` to push to `batteryControl.apply`.
Update view lifecycle task and status indicator to pass `isHeatProtectionOn: batteryHeatProtectionEnabled` to `BatterySectionPresentation.shouldPollStatus`.

In `Wattly/Resources/Localizable.xcstrings`:
Add localizations across supported languages for:
- `"발열 보호 (Heat Protection)"`
- `"배터리 온도가 설정값을 초과하면 충전을 일시 중단하여 배터리 수명을 보호합니다."`
- `"보호 시작 온도"`
- `"%lld°C 초과 시 정지, %lld°C 이하 시 재개"`
- `"발열 보호 중 (배터리 %@°C, %lld°C 도달 시 재충전)"`
- `"발열 보호 쿨다운 중 (%lld초 후 충전 재개)"`
- `"배터리 온도 센서를 읽을 수 없습니다"`

- [ ] **Step 4: Run the full test suite and build**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData`
Expected: ALL test suites PASS.

Run: `xcodebuild build -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Views/Settings/SettingsBatterySection.swift Wattly/Resources/Localizable.xcstrings WattlyTests/SettingsBatterySectionTests.swift WattlyTests/LocalizationTests.swift
git commit -m "feat(settings): integrate heat protection controls and complete localizations"
```

---

## Self-Review Checklist
1. **Spec Coverage**: All items in `05-heat-protection.md` covered (toggle, threshold, inhibit on threshold, dual cooldown & hysteresis exit condition, current temp & reason display, fail-closed unreadable sensor status, prioritization over charge limit).
2. **No Placeholders**: Every step has complete file paths, exact code blocks, concrete test cases, and git commit commands.
3. **Type Consistency**: `heatProtectionEnabled`, `heatProtectionThresholdCelsius`, `heatProtectionResumeDeltaCelsius`, `heatProtectionMinCooldownSeconds`, `isActive`, `BatteryPowerSourceReading(stateOfCharge:isPluggedIn:temperatureCelsius:)`, and `BatteryControlStatusReason.Kind` cases are uniformly named across all tasks.
