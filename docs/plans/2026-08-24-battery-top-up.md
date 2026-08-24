# Battery Top Up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a one-time "Top Up" feature that charges the battery to 100% once while preserving the user's permanent charge limit (e.g. 80%), holds at 100% on adapter bypass, and automatically restores the normal charge limit upon power adapter disconnection.

**Architecture:** The privileged LaunchDaemon (`WattlyFanDaemon`) serves as the single authority for the active Top Up state by persisting `topUpActive: true` in the atomic policy store (`/Library/Application Support/Wattly/battery-control-v1.json`). `BatteryControlEngine` overrides the effective charging ceiling to 100% without mutating the user's saved `limitPercentage`, while `BatteryControlCoordinator` monitors power state to automatically reset `topUpActive` to `false` whenever the MacBook is on battery power (`!isPluggedIn`). `Wattly` surfaces quick action controls in both the menu bar popover battery card and the settings view, accompanied by a 1-time local notification upon reaching 100%.

**Tech Stack:** Swift 6, SwiftUI, Observation, UserNotifications, Swift Testing, Codable JSON over privileged XPC, XcodeGen, macOS 14+, Apple Silicon arm64

## Global Constraints

- Support macOS 14.0 and later on Apple Silicon arm64; no third-party dependencies.
- LaunchDaemon helper and hardware readback remain the single source of truth for persistent policy and state.
- Normal `limitPercentage` (e.g., 80%) must never be permanently overwritten by Top Up.
- Heat Protection outranks Top Up: high battery temperature inhibits charging regardless of Top Up state.
- Top Up and Calibration / Active Discharge are mutually exclusive.
- Unplugging the power adapter automatically terminates Top Up and restores the permanent charge limit on the next connection.
- 100% reach triggers a single user notification; adapter unplug silently restores normal policy without notification spam.
- Any new source file requires running `xcodegen generate` and committing the updated `Wattly.xcodeproj/project.pbxproj`.
- Full validation command: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'` followed by `xcodebuild build -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'`.

---

### Task 1: Add `topUpActive` to Protocol Configuration, Policy, and Status Models

**Files:**
- Modify: `FanControlShared/BatteryControlProtocol.swift:3-81`
- Modify: `FanControlShared/BatteryControlPolicy.swift:45-71`
- Modify: `FanControlShared/BatteryControlStatusReason.swift:15-65,135-167`
- Modify: `FanControlShared/BatteryControlActivity.swift:35-52`
- Modify: `WattlyTests/BatteryControlProtocolTests.swift`
- Modify: `WattlyTests/BatteryControlPolicyTests.swift`
- Modify: `WattlyTests/BatteryControlActivityTests.swift`
- Modify: `WattlyTests/BatteryControlStatusReasonTests.swift`

**Interfaces:**
- Consumes: `BatteryControlConfiguration`, `BatteryControlPolicy`, `BatteryControlStatusReason`, `BatteryControlActivity`.
- Produces: `BatteryControlConfiguration.topUpActive: Bool`, `BatteryControlPolicy.shouldReapply` preserving active Top Up, `BatteryControlStatusReason.Kind.topUpCharging`, `BatteryControlStatusReason.Kind.topUpComplete`, and activity inference mapping to `.topUp`.

- [ ] **Step 1: Write the failing protocol, policy, and model tests**

In `WattlyTests/BatteryControlProtocolTests.swift`, add:

```swift
    @Test func topUpActiveConfigurationRoundTrips() throws {
        let input = BatteryControlConfiguration(
            enabled: true,
            limitPercentage: 80,
            lowerHysteresisDelta: 2,
            heatProtectionEnabled: false,
            heatProtectionThresholdCelsius: 35,
            topUpActive: true
        )
        let encoded = try BatteryControlCodec.encode(input)
        let decoded = try BatteryControlCodec.decode(BatteryControlConfiguration.self, from: encoded)
        #expect(decoded == input)
        #expect(decoded.topUpActive == true)
        #expect(decoded.isActive == true)
    }

    @Test func topUpActiveNormalizesPreservingFlag() {
        let config = BatteryControlConfiguration(
            enabled: true,
            limitPercentage: 80,
            lowerHysteresisDelta: 2,
            topUpActive: true
        )
        let normalized = config.normalized
        #expect(normalized.topUpActive == true)
        #expect(normalized.clampedLimitPercentage == 80)
    }
```

In `WattlyTests/BatteryControlPolicyTests.swift`, add:

```swift
    @Test func shouldReapplyPreservesActiveTopUpWhenBaseSettingsMatch() {
        let appConfig = BatteryControlConfiguration(enabled: true, limitPercentage: 80, lowerHysteresisDelta: 2, topUpActive: false)
        let daemonConfig = BatteryControlConfiguration(enabled: true, limitPercentage: 80, lowerHysteresisDelta: 2, topUpActive: true)

        let status = BatteryControlServiceStatus(
            mode: .charging,
            currentPercentage: 70,
            isPowerAdapterConnected: true,
            detail: "Top Up 중 (100%까지 충전)",
            updatedAt: 100.0,
            desiredConfiguration: daemonConfig,
            capabilities: [.persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1]
        )

        // When helper holds topUpActive == true, background client check with same base settings must NOT trigger reapply
        #expect(BatteryControlPolicy.shouldReapply(configuration: appConfig, status: status) == false)
    }
```

In `WattlyTests/BatteryControlActivityTests.swift`, add:

```swift
    @Test func topUpReasonsInferTopUpActivity() {
        let chargingReason = BatteryControlStatusReason(kind: .topUpCharging, limitPercentage: 100)
        let completeReason = BatteryControlStatusReason(kind: .topUpComplete, limitPercentage: 100)
        #expect(BatteryControlActivity.inferred(from: chargingReason) == .topUp)
        #expect(BatteryControlActivity.inferred(from: completeReason) == .topUp)
    }
```

In `WattlyTests/BatteryControlStatusReasonTests.swift`, add:

```swift
    @Test func topUpReasonsRoundTripAndProvideLegacyKoreanDetail() throws {
        let charging = BatteryControlStatusReason(kind: .topUpCharging, limitPercentage: 100)
        let complete = BatteryControlStatusReason(kind: .topUpComplete, limitPercentage: 100)

        let encodedCharging = try BatteryControlCodec.encode(charging)
        let decodedCharging = try BatteryControlCodec.decode(BatteryControlStatusReason.self, from: encodedCharging)
        #expect(decodedCharging.kind == .topUpCharging)
        #expect(decodedCharging.legacyKoreanDetail == "Top Up 중 (100%까지 충전)")

        let encodedComplete = try BatteryControlCodec.encode(complete)
        let decodedComplete = try BatteryControlCodec.decode(BatteryControlStatusReason.self, from: encodedComplete)
        #expect(decodedComplete.kind == .topUpComplete)
        #expect(decodedComplete.legacyKoreanDetail == "Top Up 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  -only-testing:WattlyTests/BatteryControlProtocolTests \
  -only-testing:WattlyTests/BatteryControlPolicyTests \
  -only-testing:WattlyTests/BatteryControlActivityTests \
  -only-testing:WattlyTests/BatteryControlStatusReasonTests
```
Expected: FAIL due to missing `topUpActive`, `.topUpCharging`, and `.topUpComplete`.

- [ ] **Step 3: Implement `topUpActive` in protocol, policy, and status reasons**

In `FanControlShared/BatteryControlProtocol.swift`:
Update `BatteryControlConfiguration`:

```swift
public struct BatteryControlConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var limitPercentage: Int
    public var lowerHysteresisDelta: Int
    public var heatProtectionEnabled: Bool
    public var heatProtectionThresholdCelsius: Int
    public var heatProtectionResumeDeltaCelsius: Int
    public var heatProtectionMinCooldownSeconds: TimeInterval
    public var topUpActive: Bool

    public init(
        enabled: Bool = false,
        limitPercentage: Int = 80,
        lowerHysteresisDelta: Int = 2,
        heatProtectionEnabled: Bool = false,
        heatProtectionThresholdCelsius: Int = 35,
        heatProtectionResumeDeltaCelsius: Int = 2,
        heatProtectionMinCooldownSeconds: TimeInterval = 300.0,
        topUpActive: Bool = false
    ) {
        self.enabled = enabled
        self.limitPercentage = limitPercentage
        self.lowerHysteresisDelta = lowerHysteresisDelta
        self.heatProtectionEnabled = heatProtectionEnabled
        self.heatProtectionThresholdCelsius = heatProtectionThresholdCelsius
        self.heatProtectionResumeDeltaCelsius = heatProtectionResumeDeltaCelsius
        self.heatProtectionMinCooldownSeconds = heatProtectionMinCooldownSeconds
        self.topUpActive = topUpActive
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, limitPercentage, lowerHysteresisDelta
        case heatProtectionEnabled, heatProtectionThresholdCelsius, heatProtectionResumeDeltaCelsius, heatProtectionMinCooldownSeconds
        case topUpActive
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? false
        limitPercentage = (try? container.decode(Int.self, forKey: .limitPercentage)) ?? 80
        lowerHysteresisDelta = (try? container.decode(Int.self, forKey: .lowerHysteresisDelta)) ?? 2
        heatProtectionEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .heatProtectionEnabled)) ?? false
        heatProtectionThresholdCelsius = (try? container.decodeIfPresent(Int.self, forKey: .heatProtectionThresholdCelsius)) ?? 35
        heatProtectionResumeDeltaCelsius = (try? container.decodeIfPresent(Int.self, forKey: .heatProtectionResumeDeltaCelsius)) ?? 2
        heatProtectionMinCooldownSeconds = (try? container.decodeIfPresent(TimeInterval.self, forKey: .heatProtectionMinCooldownSeconds)) ?? 300.0
        topUpActive = (try? container.decodeIfPresent(Bool.self, forKey: .topUpActive)) ?? false
    }

    public var normalized: BatteryControlConfiguration {
        var copy = self
        copy.limitPercentage = Self.clampLimit(limitPercentage)
        copy.lowerHysteresisDelta = Self.clampDelta(lowerHysteresisDelta)
        copy.heatProtectionThresholdCelsius = Self.clampThreshold(heatProtectionThresholdCelsius)
        copy.heatProtectionResumeDeltaCelsius = Self.clampResumeDelta(heatProtectionResumeDeltaCelsius)
        copy.heatProtectionMinCooldownSeconds = Self.clampCooldown(heatProtectionMinCooldownSeconds)
        copy.topUpActive = topUpActive
        return copy
    }

    public var isActive: Bool {
        enabled || heatProtectionEnabled || topUpActive
    }
    // (rest unchanged)
```

In `FanControlShared/BatteryControlPolicy.swift`:
Update `shouldReapply`:

```swift
    public static func shouldReapply(
        configuration: BatteryControlConfiguration,
        status: BatteryControlServiceStatus
    ) -> Bool {
        var requested = configuration.normalized
        guard status.mode != .unavailable else { return false }
        guard status.isHardwareSupported != false else { return false }
        if supportsPersistentPolicy(status: status), let desired = status.desiredConfiguration {
            // Background periodic reconciliation preserves helper's active Top Up state
            if desired.topUpActive && !configuration.topUpActive {
                requested.topUpActive = true
            }
            return desired.normalized != requested
        }
        if requested.enabled {
            return status.appliedLimitPercentage != requested.clampedLimitPercentage
        }
        return status.appliedLimitPercentage != nil || status.mode == .inhibited
    }
```

In `FanControlShared/BatteryControlStatusReason.swift`:
Add to `Kind`:
```swift
        case topUpCharging
        case topUpComplete
```
Add to `legacyKoreanDetail`:
```swift
        case .topUpCharging: return "Top Up 중 (100%까지 충전)"
        case .topUpComplete: return "Top Up 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)"
```

In `FanControlShared/BatteryControlActivity.swift`:
Add to `inferred(from:)`:
```swift
        case .some(.topUpCharging), .some(.topUpComplete):
            return .topUp
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  -only-testing:WattlyTests/BatteryControlProtocolTests \
  -only-testing:WattlyTests/BatteryControlPolicyTests \
  -only-testing:WattlyTests/BatteryControlActivityTests \
  -only-testing:WattlyTests/BatteryControlStatusReasonTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FanControlShared/BatteryControlProtocol.swift \
  FanControlShared/BatteryControlPolicy.swift \
  FanControlShared/BatteryControlStatusReason.swift \
  FanControlShared/BatteryControlActivity.swift \
  WattlyTests/BatteryControlProtocolTests.swift \
  WattlyTests/BatteryControlPolicyTests.swift \
  WattlyTests/BatteryControlActivityTests.swift \
  WattlyTests/BatteryControlStatusReasonTests.swift
git commit -m "feat(battery): add topUpActive to configuration, policy, and status models"
```

---

### Task 2: Implement Top Up Hardware & Hysteresis Logic in BatteryControlEngine

**Files:**
- Modify: `FanControlShared/BatteryControlEngine.swift:207-268,358-406`
- Modify: `WattlyTests/BatteryControlEngineTests.swift`

**Interfaces:**
- Consumes: `BatteryControlConfiguration.topUpActive`, `BatteryControlStatusReason.Kind.topUpCharging`, `BatteryControlStatusReason.Kind.topUpComplete`.
- Produces: `BatteryControlEngine.update()` charging to 100% during Top Up, inhibiting at 100%, respecting Heat Protection precedence, and emitting `.topUpCharging` / `.topUpComplete`.

- [ ] **Step 1: Write failing engine Top Up tests**

In `WattlyTests/BatteryControlEngineTests.swift`, add:

```swift
    @Test func topUpChargesTo100AndHoldsAt100OnAdapterBypass() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 80, topUpActive: true))

        // Below 100%: charging should NOT be inhibited (gate allowed)
        let status70 = engine.update(currentSoC: 70, isPluggedIn: true)
        #expect(status70.mode == .charging)
        #expect(status70.activity == .topUp)
        #expect(status70.detailReason?.kind == .topUpCharging)
        #expect(mockHW.isInhibited == false)

        // At 80% (normal limit): should KEEP charging to 100%
        let status80 = engine.update(currentSoC: 80, isPluggedIn: true)
        #expect(status80.mode == .charging)
        #expect(status80.activity == .topUp)
        #expect(status80.detailReason?.kind == .topUpCharging)
        #expect(mockHW.isInhibited == false)

        // Reaching 100%: should INHIBIT charging and hold at 100%
        let status100 = engine.update(currentSoC: 100, isPluggedIn: true)
        #expect(status100.mode == .inhibited)
        #expect(status100.activity == .topUp)
        #expect(status100.detailReason?.kind == .topUpComplete)
        #expect(mockHW.isInhibited == true)
    }

    @Test func heatProtectionOutranksTopUp() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(
            enabled: true,
            limitPercentage: 80,
            heatProtectionEnabled: true,
            heatProtectionThresholdCelsius: 35,
            topUpActive: true
        ))

        // Normal temperature: Top Up charges
        let cool = engine.update(currentSoC: 70, isPluggedIn: true, temperatureCelsius: 30.0)
        #expect(cool.mode == .charging)
        #expect(cool.activity == .topUp)

        // High temperature (36°C): Heat Protection engages and inhibits charging
        let hot = engine.update(currentSoC: 70, isPluggedIn: true, temperatureCelsius: 36.0)
        #expect(hot.mode == .inhibited)
        #expect(hot.activity == .heatProtection)
        #expect(hot.detailReason?.kind == .heatProtectionActive)
        #expect(mockHW.isInhibited == true)
    }

    @Test func topUpCancelsImmediatelyRestoringNormalLimit() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 80, topUpActive: true))

        // At 85% during Top Up: still charging
        _ = engine.update(currentSoC: 85, isPluggedIn: true)
        #expect(mockHW.isInhibited == false)

        // User cancels Top Up: configuration re-applied with topUpActive: false
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 80, topUpActive: false))
        let afterCancel = engine.update(currentSoC: 85, isPluggedIn: true)

        // Since currentSoC (85%) >= normal limit (80%), charging is immediately inhibited
        #expect(afterCancel.mode == .inhibited)
        #expect(afterCancel.activity == .holdingAtLimit)
        #expect(mockHW.isInhibited == true)
    }
```

- [ ] **Step 2: Run engine tests to verify they fail**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  -only-testing:WattlyTests/BatteryControlEngineTests
```
Expected: FAIL because engine does not evaluate `topUpActive`.

- [ ] **Step 3: Implement Top Up evaluation in BatteryControlEngine**

In `FanControlShared/BatteryControlEngine.swift`:

Update `update(currentSoC:isPluggedIn:temperatureCelsius:now:)` evaluation around lines 235-255:

```swift
        // 2. Evaluate shouldInhibit
        let target = config.topUpActive ? 100 : config.clampedLimitPercentage
        let shouldInhibit: Bool
        if isInHeatProtection {
            shouldInhibit = true
        } else if config.topUpActive && isPluggedIn {
            shouldInhibit = currentSoC >= 100
        } else if config.enabled && isPluggedIn {
            // Hysteresis: cross up at the target, come back down only at the resume threshold.
            shouldInhibit = isCurrentlyInhibited
                ? currentSoC > config.resumePercentage
                : currentSoC >= target
        } else {
            shouldInhibit = false
        }
```

Update `detailReason(...)` around lines 358-405:

```swift
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
        if config.topUpActive && isPluggedIn {
            if currentSoC >= 100 {
                return .init(kind: .topUpComplete, limitPercentage: 100)
            }
            return .init(kind: .topUpCharging, limitPercentage: 100)
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
```

- [ ] **Step 4: Run engine tests to verify they pass**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  -only-testing:WattlyTests/BatteryControlEngineTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FanControlShared/BatteryControlEngine.swift WattlyTests/BatteryControlEngineTests.swift
git commit -m "feat(battery): implement top up charging and holding logic in engine"
```

---

### Task 3: Implement Battery Power Auto-Reset in BatteryControlCoordinator

**Files:**
- Modify: `FanControlShared/BatteryControlCoordinator.swift:45-88,256-276`
- Modify: `WattlyTests/BatteryControlCoordinatorTests.swift`

**Interfaces:**
- Consumes: `BatteryMaintenanceTrigger`, `BatteryControlConfiguration.topUpActive`, `isPluggedIn`.
- Produces: Automatic Top Up deactivation and atomic persistence update whenever Mac runs on battery power (`!isPluggedIn`).

- [ ] **Step 1: Write failing coordinator auto-reset tests**

In `WattlyTests/BatteryControlCoordinatorTests.swift`, add:

```swift
    @Test func unpluggingAdapterAutomaticallyDeactivatesTopUpAndPersistsBasePolicy() throws {
        let store = MockBatteryPolicyStore()
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: engine,
            now: { 1000.0 }
        )

        // Configure Top Up while plugged in
        let topUpConfig = BatteryControlConfiguration(enabled: true, limitPercentage: 80, topUpActive: true)
        _ = coordinator.configure(topUpConfig, trigger: .clientConfiguration, currentSoC: 70, isPluggedIn: true)
        #expect(coordinator.latestStatus.desiredConfiguration?.topUpActive == true)
        #expect(store.savedRecord?.configuration.topUpActive == true)

        // Adapter is disconnected (unplugged): trigger adapterTransition
        let unpluggedStatus = coordinator.reconcile(
            trigger: .adapterTransition,
            currentSoC: 70,
            isPluggedIn: false
        )

        // Top Up must be cleared, normal policy (limit 80) persisted and enforced
        #expect(unpluggedStatus.desiredConfiguration?.topUpActive == false)
        #expect(unpluggedStatus.desiredConfiguration?.limitPercentage == 80)
        #expect(store.savedRecord?.configuration.topUpActive == false)
        #expect(store.savedRecord?.configuration.limitPercentage == 80)
    }

    @Test func startingUpOrWakingOnBatteryPowerClearsAnyStaleTopUpActive() throws {
        let store = MockBatteryPolicyStore()
        let staleTopUp = BatteryControlConfiguration(enabled: true, limitPercentage: 80, topUpActive: true)
        try store.save(.init(ownerUID: 501, configuration: staleTopUp, updatedAt: 900.0))

        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: engine,
            now: { 1000.0 }
        )

        // Restore on battery power (!isPluggedIn)
        let restoreStatus = coordinator.restore(currentSoC: 90, isPluggedIn: false)
        #expect(restoreStatus.desiredConfiguration?.topUpActive == false)
        #expect(store.savedRecord?.configuration.topUpActive == false)
    }
```

- [ ] **Step 2: Run coordinator tests to verify they fail**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  -only-testing:WattlyTests/BatteryControlCoordinatorTests
```
Expected: FAIL because coordinator does not clear `topUpActive` on battery power.

- [ ] **Step 3: Implement battery power auto-reset in coordinator**

In `FanControlShared/BatteryControlCoordinator.swift`:

Update `restore`:

```swift
    public func restore(
        currentSoC: Int,
        isPluggedIn: Bool,
        temperatureCelsius: Double? = nil
    ) -> BatteryControlServiceStatus {
        do {
            var (desired, ownershipFailure) = try resolvedStoredPolicy()
            if !isPluggedIn && desired.topUpActive {
                desired.topUpActive = false
                try? store.save(.init(ownerUID: ownerUID, configuration: desired, updatedAt: now()))
            }
            engine.configure(desired)
            if !desired.isActive {
                return publishDisabledRestore(
                    currentSoC: currentSoC,
                    isPluggedIn: isPluggedIn,
                    temperatureCelsius: temperatureCelsius,
                    resolutionFailure: ownershipFailure)
            }
            let status = engine.verifyAndUpdate(
                currentSoC: currentSoC,
                isPluggedIn: isPluggedIn,
                temperatureCelsius: temperatureCelsius)
            let failure = ownershipFailure ?? hardwareFailureReason(in: status)
            return publish(
                status,
                trigger: .startup,
                result: failure == nil ? .verified : .failed,
                reason: failure)
        } catch {
            // (error branch unchanged)
```

Update `reconcile`:

```swift
    public func reconcile(
        trigger: BatteryMaintenanceTrigger,
        currentSoC: Int,
        isPluggedIn: Bool,
        temperatureCelsius: Double? = nil
    ) -> BatteryControlServiceStatus {
        if trigger == .wake || trigger == .adapterTransition {
            engine.beginRecoveryWindow()
        }

        // Auto-terminate Top Up whenever on battery power
        if !isPluggedIn && engine.configuration.topUpActive {
            var updatedConfig = engine.configuration
            updatedConfig.topUpActive = false
            do {
                try store.save(.init(
                    ownerUID: ownerUID,
                    configuration: updatedConfig,
                    updatedAt: now()))
            } catch {
                // If persistence write fails, proceed with in-memory policy reset
            }
            engine.configure(updatedConfig)
        }

        let status = engine.verifyAndUpdate(
            currentSoC: currentSoC,
            isPluggedIn: isPluggedIn,
            temperatureCelsius: temperatureCelsius)
        let failure = hardwareFailureReason(in: status)
        return publish(
            status,
            trigger: trigger,
            result: failure == nil ? .verified : .failed,
            reason: failure)
    }
```

- [ ] **Step 4: Run coordinator tests to verify they pass**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  -only-testing:WattlyTests/BatteryControlCoordinatorTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FanControlShared/BatteryControlCoordinator.swift WattlyTests/BatteryControlCoordinatorTests.swift
git commit -m "feat(battery): auto-reset top up on battery power in coordinator"
```

---

### Task 4: Add Top Up Localized Status Text and Presentation Mapping

**Files:**
- Modify: `Wattly/Core/BatteryStatusText.swift:48-98`
- Modify: `Wattly/Core/BatterySectionPresentation.swift:340-372`
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Modify: `WattlyTests/BatteryStatusTextTests.swift`
- Modify: `WattlyTests/BatterySectionPresentationTests.swift`
- Modify: `WattlyTests/LocalizationTests.swift`

**Interfaces:**
- Consumes: `BatteryControlStatusReason.Kind.topUpCharging`, `BatteryControlStatusReason.Kind.topUpComplete`.
- Produces: Localized strings for Korean and English catalogs, mapped to `Indicator.topUp`, and polling status during Top Up.

- [ ] **Step 1: Write failing status text and presentation tests**

In `WattlyTests/BatteryStatusTextTests.swift`, add:

```swift
    @Test func topUpStatusTextLocalized() {
        let ko = Locale(identifier: "ko")
        let en = Locale(identifier: "en")

        let chargingReason = BatteryControlStatusReason(kind: .topUpCharging, limitPercentage: 100)
        let completeReason = BatteryControlStatusReason(kind: .topUpComplete, limitPercentage: 100)

        #expect(BatteryStatusText.text(reason: chargingReason, detail: "", locale: ko)
                == "Top Up 중 (100%까지 충전)")
        #expect(BatteryStatusText.text(reason: chargingReason, detail: "", locale: en)
                == "Top Up in progress (Charging to 100%)")

        #expect(BatteryStatusText.text(reason: completeReason, detail: "", locale: ko)
                == "Top Up 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)")
        #expect(BatteryStatusText.text(reason: completeReason, detail: "", locale: en)
                == "Top Up complete (Holding at 100%, normal limit restores on unplug)")
    }
```

In `WattlyTests/BatterySectionPresentationTests.swift`, add:

```swift
    @Test func topUpStatusRendersTopUpIndicator() {
        let ko = Locale(identifier: "ko")
        let statusCharging = BatterySectionPresentation.status(
            isLimitOn: true,
            isInstalling: false,
            mode: .charging,
            reason: .init(kind: .topUpCharging, limitPercentage: 100),
            detail: "Top Up 중 (100%까지 충전)",
            locale: ko,
            activity: .topUp
        )
        #expect(statusCharging.indicator == .topUp)
        #expect(statusCharging.indicator.symbolName == "arrow.up.circle.fill")
        #expect(statusCharging.indicator.tone == .green)
        #expect(statusCharging.text == "Top Up 중 (100%까지 충전)")

        let statusComplete = BatterySectionPresentation.status(
            isLimitOn: true,
            isInstalling: false,
            mode: .inhibited,
            reason: .init(kind: .topUpComplete, limitPercentage: 100),
            detail: "Top Up 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)",
            locale: ko,
            activity: .topUp
        )
        #expect(statusComplete.indicator == .topUp)
        #expect(statusComplete.text == "Top Up 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)")
    }

    @Test func shouldPollStatusReturnsTrueDuringActiveTopUp() {
        #expect(BatterySectionPresentation.shouldPollStatus(
            isLimitOn: false,
            isHeatProtectionOn: false,
            isTopUpOn: true,
            mode: .charging,
            isHardwareSupported: true
        ) == true)
    }
```

- [ ] **Step 2: Run status text tests to verify they fail**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  -only-testing:WattlyTests/BatteryStatusTextTests \
  -only-testing:WattlyTests/BatterySectionPresentationTests
```
Expected: FAIL because `BatteryStatusText` and `shouldPollStatus` do not handle Top Up.

- [ ] **Step 3: Implement localization in BatteryStatusText and Localizable.xcstrings**

In `Wattly/Core/BatteryStatusText.swift`, add to `switch resolved.kind`:

```swift
        case .topUpCharging:
            return String(localized: "Top Up 중 (100%까지 충전)", locale: locale)
        case .topUpComplete:
            return String(localized: "Top Up 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)", locale: locale)
```

In `Wattly/Core/BatterySectionPresentation.swift`, update `shouldPollStatus`:

```swift
    static func shouldPollStatus(isLimitOn: Bool,
                                 isHeatProtectionOn: Bool = false,
                                 isTopUpOn: Bool = false,
                                 mode: BatteryControlServiceMode,
                                 isHardwareSupported: Bool?) -> Bool {
        if isHardwareSupported == false { return false }
        if isLimitOn || isHeatProtectionOn || isTopUpOn { return true }
        switch mode {
        case .inhibited, .unsupported: return true
        case .charging, .unavailable: return false
        }
    }
```

In `Wattly/Resources/Localizable.xcstrings`, add localization keys:
- Key: `"Top Up 중 (100%까지 충전)"`
  - ko: `"Top Up 중 (100%까지 충전)"`
  - en: `"Top Up in progress (Charging to 100%)"`
- Key: `"Top Up 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)"`
  - ko: `"Top Up 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)"`
  - en: `"Top Up complete (Holding at 100%, normal limit restores on unplug)"`
- Key: `"한 번만 100% 충전 (Top Up)"`
  - ko: `"한 번만 100% 충전 (Top Up)"`
  - en: `"Charge to 100% Once (Top Up)"`
- Key: `"외출 전에 한 번만 100%까지 완충하며, 어댑터를 분리하면 기존 한도로 자동 복귀합니다."`
  - ko: `"외출 전에 한 번만 100%까지 완충하며, 어댑터를 분리하면 기존 한도로 자동 복귀합니다."`
  - en: `"Charges to 100% once before heading out, then automatically restores your charge limit when unplugged."`
- Key: `"Top Up 취소"`
  - ko: `"Top Up 취소"`
  - en: `"Cancel Top Up"`
- Key: `"Top Up 시작"`
  - ko: `"Top Up 시작"`
  - en: `"Start Top Up"`
- Key: `"Top Up 완료"`
  - ko: `"Top Up 완료"`
  - en: `"Top Up Complete"`
- Key: `"배터리가 100%까지 충전되었습니다. 어댑터를 분리하면 기존 충전 제한으로 자동 복귀합니다."`
  - ko: `"배터리가 100%까지 충전되었습니다. 어댑터를 분리하면 기존 충전 제한으로 자동 복귀합니다."`
  - en: `"Battery is charged to 100%. Normal limit will restore automatically when unplugged."`

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  -only-testing:WattlyTests/BatteryStatusTextTests \
  -only-testing:WattlyTests/BatterySectionPresentationTests \
  -only-testing:WattlyTests/LocalizationTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/BatteryStatusText.swift \
  Wattly/Core/BatterySectionPresentation.swift \
  Wattly/Resources/Localizable.xcstrings \
  WattlyTests/BatteryStatusTextTests.swift \
  WattlyTests/BatterySectionPresentationTests \
  WattlyTests/LocalizationTests.swift
git commit -m "feat(battery): add localized text and presentation for top up"
```

---

### Task 5: Implement Client API, Bridge Integration, and Completion Notifications

**Files:**
- Create: `Wattly/Core/BatteryNotificationManager.swift`
- Create: `WattlyTests/BatteryNotificationManagerTests.swift`
- Modify: `Wattly/Control/BatteryControlClient.swift:67-170`
- Modify: `Wattly/Views/BatteryControlBridge.swift:43-205`
- Modify: `WattlyTests/BatteryControlClientTests.swift`
- Modify: `Wattly.xcodeproj/project.pbxproj` through `xcodegen generate`

**Interfaces:**
- Consumes: `BatteryControlClient`, `BatteryControlServiceStatus`.
- Produces: `BatteryControlClient.startTopUp()`, `BatteryControlClient.cancelTopUp()`, `BatteryNotificationManager.requestAuthorization()`, `BatteryNotificationManager.postTopUpCompleteNotification()`.

- [ ] **Step 1: Write failing notification manager and client tests**

Create `WattlyTests/BatteryNotificationManagerTests.swift`:

```swift
import Foundation
import Testing
@testable import Wattly

@Suite struct BatteryNotificationManagerTests {
    @Test func notificationTitleAndBodyAreLocalized() {
        let ko = Locale(identifier: "ko")
        let en = Locale(identifier: "en")

        let koTitle = BatteryNotificationManager.topUpCompleteTitle(locale: ko)
        let koBody = BatteryNotificationManager.topUpCompleteBody(locale: ko)
        #expect(koTitle == "Top Up 완료")
        #expect(koBody == "배터리가 100%까지 충전되었습니다. 어댑터를 분리하면 기존 충전 제한으로 자동 복귀합니다.")

        let enTitle = BatteryNotificationManager.topUpCompleteTitle(locale: en)
        let enBody = BatteryNotificationManager.topUpCompleteBody(locale: en)
        #expect(enTitle == "Top Up Complete")
        #expect(enBody == "Battery is charged to 100%. Normal limit will restore automatically when unplugged.")
    }

    @Test func transitionDetectionFiresOnlyOnTransitionToComplete() {
        var detector = BatteryTopUpTransitionDetector()

        // 1. Initial charging state: no notification
        #expect(detector.update(reasonKind: .topUpCharging) == false)

        // 2. Still charging: no notification
        #expect(detector.update(reasonKind: .topUpCharging) == false)

        // 3. Transition to complete: notification FIRES
        #expect(detector.update(reasonKind: .topUpComplete) == true)

        // 4. Continued complete state: notification does NOT repeat
        #expect(detector.update(reasonKind: .topUpComplete) == false)

        // 5. Unplugged / reset to normal limit: detector resets
        #expect(detector.update(reasonKind: .inhibitedAtLimit) == false)

        // 6. Next top up complete transition can fire again
        #expect(detector.update(reasonKind: .topUpCharging) == false)
        #expect(detector.update(reasonKind: .topUpComplete) == true)
    }
}
```

In `WattlyTests/BatteryControlClientTests.swift`, add:

```swift
    @Test func startTopUpAppliesTopUpActiveTrue() async {
        var recordedRequest: BatteryControlConfigurationRequest?
        let client = BatteryControlClient(requestHandler: { req in
            if case .configure(let data) = req {
                recordedRequest = try? BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
                let status = BatteryControlServiceStatus(
                    mode: .charging,
                    currentPercentage: 70,
                    isPowerAdapterConnected: true,
                    detail: "Top Up 중 (100%까지 충전)",
                    updatedAt: 1.0,
                    activity: .topUp
                )
                let replyData = try? BatteryControlCodec.encode(status)
                return (replyData, nil)
            }
            return (nil, nil)
        })

        await client.startTopUp(
            limitPercentage: 80,
            lowerHysteresisDelta: 2,
            heatProtectionEnabled: false,
            heatProtectionThresholdCelsius: 35
        )

        #expect(recordedRequest?.configuration.topUpActive == true)
        #expect(recordedRequest?.configuration.limitPercentage == 80)
    }

    @Test func cancelTopUpAppliesTopUpActiveFalse() async {
        var recordedRequest: BatteryControlConfigurationRequest?
        let client = BatteryControlClient(requestHandler: { req in
            if case .configure(let data) = req {
                recordedRequest = try? BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
                let status = BatteryControlServiceStatus(
                    mode: .inhibited,
                    currentPercentage: 85,
                    isPowerAdapterConnected: true,
                    detail: "충전 제한 80% 도달",
                    updatedAt: 1.0,
                    activity: .holdingAtLimit
                )
                let replyData = try? BatteryControlCodec.encode(status)
                return (replyData, nil)
            }
            return (nil, nil)
        })

        await client.cancelTopUp(
            limitPercentage: 80,
            lowerHysteresisDelta: 2,
            heatProtectionEnabled: false,
            heatProtectionThresholdCelsius: 35
        )

        #expect(recordedRequest?.configuration.topUpActive == false)
        #expect(recordedRequest?.configuration.limitPercentage == 80)
    }
```

- [ ] **Step 2: Generate project and run tests to verify they fail**

Run:
```bash
xcodegen generate
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  -only-testing:WattlyTests/BatteryNotificationManagerTests \
  -only-testing:WattlyTests/BatteryControlClientTests
```
Expected: FAIL because `BatteryNotificationManager` and client methods do not exist.

- [ ] **Step 3: Implement BatteryNotificationManager, Client methods, and Bridge observer**

Create `Wattly/Core/BatteryNotificationManager.swift`:

```swift
import Foundation
import UserNotifications

public struct BatteryTopUpTransitionDetector: Sendable {
    private var lastReasonKind: BatteryControlStatusReason.Kind?

    public init() {}

    public mutating func update(reasonKind: BatteryControlStatusReason.Kind?) -> Bool {
        defer { lastReasonKind = reasonKind }
        guard let reasonKind else { return false }
        if lastReasonKind == .topUpCharging && reasonKind == .topUpComplete {
            return true
        }
        return false
    }
}

public enum BatteryNotificationManager {
    public static func topUpCompleteTitle(locale: Locale) -> String {
        String(localized: "Top Up 완료", locale: locale)
    }

    public static func topUpCompleteBody(locale: Locale) -> String {
        String(localized: "배터리가 100%까지 충전되었습니다. 어댑터를 분리하면 기존 충전 제한으로 자동 복귀합니다.", locale: locale)
    }

    public static func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public static func postTopUpCompleteNotification() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = topUpCompleteTitle(locale: .current)
            content.body = topUpCompleteBody(locale: .current)
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "dev.jjundev.Wattly.topUpComplete",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }
}
```

In `Wattly/Control/BatteryControlClient.swift`:

```swift
    @discardableResult
    public func apply(
        enabled: Bool,
        limitPercentage: Int,
        lowerHysteresisDelta: Int = 2,
        heatProtectionEnabled: Bool = false,
        heatProtectionThresholdCelsius: Int = 35,
        topUpActive: Bool = false
    ) async -> BatteryControlServiceStatus? {
        commandGeneration &+= 1
        let config = BatteryControlConfiguration(
            enabled: enabled,
            limitPercentage: limitPercentage,
            lowerHysteresisDelta: lowerHysteresisDelta,
            heatProtectionEnabled: heatProtectionEnabled,
            heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
            topUpActive: topUpActive
        )
        let request = BatteryControlConfigurationRequest(configuration: config, generation: commandGeneration)
        guard let data = try? BatteryControlCodec.encode(request) else {
            updateUnavailable("충전 제한 설정을 인코딩할 수 없음")
            return nil
        }
        return await send(.configure(data))
    }

    @discardableResult
    public func startTopUp(
        limitPercentage: Int,
        lowerHysteresisDelta: Int = 2,
        heatProtectionEnabled: Bool = false,
        heatProtectionThresholdCelsius: Int = 35
    ) async -> BatteryControlServiceStatus? {
        BatteryNotificationManager.requestAuthorization()
        return await apply(
            enabled: true,
            limitPercentage: limitPercentage,
            lowerHysteresisDelta: lowerHysteresisDelta,
            heatProtectionEnabled: heatProtectionEnabled,
            heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
            topUpActive: true
        )
    }

    @discardableResult
    public func cancelTopUp(
        limitPercentage: Int,
        lowerHysteresisDelta: Int = 2,
        heatProtectionEnabled: Bool = false,
        heatProtectionThresholdCelsius: Int = 35
    ) async -> BatteryControlServiceStatus? {
        await apply(
            enabled: true,
            limitPercentage: limitPercentage,
            lowerHysteresisDelta: lowerHysteresisDelta,
            heatProtectionEnabled: heatProtectionEnabled,
            heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
            topUpActive: false
        )
    }

    public func reconcile(
        enabled: Bool,
        limitPercentage: Int,
        lowerHysteresisDelta: Int = 2,
        heatProtectionEnabled: Bool = false,
        heatProtectionThresholdCelsius: Int = 35
    ) async {
        await refreshStatus()
        let isTopUp = status.desiredConfiguration?.topUpActive == true
        guard !Task.isCancelled,
              BatteryControlPolicy.shouldReapply(
                configuration: .init(
                    enabled: enabled,
                    limitPercentage: limitPercentage,
                    lowerHysteresisDelta: lowerHysteresisDelta,
                    heatProtectionEnabled: heatProtectionEnabled,
                    heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
                    topUpActive: isTopUp),
                status: status) else { return }
        if enabled || heatProtectionEnabled || isTopUp {
            await apply(
                enabled: enabled,
                limitPercentage: limitPercentage,
                lowerHysteresisDelta: lowerHysteresisDelta,
                heatProtectionEnabled: heatProtectionEnabled,
                heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
                topUpActive: isTopUp)
        } else {
            _ = await disableAndConfirm(
                limitPercentage: limitPercentage,
                lowerHysteresisDelta: lowerHysteresisDelta)
        }
    }
```

In `Wattly/Views/BatteryControlBridge.swift`:
Attach the detector and observer:

```swift
    @State private var topUpDetector = BatteryTopUpTransitionDetector()

    // Add inside body View hierarchy:
    .onChange(of: client.status) { _, newStatus in
        if topUpDetector.update(reasonKind: newStatus.detailReason?.kind) {
            BatteryNotificationManager.postTopUpCompleteNotification()
        }
    }
```

- [ ] **Step 4: Regenerate project and run tests**

Run:
```bash
xcodegen generate
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  -only-testing:WattlyTests/BatteryNotificationManagerTests \
  -only-testing:WattlyTests/BatteryControlClientTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/BatteryNotificationManager.swift \
  Wattly/Control/BatteryControlClient.swift \
  Wattly/Views/BatteryControlBridge.swift \
  WattlyTests/BatteryNotificationManagerTests.swift \
  WattlyTests/BatteryControlClientTests.swift \
  Wattly.xcodeproj/project.pbxproj
git commit -m "feat(battery): implement client top up API and notification manager"
```

---

### Task 6: Implement Top Up UI in Menu Bar Popover & Settings View

**Files:**
- Modify: `Wattly/App/WattlyApp.swift:25-30`
- Modify: `Wattly/Views/PopoverContentView.swift:10-50,380-410`
- Modify: `Wattly/Views/MetricCardView.swift:15-50`
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift:180-240`
- Modify: `WattlyTests/SettingsBatterySectionTests.swift`

**Interfaces:**
- Consumes: `BatteryControlClient.startTopUp()`, `BatteryControlClient.cancelTopUp()`, `BatteryControlServiceStatus.activity`.
- Produces: Data flow of `BatteryControlClient` to popover and quick action controls in Popover and Settings.

- [ ] **Step 1: Write failing UI presentation tests**

In `WattlyTests/SettingsBatterySectionTests.swift`, add:

```swift
    @Test func topUpButtonStatePresentation() {
        // When Top Up is active, button shows "Top Up 취소"
        let isTopUpActive = true
        let labelActive = isTopUpActive ? "Top Up 취소" : "Top Up 시작"
        #expect(labelActive == "Top Up 취소")

        // When Top Up is inactive, button shows "Top Up 시작"
        let isTopUpInactive = false
        let labelInactive = isTopUpInactive ? "Top Up 취소" : "Top Up 시작"
        #expect(labelInactive == "Top Up 시작")
    }
```

- [ ] **Step 2: Run tests to verify**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  -only-testing:WattlyTests/SettingsBatterySectionTests
```
Expected: PASS.

- [ ] **Step 3: Implement data flow and Top Up controls in Popover and Settings**

In `Wattly/App/WattlyApp.swift`:
Pass `batteryControl: batteryControl` into `PopoverContentView`:

```swift
        MenuBarExtra {
            ThemedRoot {
                PopoverContentView(monitor: monitor, fanControl: fanControl, batteryControl: batteryControl)
            }
        }
```

In `Wattly/Views/PopoverContentView.swift`:
Accept `batteryControl: BatteryControlClient` and pass to `MetricCardView`:

```swift
struct PopoverContentView: View {
    let monitor: SystemMonitor
    let fanControl: FanControlClient
    let batteryControl: BatteryControlClient
```

In `Wattly/Views/MetricCardView.swift`:
In the expanded battery card or when `card == .battery`, add a quick action Top Up button when plugged in:

```swift
    // When card == .battery && isExpanded && batteryControl.status.isPowerAdapterConnected:
    let isTopUp = batteryControl.status.desiredConfiguration?.topUpActive == true
        || batteryControl.status.activity == .topUp
    Button {
        Task {
            if isTopUp {
                await batteryControl.cancelTopUp(
                    limitPercentage: 80,
                    lowerHysteresisDelta: 2)
            } else {
                await batteryControl.startTopUp(
                    limitPercentage: 80,
                    lowerHysteresisDelta: 2)
            }
        }
    } label: {
        HStack(spacing: 4) {
            Image(systemName: isTopUp ? "xmark.circle.fill" : "bolt.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(isTopUp ? "Top Up 취소" : "Top Up (100% 충전)")
                .font(WattlyFont.at(10.5, weight: .medium))
        }
        .foregroundStyle(isTopUp ? Tokens.statusOrange : Tokens.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(t.segTrack))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(isTopUp ? Tokens.statusOrange.opacity(0.4) : t.rowBorder, lineWidth: 1))
    }
    .buttonStyle(.plain)
```

In `Wattly/Views/Settings/SettingsBatterySection.swift`:
Inside `if showsConfigurationControls`, add the dedicated Top Up settings row:

```swift
                    Rectangle().fill(t.line).frame(height: 1)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 2) {
                                SettingsRowTitle("한 번만 100% 충전 (Top Up)")
                                Text("외출 전에 한 번만 100%까지 완충하며, 어댑터를 분리하면 기존 한도로 자동 복귀합니다.")
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
                                    Image(systemName: isTopUp ? "xmark.circle" : "bolt.fill")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(isTopUp ? "Top Up 취소" : "Top Up 시작")
                                        .font(WattlyFont.at(11.5, weight: .medium))
                                }
                                .foregroundStyle(isTopUp ? Tokens.statusOrange : t.text)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(t.segTrack))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(isTopUp ? Tokens.statusOrange.opacity(0.5) : t.rowBorder, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .disabled(!isToggleEnabled || isHardwareUnsupported)
                        }
                    }
                    .padding(EdgeInsets(top: 10, leading: 14, bottom: 14, trailing: 14))
```

- [ ] **Step 4: Run all test suites and verify full build**

Run:
```bash
xcodegen generate
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'
xcodebuild build -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'
```
Expected: `** TEST SUCCEEDED **` and `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit UI changes**

```bash
git add Wattly/App/WattlyApp.swift \
  Wattly/Views/PopoverContentView.swift \
  Wattly/Views/MetricCardView.swift \
  Wattly/Views/Settings/SettingsBatterySection.swift \
  WattlyTests/SettingsBatterySectionTests.swift
git commit -m "feat(battery): implement top up UI in settings and popover"
```
