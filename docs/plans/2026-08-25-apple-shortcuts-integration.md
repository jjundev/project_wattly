# Apple Shortcuts (App Intents) Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement Apple Shortcuts integration using macOS 14+ native `AppIntents` framework to expose Wattly's battery management controls (charge limits, sailing mode, Top Up, heat protection, and real-time battery/temperature telemetry) to the macOS Shortcuts app and Siri.

**Architecture:** A lightweight facade (`BatteryIntentBridge`) coordinates between `AppIntent` handlers, `UserDefaults.standard` (`StorageKey`s), `BatteryProvider` (for instant SMC/IOKit telemetry), and `BatteryControlClient` (for privileged LaunchDaemon XPC control). Read intents return structured `AppEntity` / `TransientEntity` models for Shortcuts action chaining, while write intents validate and clamp inputs, update persisted preferences, push the policy via XPC, and return localized feedback dialogs without popping unexpected UI auth prompts in headless contexts.

**Tech Stack:** Swift 6 (Strict Concurrency), AppIntents, SwiftUI, IOKit, SMC, Swift Testing, XcodeGen, macOS 14+ (arm64)

## Global Constraints

- Target macOS 14.0+ on Apple Silicon arm64 with Swift 6 mode; no third-party dependencies.
- AppIntents code must reside directly inside the main `Wattly` application target without separate extension targets.
- Headless / background execution must never trigger interactive admin password prompts; helper absence or failure must throw typed `BatteryIntentError`.
- Hardware safety precedence must be maintained: Heat Protection and low SoC thresholds outrank any Shortcuts request.
- Every persisted configuration edit via Shortcuts must synchronize `UserDefaults.standard` (`StorageKey`) so active `@AppStorage` views update immediately.
- Whenever new source files are added, run `xcodegen generate` to update `Wattly.xcodeproj/project.pbxproj`.
- Full verification command: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -derivedDataPath .derivedData -destination 'platform=macOS'`

---

### Task 1: Create Battery Intent Error Types and Entity Models

**Files:**
- Create: `Wattly/Intents/Errors/BatteryIntentError.swift`
- Create: `Wattly/Intents/Entities/BatteryStateEntity.swift`
- Create: `Wattly/Intents/Entities/BatteryLimitConfigEntity.swift`
- Create: `WattlyTests/BatteryIntentEntityTests.swift`

**Interfaces:**
- Consumes: `AppIntents` framework, `LocalizedStringResource`.
- Produces: `BatteryIntentError`, `BatteryStateEntity`, `BatteryLimitConfigEntity`.

- [ ] **Step 1: Write the failing tests for entity models and error descriptions**

In `WattlyTests/BatteryIntentEntityTests.swift`:

```swift
import Testing
import AppIntents
import Foundation
@testable import Wattly

@Suite struct BatteryIntentEntityTests {
    @Test func batteryStateEntityProperties() {
        let entity = BatteryStateEntity(
            percentage: 80,
            isCharging: true,
            isPowerAdapterConnected: true,
            temperatureCelsius: 32.5,
            netWatts: -15.2,
            timeRemainingMinutes: 120,
            healthPercentage: 98
        )

        #expect(entity.percentage == 80)
        #expect(entity.isCharging == true)
        #expect(entity.isPowerAdapterConnected == true)
        #expect(entity.temperatureCelsius == 32.5)
        #expect(entity.netWatts == -15.2)
        #expect(entity.timeRemainingMinutes == 120)
        #expect(entity.healthPercentage == 98)
    }

    @Test func batteryLimitConfigEntityProperties() {
        let entity = BatteryLimitConfigEntity(
            isEnabled: true,
            limitPercentage: 80,
            isSailingEnabled: true,
            sailingDelta: 5,
            isHeatProtectionEnabled: true,
            isTopUpActive: false
        )

        #expect(entity.isEnabled == true)
        #expect(entity.limitPercentage == 80)
        #expect(entity.isSailingEnabled == true)
        #expect(entity.sailingDelta == 5)
        #expect(entity.isHeatProtectionEnabled == true)
        #expect(entity.isTopUpActive == false)
    }

    @Test func batteryIntentErrorLocalizationKeys() {
        let notInstalled = BatteryIntentError.helperNotInstalled
        let unsupported = BatteryIntentError.hardwareUnsupported
        let xpcFailed = BatteryIntentError.xpcCommunicationFailed("Timeout")
        let invalidParam = BatteryIntentError.invalidParameter("Out of range")

        #expect(notInstalled.errorDescription != nil)
        #expect(unsupported.errorDescription != nil)
        #expect(xpcFailed.errorDescription != nil)
        #expect(invalidParam.errorDescription != nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -derivedDataPath .derivedData -destination 'platform=macOS' -only-testing:WattlyTests/BatteryIntentEntityTests
```
Expected: FAIL due to missing `BatteryIntentError`, `BatteryStateEntity`, `BatteryLimitConfigEntity`.

- [ ] **Step 3: Implement BatteryIntentError, BatteryStateEntity, and BatteryLimitConfigEntity**

In `Wattly/Intents/Errors/BatteryIntentError.swift`:

```swift
import Foundation
import AppIntents

public enum BatteryIntentError: Swift.Error, CustomLocalizedStringResourceConvertible, LocalizedError, Sendable {
    case helperNotInstalled
    case hardwareUnsupported
    case xpcCommunicationFailed(String)
    case invalidParameter(String)

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .helperNotInstalled:
            return "Wattly 도우미가 설치되지 않았습니다. Wattly 앱 설정에서 도우미를 먼저 설치해주세요."
        case .hardwareUnsupported:
            return "이 Mac은 배터리 충전 제어를 지원하지 않는 하드웨어입니다."
        case .xpcCommunicationFailed(let detail):
            return "도우미와의 통신에 실패했습니다: \(detail)"
        case .invalidParameter(let msg):
            return "유효하지 않은 설정값입니다: \(msg)"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .helperNotInstalled:
            return "Wattly 도우미가 설치되지 않았습니다. Wattly 앱 설정에서 도우미를 먼저 설치해주세요."
        case .hardwareUnsupported:
            return "이 Mac은 배터리 충전 제어를 지원하지 않는 하드웨어입니다."
        case .xpcCommunicationFailed(let detail):
            return "도우미와의 통신에 실패했습니다: \(detail)"
        case .invalidParameter(let msg):
            return "유효하지 않은 설정값입니다: \(msg)"
        }
    }
}
```

In `Wattly/Intents/Entities/BatteryStateEntity.swift`:

```swift
import Foundation
import AppIntents

public struct BatteryStateEntity: TransientEntity, Sendable {
    public static var headerTitle: LocalizedStringResource = "배터리 상태"

    @Property(title: "배터리 잔량 (%)")
    public var percentage: Int

    @Property(title: "충전 중 여부")
    public var isCharging: Bool

    @Property(title: "전원 어댑터 연결 여부")
    public var isPowerAdapterConnected: Bool

    @Property(title: "배터리 온도 (°C)")
    public var temperatureCelsius: Double?

    @Property(title: "순 소비 전력 (W)")
    public var netWatts: Double?

    @Property(title: "남은 사용/충전 시간 (분)")
    public var timeRemainingMinutes: Int?

    @Property(title: "배터리 수명/효율 (%)")
    public var healthPercentage: Int?

    public init(
        percentage: Int,
        isCharging: Bool,
        isPowerAdapterConnected: Bool,
        temperatureCelsius: Double? = nil,
        netWatts: Double? = nil,
        timeRemainingMinutes: Int? = nil,
        healthPercentage: Int? = nil
    ) {
        self.percentage = percentage
        self.isCharging = isCharging
        self.isPowerAdapterConnected = isPowerAdapterConnected
        self.temperatureCelsius = temperatureCelsius
        self.netWatts = netWatts
        self.timeRemainingMinutes = timeRemainingMinutes
        self.healthPercentage = healthPercentage
    }
}
```

In `Wattly/Intents/Entities/BatteryLimitConfigEntity.swift`:

```swift
import Foundation
import AppIntents

public struct BatteryLimitConfigEntity: TransientEntity, Sendable {
    public static var headerTitle: LocalizedStringResource = "배터리 충전 제한 설정"

    @Property(title: "충전 제한 활성화 여부")
    public var isEnabled: Bool

    @Property(title: "최대 충전 한도 (%)")
    public var limitPercentage: Int

    @Property(title: "Sailing 모드 활성화 여부")
    public var isSailingEnabled: Bool

    @Property(title: "Sailing 범위 (%)")
    public var sailingDelta: Int

    @Property(title: "발열 보호 활성화 여부")
    public var isHeatProtectionEnabled: Bool

    @Property(title: "한 번만 완충 활성화 여부")
    public var isTopUpActive: Bool

    public init(
        isEnabled: Bool,
        limitPercentage: Int,
        isSailingEnabled: Bool,
        sailingDelta: Int,
        isHeatProtectionEnabled: Bool,
        isTopUpActive: Bool
    ) {
        self.isEnabled = isEnabled
        self.limitPercentage = limitPercentage
        self.isSailingEnabled = isSailingEnabled
        self.sailingDelta = sailingDelta
        self.isHeatProtectionEnabled = isHeatProtectionEnabled
        self.isTopUpActive = isTopUpActive
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -derivedDataPath .derivedData -destination 'platform=macOS' -only-testing:WattlyTests/BatteryIntentEntityTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Intents/Errors/BatteryIntentError.swift \
  Wattly/Intents/Entities/BatteryStateEntity.swift \
  Wattly/Intents/Entities/BatteryLimitConfigEntity.swift \
  WattlyTests/BatteryIntentEntityTests.swift \
  Wattly.xcodeproj/project.pbxproj
git commit -m "feat(shortcuts): add battery intent entities and error types"
```

---

### Task 2: Implement BatteryIntentBridge Facade

**Files:**
- Create: `Wattly/Intents/BatteryIntentBridge.swift`
- Create: `WattlyTests/BatteryIntentBridgeTests.swift`

**Interfaces:**
- Consumes: `BatteryControlClient`, `BatteryProvider`, `UserDefaults.standard`, `StorageKey`, `Defaults`, `BatteryControlConfiguration`.
- Produces: `BatteryIntentBridge` actor with methods:
  - `fetchBatteryState() async throws -> BatteryStateEntity`
  - `fetchLimitConfig() async throws -> BatteryLimitConfigEntity`
  - `applyLimit(enabled: Bool?, limitPercentage: Int?) async throws -> BatteryControlServiceStatus`
  - `applySailing(enabled: Bool, delta: Int?) async throws -> BatteryControlServiceStatus`
  - `applyTopUp(start: Bool) async throws -> BatteryControlServiceStatus`
  - `applyHeatProtection(enabled: Bool, thresholdCelsius: Int?) async throws -> BatteryControlServiceStatus`

- [ ] **Step 1: Write failing bridge tests**

In `WattlyTests/BatteryIntentBridgeTests.swift`:

```swift
import Testing
import Foundation
@testable import Wattly

@Suite struct BatteryIntentBridgeTests {
    @Test func fetchLimitConfigReadsFromUserDefaults() async throws {
        let defaults = UserDefaults(suiteName: "BatteryIntentBridgeTests")!
        defaults.set(true, forKey: StorageKey.batteryLimitEnabled)
        defaults.set(85, forKey: StorageKey.batteryLimitPercentage)
        defaults.set(true, forKey: StorageKey.batterySailingEnabled)
        defaults.set(4, forKey: StorageKey.batterySailingDelta)
        defaults.set(true, forKey: StorageKey.batteryHeatProtectionEnabled)

        let bridge = BatteryIntentBridge(userDefaults: defaults, clientProvider: {
            BatteryControlClient(requestHandler: { req in
                let status = BatteryControlServiceStatus(
                    mode: .charging,
                    currentPercentage: 70,
                    isPowerAdapterConnected: true,
                    detail: "정상",
                    updatedAt: 100,
                    desiredConfiguration: BatteryControlConfiguration(
                        enabled: true, limitPercentage: 85, lowerHysteresisDelta: 4, heatProtectionEnabled: true, topUpActive: false
                    )
                )
                let data = try? BatteryControlCodec.encode(status)
                return (data, nil)
            })
        })

        let config = try await bridge.fetchLimitConfig()
        #expect(config.isEnabled == true)
        #expect(config.limitPercentage == 85)
        #expect(config.isSailingEnabled == true)
        #expect(config.sailingDelta == 4)
        #expect(config.isHeatProtectionEnabled == true)
    }

    @Test func applyLimitPersistsDefaultsAndInvokesClient() async throws {
        let defaults = UserDefaults(suiteName: "BatteryIntentBridgeTestsApply")!
        defaults.set(false, forKey: StorageKey.batteryLimitEnabled)
        defaults.set(80, forKey: StorageKey.batteryLimitPercentage)

        var requestedConfig: BatteryControlConfigurationRequest?
        let bridge = BatteryIntentBridge(userDefaults: defaults, clientProvider: {
            BatteryControlClient(requestHandler: { req in
                if case .configure(let data) = req {
                    requestedConfig = try? BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
                }
                let status = BatteryControlServiceStatus(
                    mode: .charging,
                    currentPercentage: 70,
                    isPowerAdapterConnected: true,
                    detail: "정상",
                    updatedAt: 100,
                    isHardwareSupported: true
                )
                let data = try? BatteryControlCodec.encode(status)
                return (data, nil)
            })
        })

        let status = try await bridge.applyLimit(enabled: true, limitPercentage: 90)
        #expect(status.isHardwareSupported == true)
        #expect(defaults.bool(forKey: StorageKey.batteryLimitEnabled) == true)
        #expect(defaults.integer(forKey: StorageKey.batteryLimitPercentage) == 90)
        #expect(requestedConfig?.configuration.limitPercentage == 90)
        #expect(requestedConfig?.configuration.enabled == true)
    }

    @Test func applyFailsWhenHelperUnavailable() async {
        let defaults = UserDefaults(suiteName: "BatteryIntentBridgeTestsFail")!
        let bridge = BatteryIntentBridge(userDefaults: defaults, clientProvider: {
            BatteryControlClient(requestHandler: { _ in
                (nil, NSError(domain: "Wattly", code: 1, userInfo: [NSLocalizedDescriptionKey: "Helper not installed"]))
            })
        })

        await #expect(throws: BatteryIntentError.self) {
            try await bridge.applyLimit(enabled: true, limitPercentage: 80)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -derivedDataPath .derivedData -destination 'platform=macOS' -only-testing:WattlyTests/BatteryIntentBridgeTests
```
Expected: FAIL due to missing `BatteryIntentBridge`.

- [ ] **Step 3: Implement BatteryIntentBridge**

In `Wattly/Intents/BatteryIntentBridge.swift`:

```swift
import Foundation
import AppKit

public final class BatteryIntentBridge: @unchecked Sendable {
    public static let shared = BatteryIntentBridge()

    private let userDefaults: UserDefaults
    private let clientProvider: @Sendable () -> BatteryControlClient
    private let batteryProvider: BatteryProvider

    public init(
        userDefaults: UserDefaults = .standard,
        clientProvider: (@Sendable () -> BatteryControlClient)? = nil,
        batteryProvider: BatteryProvider = BatteryProvider()
    ) {
        self.userDefaults = userDefaults
        self.clientProvider = clientProvider ?? {
            if Thread.isMainThread {
                return BatteryControlClient()
            } else {
                return DispatchQueue.main.sync { BatteryControlClient() }
            }
        }
        self.batteryProvider = batteryProvider
    }

    public func fetchBatteryState() async throws -> BatteryStateEntity {
        let reading = await batteryProvider.read(at: .now())
        let client = await MainActor.run { clientProvider() }
        let status = await client.refreshStatus()

        var percentage = status?.currentPercentage ?? 0
        var isCharging = false
        var isPluggedIn = status?.isPowerAdapterConnected ?? false
        var temp: Double? = status?.batteryTemperatureCelsius
        var netW: Double?
        var timeRemaining: Int?
        var health: Int?

        if case .value(.battery(let sample)) = reading {
            if percentage == 0 {
                percentage = sample.maxWh > 0 ? Int((Double(sample.remainingWh) / Double(sample.maxWh) * 100.0).rounded()) : 0
            }
            isCharging = sample.charging
            isPluggedIn = sample.externalConnected
            if temp == nil { temp = sample.temperatureCelsius }
            netW = sample.netW
            timeRemaining = sample.timeRemainingMinutes
            health = sample.efficiencyPercent
        }

        return BatteryStateEntity(
            percentage: percentage,
            isCharging: isCharging,
            isPowerAdapterConnected: isPluggedIn,
            temperatureCelsius: temp,
            netWatts: netW,
            timeRemainingMinutes: timeRemaining,
            healthPercentage: health
        )
    }

    public func fetchLimitConfig() async throws -> BatteryLimitConfigEntity {
        let isEnabled = userDefaults.object(forKey: StorageKey.batteryLimitEnabled) != nil
            ? userDefaults.bool(forKey: StorageKey.batteryLimitEnabled)
            : Defaults.batteryLimitEnabled
        let limit = userDefaults.object(forKey: StorageKey.batteryLimitPercentage) != nil
            ? userDefaults.integer(forKey: StorageKey.batteryLimitPercentage)
            : Defaults.batteryLimitPercentage
        let sailingEnabled = userDefaults.object(forKey: StorageKey.batterySailingEnabled) != nil
            ? userDefaults.bool(forKey: StorageKey.batterySailingEnabled)
            : Defaults.batterySailingEnabled
        let sailingDelta = userDefaults.object(forKey: StorageKey.batterySailingDelta) != nil
            ? userDefaults.integer(forKey: StorageKey.batterySailingDelta)
            : Defaults.batterySailingDelta
        let heatEnabled = userDefaults.object(forKey: StorageKey.batteryHeatProtectionEnabled) != nil
            ? userDefaults.bool(forKey: StorageKey.batteryHeatProtectionEnabled)
            : Defaults.batteryHeatProtectionEnabled

        let client = await MainActor.run { clientProvider() }
        let status = await client.refreshStatus()
        let isTopUp = status?.desiredConfiguration?.topUpActive == true || status?.activity == .topUp

        return BatteryLimitConfigEntity(
            isEnabled: isEnabled,
            limitPercentage: limit,
            isSailingEnabled: sailingEnabled,
            sailingDelta: sailingDelta,
            isHeatProtectionEnabled: heatEnabled,
            isTopUpActive: isTopUp
        )
    }

    @discardableResult
    public func applyLimit(enabled: Bool? = nil, limitPercentage: Int? = nil) async throws -> BatteryControlServiceStatus {
        let curEnabled = userDefaults.object(forKey: StorageKey.batteryLimitEnabled) != nil
            ? userDefaults.bool(forKey: StorageKey.batteryLimitEnabled)
            : Defaults.batteryLimitEnabled
        let curLimit = userDefaults.object(forKey: StorageKey.batteryLimitPercentage) != nil
            ? userDefaults.integer(forKey: StorageKey.batteryLimitPercentage)
            : Defaults.batteryLimitPercentage
        let sailingEnabled = userDefaults.object(forKey: StorageKey.batterySailingEnabled) != nil
            ? userDefaults.bool(forKey: StorageKey.batterySailingEnabled)
            : Defaults.batterySailingEnabled
        let sailingDelta = userDefaults.object(forKey: StorageKey.batterySailingDelta) != nil
            ? userDefaults.integer(forKey: StorageKey.batterySailingDelta)
            : Defaults.batterySailingDelta
        let heatEnabled = userDefaults.object(forKey: StorageKey.batteryHeatProtectionEnabled) != nil
            ? userDefaults.bool(forKey: StorageKey.batteryHeatProtectionEnabled)
            : Defaults.batteryHeatProtectionEnabled
        let heatThreshold = userDefaults.object(forKey: StorageKey.batteryHeatProtectionThreshold) != nil
            ? userDefaults.integer(forKey: StorageKey.batteryHeatProtectionThreshold)
            : Defaults.batteryHeatProtectionThreshold

        let newEnabled = enabled ?? curEnabled
        let newLimit = limitPercentage ?? curLimit
        let delta = sailingEnabled ? sailingDelta : 2

        let client = await MainActor.run { clientProvider() }
        guard let status = await client.apply(
            enabled: newEnabled,
            limitPercentage: newLimit,
            lowerHysteresisDelta: delta,
            heatProtectionEnabled: heatEnabled,
            heatProtectionThresholdCelsius: heatThreshold
        ) else {
            throw BatteryIntentError.helperNotInstalled
        }

        if status.mode == .unsupported || status.isHardwareSupported == false {
            throw BatteryIntentError.hardwareUnsupported
        }

        userDefaults.set(newEnabled, forKey: StorageKey.batteryLimitEnabled)
        userDefaults.set(newLimit, forKey: StorageKey.batteryLimitPercentage)

        return status
    }

    @discardableResult
    public func applySailing(enabled: Bool, delta: Int? = nil) async throws -> BatteryControlServiceStatus {
        let curLimit = userDefaults.object(forKey: StorageKey.batteryLimitPercentage) != nil
            ? userDefaults.integer(forKey: StorageKey.batteryLimitPercentage)
            : Defaults.batteryLimitPercentage
        let curEnabled = userDefaults.object(forKey: StorageKey.batteryLimitEnabled) != nil
            ? userDefaults.bool(forKey: StorageKey.batteryLimitEnabled)
            : Defaults.batteryLimitEnabled
        let curDelta = userDefaults.object(forKey: StorageKey.batterySailingDelta) != nil
            ? userDefaults.integer(forKey: StorageKey.batterySailingDelta)
            : Defaults.batterySailingDelta
        let heatEnabled = userDefaults.object(forKey: StorageKey.batteryHeatProtectionEnabled) != nil
            ? userDefaults.bool(forKey: StorageKey.batteryHeatProtectionEnabled)
            : Defaults.batteryHeatProtectionEnabled
        let heatThreshold = userDefaults.object(forKey: StorageKey.batteryHeatProtectionThreshold) != nil
            ? userDefaults.integer(forKey: StorageKey.batteryHeatProtectionThreshold)
            : Defaults.batteryHeatProtectionThreshold

        let newDelta = delta ?? curDelta
        let effectiveDelta = enabled ? newDelta : 2

        let client = await MainActor.run { clientProvider() }
        guard let status = await client.apply(
            enabled: curEnabled,
            limitPercentage: curLimit,
            lowerHysteresisDelta: effectiveDelta,
            heatProtectionEnabled: heatEnabled,
            heatProtectionThresholdCelsius: heatThreshold
        ) else {
            throw BatteryIntentError.helperNotInstalled
        }

        if status.mode == .unsupported || status.isHardwareSupported == false {
            throw BatteryIntentError.hardwareUnsupported
        }

        userDefaults.set(enabled, forKey: StorageKey.batterySailingEnabled)
        if let delta { userDefaults.set(delta, forKey: StorageKey.batterySailingDelta) }

        return status
    }

    @discardableResult
    public func applyTopUp(start: Bool) async throws -> BatteryControlServiceStatus {
        let curLimit = userDefaults.object(forKey: StorageKey.batteryLimitPercentage) != nil
            ? userDefaults.integer(forKey: StorageKey.batteryLimitPercentage)
            : Defaults.batteryLimitPercentage
        let sailingEnabled = userDefaults.object(forKey: StorageKey.batterySailingEnabled) != nil
            ? userDefaults.bool(forKey: StorageKey.batterySailingEnabled)
            : Defaults.batterySailingEnabled
        let sailingDelta = userDefaults.object(forKey: StorageKey.batterySailingDelta) != nil
            ? userDefaults.integer(forKey: StorageKey.batterySailingDelta)
            : Defaults.batterySailingDelta
        let heatEnabled = userDefaults.object(forKey: StorageKey.batteryHeatProtectionEnabled) != nil
            ? userDefaults.bool(forKey: StorageKey.batteryHeatProtectionEnabled)
            : Defaults.batteryHeatProtectionEnabled
        let heatThreshold = userDefaults.object(forKey: StorageKey.batteryHeatProtectionThreshold) != nil
            ? userDefaults.integer(forKey: StorageKey.batteryHeatProtectionThreshold)
            : Defaults.batteryHeatProtectionThreshold
        let delta = sailingEnabled ? sailingDelta : 2

        let client = await MainActor.run { clientProvider() }
        let status: BatteryControlServiceStatus?
        if start {
            status = await client.startTopUp(
                limitPercentage: curLimit,
                lowerHysteresisDelta: delta,
                heatProtectionEnabled: heatEnabled,
                heatProtectionThresholdCelsius: heatThreshold
            )
        } else {
            status = await client.cancelTopUp(
                limitPercentage: curLimit,
                lowerHysteresisDelta: delta,
                heatProtectionEnabled: heatEnabled,
                heatProtectionThresholdCelsius: heatThreshold
            )
        }

        guard let result = status else {
            throw BatteryIntentError.helperNotInstalled
        }
        if result.mode == .unsupported || result.isHardwareSupported == false {
            throw BatteryIntentError.hardwareUnsupported
        }
        return result
    }

    @discardableResult
    public func applyHeatProtection(enabled: Bool, thresholdCelsius: Int? = nil) async throws -> BatteryControlServiceStatus {
        let curLimit = userDefaults.object(forKey: StorageKey.batteryLimitPercentage) != nil
            ? userDefaults.integer(forKey: StorageKey.batteryLimitPercentage)
            : Defaults.batteryLimitPercentage
        let limitEnabled = userDefaults.object(forKey: StorageKey.batteryLimitEnabled) != nil
            ? userDefaults.bool(forKey: StorageKey.batteryLimitEnabled)
            : Defaults.batteryLimitEnabled
        let sailingEnabled = userDefaults.object(forKey: StorageKey.batterySailingEnabled) != nil
            ? userDefaults.bool(forKey: StorageKey.batterySailingEnabled)
            : Defaults.batterySailingEnabled
        let sailingDelta = userDefaults.object(forKey: StorageKey.batterySailingDelta) != nil
            ? userDefaults.integer(forKey: StorageKey.batterySailingDelta)
            : Defaults.batterySailingDelta
        let curThreshold = userDefaults.object(forKey: StorageKey.batteryHeatProtectionThreshold) != nil
            ? userDefaults.integer(forKey: StorageKey.batteryHeatProtectionThreshold)
            : Defaults.batteryHeatProtectionThreshold

        let newThreshold = thresholdCelsius ?? curThreshold
        let delta = sailingEnabled ? sailingDelta : 2

        let client = await MainActor.run { clientProvider() }
        guard let status = await client.apply(
            enabled: limitEnabled,
            limitPercentage: curLimit,
            lowerHysteresisDelta: delta,
            heatProtectionEnabled: enabled,
            heatProtectionThresholdCelsius: newThreshold
        ) else {
            throw BatteryIntentError.helperNotInstalled
        }

        if status.mode == .unsupported || status.isHardwareSupported == false {
            throw BatteryIntentError.hardwareUnsupported
        }

        userDefaults.set(enabled, forKey: StorageKey.batteryHeatProtectionEnabled)
        if let thresholdCelsius { userDefaults.set(thresholdCelsius, forKey: StorageKey.batteryHeatProtectionThreshold) }

        return status
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -derivedDataPath .derivedData -destination 'platform=macOS' -only-testing:WattlyTests/BatteryIntentBridgeTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Intents/BatteryIntentBridge.swift \
  WattlyTests/BatteryIntentBridgeTests.swift \
  Wattly.xcodeproj/project.pbxproj
git commit -m "feat(shortcuts): implement BatteryIntentBridge facade"
```

---

### Task 3: Implement Read Intents (`GetBatteryStatusIntent`, `GetBatteryLimitIntent`)

**Files:**
- Create: `Wattly/Intents/Intents/GetBatteryStatusIntent.swift`
- Create: `Wattly/Intents/Intents/GetBatteryLimitIntent.swift`
- Create: `WattlyTests/GetBatteryIntentsTests.swift`

**Interfaces:**
- Consumes: `AppIntent`, `BatteryIntentBridge`, `BatteryStateEntity`, `BatteryLimitConfigEntity`.
- Produces: `GetBatteryStatusIntent`, `GetBatteryLimitIntent`.

- [ ] **Step 1: Write failing read intents tests**

In `WattlyTests/GetBatteryIntentsTests.swift`:

```swift
import Testing
import AppIntents
import Foundation
@testable import Wattly

@Suite struct GetBatteryIntentsTests {
    @Test func getBatteryStatusIntentPerformsAndReturnsResult() async throws {
        let intent = GetBatteryStatusIntent()
        let result = try await intent.perform()
        #expect(result.value != nil)
    }

    @Test func getBatteryLimitIntentPerformsAndReturnsResult() async throws {
        let intent = GetBatteryLimitIntent()
        let result = try await intent.perform()
        #expect(result.value != nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -derivedDataPath .derivedData -destination 'platform=macOS' -only-testing:WattlyTests/GetBatteryIntentsTests
```
Expected: FAIL due to missing `GetBatteryStatusIntent` and `GetBatteryLimitIntent`.

- [ ] **Step 3: Implement GetBatteryStatusIntent and GetBatteryLimitIntent**

In `Wattly/Intents/Intents/GetBatteryStatusIntent.swift`:

```swift
import Foundation
import AppIntents

public struct GetBatteryStatusIntent: AppIntent {
    public static var title: LocalizedStringResource = "배터리 상태 가져오기"
    public static var description: IntentDescription = IntentDescription("현재 배터리 잔량, 충전 상태, 전력, 온도 등을 조회합니다.")

    public init() {}

    public func perform() async throws -> some ReturnsValue<BatteryStateEntity> & ProvidesDialog {
        let bridge = BatteryIntentBridge.shared
        let state = try await bridge.fetchBatteryState()

        let dialogText: String
        if let temp = state.temperatureCelsius {
            dialogText = "현재 배터리 잔량은 \(state.percentage)%이며, 온도는 \(String(format: "%.1f", temp))°C입니다."
        } else {
            dialogText = "현재 배터리 잔량은 \(state.percentage)%입니다."
        }

        return .result(value: state, dialog: IntentDialog(stringLiteral: dialogText))
    }
}
```

In `Wattly/Intents/Intents/GetBatteryLimitIntent.swift`:

```swift
import Foundation
import AppIntents

public struct GetBatteryLimitIntent: AppIntent {
    public static var title: LocalizedStringResource = "충전 제한 설정 가져오기"
    public static var description: IntentDescription = IntentDescription("현재 설정된 배터리 충전 한도 및 Sailing 모드 상태를 조회합니다.")

    public init() {}

    public func perform() async throws -> some ReturnsValue<BatteryLimitConfigEntity> & ProvidesDialog {
        let bridge = BatteryIntentBridge.shared
        let config = try await bridge.fetchLimitConfig()

        let statusText = config.isEnabled ? "\(config.limitPercentage)%로 설정됨" : "비활성화됨"
        let dialogText = "배터리 충전 제한이 \(statusText)."

        return .result(value: config, dialog: IntentDialog(stringLiteral: dialogText))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -derivedDataPath .derivedData -destination 'platform=macOS' -only-testing:WattlyTests/GetBatteryIntentsTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Intents/Intents/GetBatteryStatusIntent.swift \
  Wattly/Intents/Intents/GetBatteryLimitIntent.swift \
  WattlyTests/GetBatteryIntentsTests.swift \
  Wattly.xcodeproj/project.pbxproj
git commit -m "feat(shortcuts): implement GetBatteryStatusIntent and GetBatteryLimitIntent"
```

---

### Task 4: Implement Limit & Sailing Intents (`SetBatteryLimitIntent`, `SetBatteryLimitEnabledIntent`, `SetBatterySailingIntent`)

**Files:**
- Create: `Wattly/Intents/Intents/SetBatteryLimitIntent.swift`
- Create: `Wattly/Intents/Intents/SetBatteryLimitEnabledIntent.swift`
- Create: `Wattly/Intents/Intents/SetBatterySailingIntent.swift`
- Create: `WattlyTests/SetBatteryLimitIntentsTests.swift`

**Interfaces:**
- Consumes: `AppIntent`, `BatteryIntentBridge`, `BatteryIntentError`.
- Produces: `SetBatteryLimitIntent`, `SetBatteryLimitEnabledIntent`, `SetBatterySailingIntent`.

- [ ] **Step 1: Write failing limit intents tests**

In `WattlyTests/SetBatteryLimitIntentsTests.swift`:

```swift
import Testing
import AppIntents
import Foundation
@testable import Wattly

@Suite struct SetBatteryLimitIntentsTests {
    @Test func setBatteryLimitIntentValidation() {
        var intent = SetBatteryLimitIntent()
        intent.limit = 85
        #expect(intent.limit == 85)
    }

    @Test func setBatteryLimitEnabledIntentInit() {
        var intent = SetBatteryLimitEnabledIntent()
        intent.enabled = true
        #expect(intent.enabled == true)
    }

    @Test func setBatterySailingIntentInit() {
        var intent = SetBatterySailingIntent()
        intent.enabled = true
        intent.delta = 5
        #expect(intent.enabled == true)
        #expect(intent.delta == 5)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -derivedDataPath .derivedData -destination 'platform=macOS' -only-testing:WattlyTests/SetBatteryLimitIntentsTests
```
Expected: FAIL due to missing `SetBatteryLimitIntent`, `SetBatteryLimitEnabledIntent`, and `SetBatterySailingIntent`.

- [ ] **Step 3: Implement SetBatteryLimitIntent, SetBatteryLimitEnabledIntent, and SetBatterySailingIntent**

In `Wattly/Intents/Intents/SetBatteryLimitIntent.swift`:

```swift
import Foundation
import AppIntents

public struct SetBatteryLimitIntent: AppIntent {
    public static var title: LocalizedStringResource = "충전 한도 설정"
    public static var description: IntentDescription = IntentDescription("배터리 최대 충전 한도(%)를 설정하고 충전 제한을 적용합니다.")

    @Parameter(title: "충전 한도 (%)", default: 80, inclusiveRange: 50...100)
    public var limit: Int

    @Parameter(title: "충전 제한 활성화", default: true)
    public var enableLimit: Bool

    public init() {}

    public init(limit: Int, enableLimit: Bool = true) {
        self.limit = limit
        self.enableLimit = enableLimit
    }

    public func perform() async throws -> some ProvidesDialog {
        guard limit >= 50 && limit <= 100 else {
            throw BatteryIntentError.invalidParameter("충전 한도는 50%에서 100% 사이여야 합니다.")
        }
        let bridge = BatteryIntentBridge.shared
        _ = try await bridge.applyLimit(enabled: enableLimit, limitPercentage: limit)

        let dialogText = enableLimit
            ? "배터리 충전 한도를 \(limit)%로 설정했습니다."
            : "배터리 충전 한도를 \(limit)%로 변경하고 비활성화했습니다."

        return .result(dialog: IntentDialog(stringLiteral: dialogText))
    }
}
```

In `Wattly/Intents/Intents/SetBatteryLimitEnabledIntent.swift`:

```swift
import Foundation
import AppIntents

public struct SetBatteryLimitEnabledIntent: AppIntent {
    public static var title: LocalizedStringResource = "충전 제한 켜기/끄기"
    public static var description: IntentDescription = IntentDescription("배터리 충전 제한 기능을 켜거나 끕니다.")

    @Parameter(title: "활성화 여부")
    public var enabled: Bool

    public init() {}

    public init(enabled: Bool) {
        self.enabled = enabled
    }

    public func perform() async throws -> some ProvidesDialog {
        let bridge = BatteryIntentBridge.shared
        _ = try await bridge.applyLimit(enabled: enabled)

        let dialogText = enabled ? "배터리 충전 제한을 켰습니다." : "배터리 충전 제한을 껐습니다."
        return .result(dialog: IntentDialog(stringLiteral: dialogText))
    }
}
```

In `Wattly/Intents/Intents/SetBatterySailingIntent.swift`:

```swift
import Foundation
import AppIntents

public struct SetBatterySailingIntent: AppIntent {
    public static var title: LocalizedStringResource = "Sailing 모드 설정"
    public static var description: IntentDescription = IntentDescription("충전 한도 도달 후 자연 방전 허용 범위(Sailing)를 설정합니다.")

    @Parameter(title: "Sailing 활성화")
    public var enabled: Bool

    @Parameter(title: "하한 범위 (% Delta)", default: 5, inclusiveRange: 1...10)
    public var delta: Int

    public init() {}

    public init(enabled: Bool, delta: Int = 5) {
        self.enabled = enabled
        self.delta = delta
    }

    public func perform() async throws -> some ProvidesDialog {
        guard delta >= 1 && delta <= 10 else {
            throw BatteryIntentError.invalidParameter("Sailing 범위는 1%에서 10% 사이여야 합니다.")
        }
        let bridge = BatteryIntentBridge.shared
        _ = try await bridge.applySailing(enabled: enabled, delta: delta)

        let dialogText = enabled
            ? "Sailing 모드를 켰습니다 (범위: \(delta)%)."
            : "Sailing 모드를 껐습니다."

        return .result(dialog: IntentDialog(stringLiteral: dialogText))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -derivedDataPath .derivedData -destination 'platform=macOS' -only-testing:WattlyTests/SetBatteryLimitIntentsTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Intents/Intents/SetBatteryLimitIntent.swift \
  Wattly/Intents/Intents/SetBatteryLimitEnabledIntent.swift \
  Wattly/Intents/Intents/SetBatterySailingIntent.swift \
  WattlyTests/SetBatteryLimitIntentsTests.swift \
  Wattly.xcodeproj/project.pbxproj
git commit -m "feat(shortcuts): implement SetBatteryLimit, SetBatteryLimitEnabled, and SetBatterySailing intents"
```

---

### Task 5: Implement Top Up & Heat Protection Intents (`SetBatteryTopUpIntent`, `SetBatteryHeatProtectionIntent`)

**Files:**
- Create: `Wattly/Intents/Intents/SetBatteryTopUpIntent.swift`
- Create: `Wattly/Intents/Intents/SetBatteryHeatProtectionIntent.swift`
- Create: `WattlyTests/SpecialBatteryIntentsTests.swift`

**Interfaces:**
- Consumes: `AppIntent`, `BatteryIntentBridge`, `BatteryIntentError`.
- Produces: `SetBatteryTopUpIntent`, `SetBatteryHeatProtectionIntent`.

- [ ] **Step 1: Write failing special battery intents tests**

In `WattlyTests/SpecialBatteryIntentsTests.swift`:

```swift
import Testing
import AppIntents
import Foundation
@testable import Wattly

@Suite struct SpecialBatteryIntentsTests {
    @Test func setBatteryTopUpIntentInit() {
        var startIntent = SetBatteryTopUpIntent()
        startIntent.start = true
        #expect(startIntent.start == true)

        var cancelIntent = SetBatteryTopUpIntent()
        cancelIntent.start = false
        #expect(cancelIntent.start == false)
    }

    @Test func setBatteryHeatProtectionIntentInit() {
        var intent = SetBatteryHeatProtectionIntent()
        intent.enabled = true
        intent.thresholdCelsius = 35
        #expect(intent.enabled == true)
        #expect(intent.thresholdCelsius == 35)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -derivedDataPath .derivedData -destination 'platform=macOS' -only-testing:WattlyTests/SpecialBatteryIntentsTests
```
Expected: FAIL due to missing `SetBatteryTopUpIntent` and `SetBatteryHeatProtectionIntent`.

- [ ] **Step 3: Implement SetBatteryTopUpIntent and SetBatteryHeatProtectionIntent**

In `Wattly/Intents/Intents/SetBatteryTopUpIntent.swift`:

```swift
import Foundation
import AppIntents

public struct SetBatteryTopUpIntent: AppIntent {
    public static var title: LocalizedStringResource = "한 번만 완충 (Top Up)"
    public static var description: IntentDescription = IntentDescription("다음 외출을 위해 배터리를 100%까지 1회성으로 완전 충전합니다.")

    @Parameter(title: "완충 시작 여부 (false는 취소)", default: true)
    public var start: Bool

    public init() {}

    public init(start: Bool) {
        self.start = start
    }

    public func perform() async throws -> some ProvidesDialog {
        let bridge = BatteryIntentBridge.shared
        _ = try await bridge.applyTopUp(start: start)

        let dialogText = start
            ? "한 번만 완충을 시작했습니다 (100% 도달 후 어댑터 분리 시 원래 한도로 복귀)."
            : "한 번만 완충을 취소하고 원래 충전 한도로 복귀했습니다."

        return .result(dialog: IntentDialog(stringLiteral: dialogText))
    }
}
```

In `Wattly/Intents/Intents/SetBatteryHeatProtectionIntent.swift`:

```swift
import Foundation
import AppIntents

public struct SetBatteryHeatProtectionIntent: AppIntent {
    public static var title: LocalizedStringResource = "발열 보호 설정"
    public static var description: IntentDescription = IntentDescription("배터리 과열 방지를 위해 임계 온도 도달 시 충전을 일시 중단합니다.")

    @Parameter(title: "발열 보호 활성화")
    public var enabled: Bool

    @Parameter(title: "임계 온도 (°C)", default: 35, inclusiveRange: 30...45)
    public var thresholdCelsius: Int

    public init() {}

    public init(enabled: Bool, thresholdCelsius: Int = 35) {
        self.enabled = enabled
        self.thresholdCelsius = thresholdCelsius
    }

    public func perform() async throws -> some ProvidesDialog {
        guard thresholdCelsius >= 30 && thresholdCelsius <= 45 else {
            throw BatteryIntentError.invalidParameter("발열 보호 온도는 30°C에서 45°C 사이여야 합니다.")
        }
        let bridge = BatteryIntentBridge.shared
        _ = try await bridge.applyHeatProtection(enabled: enabled, thresholdCelsius: thresholdCelsius)

        let dialogText = enabled
            ? "발열 보호를 켰습니다 (임계 온도: \(thresholdCelsius)°C)."
            : "발열 보호를 껐습니다."

        return .result(dialog: IntentDialog(stringLiteral: dialogText))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -derivedDataPath .derivedData -destination 'platform=macOS' -only-testing:WattlyTests/SpecialBatteryIntentsTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Intents/Intents/SetBatteryTopUpIntent.swift \
  Wattly/Intents/Intents/SetBatteryHeatProtectionIntent.swift \
  WattlyTests/SpecialBatteryIntentsTests.swift \
  Wattly.xcodeproj/project.pbxproj
git commit -m "feat(shortcuts): implement SetBatteryTopUp and SetBatteryHeatProtection intents"
```

---

### Task 6: Implement AppShortcutsProvider, Localization, and Integration Verification

**Files:**
- Create: `Wattly/Intents/WattlyShortcuts.swift`
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Create: `WattlyTests/WattlyShortcutsTests.swift`

**Interfaces:**
- Consumes: `AppShortcutsProvider`, all created `AppIntent`s.
- Produces: `WattlyShortcuts` provider exposing predefined Siri phrases and Shortcuts app templates.

- [ ] **Step 1: Write shortcuts provider test**

In `WattlyTests/WattlyShortcutsTests.swift`:

```swift
import Testing
import AppIntents
import Foundation
@testable import Wattly

@Suite struct WattlyShortcutsTests {
    @Test func appShortcutsContainStandardIntents() {
        let shortcuts = WattlyShortcuts.appShortcuts
        #expect(!shortcuts.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -derivedDataPath .derivedData -destination 'platform=macOS' -only-testing:WattlyTests/WattlyShortcutsTests
```
Expected: FAIL due to missing `WattlyShortcuts`.

- [ ] **Step 3: Implement WattlyShortcuts and update Localizable.xcstrings**

In `Wattly/Intents/WattlyShortcuts.swift`:

```swift
import Foundation
import AppIntents

public struct WattlyShortcuts: AppShortcutsProvider {
    public static var shortcutTileColor: ShortcutTileColor = .orange

    @AppShortcutsBuilder
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetBatteryStatusIntent(),
            phrases: [
                "\(.applicationName)에서 배터리 상태 확인",
                "\(.applicationName) 배터리 상태",
                "Get battery status in \(.applicationName)"
            ],
            shortTitle: "배터리 상태",
            systemImageName: "battery.100.bolt"
        )
        AppShortcut(
            intent: SetBatteryTopUpIntent(start: true),
            phrases: [
                "\(.applicationName)에서 완충 시작",
                "\(.applicationName) 한 번만 완충",
                "Top Up battery in \(.applicationName)"
            ],
            shortTitle: "한 번만 완충 시작",
            systemImageName: "bolt.fill"
        )
        AppShortcut(
            intent: SetBatteryLimitEnabledIntent(enabled: true),
            phrases: [
                "\(.applicationName) 충전 제한 켜기",
                "Turn on battery limit in \(.applicationName)"
            ],
            shortTitle: "충전 제한 켜기",
            systemImageName: "battery.75"
        )
    }
}
```

Update `Wattly/Resources/Localizable.xcstrings` to include localized translations for Shortcuts phrases, intent titles, parameters, and dialogs.

- [ ] **Step 4: Run all tests to verify full pass**

Run:
```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -derivedDataPath .derivedData -destination 'platform=macOS'
```
Expected: 100% PASS across all suites.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Intents/WattlyShortcuts.swift \
  Wattly/Resources/Localizable.xcstrings \
  WattlyTests/WattlyShortcutsTests.swift \
  Wattly.xcodeproj/project.pbxproj
git commit -m "feat(shortcuts): register WattlyShortcuts AppShortcutsProvider and localizations"
```

---

## Verification Plan

### Automated Tests
- Run test suite: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -derivedDataPath .derivedData -destination 'platform=macOS'`
- Specific new test suites:
  - `WattlyTests/BatteryIntentEntityTests`
  - `WattlyTests/BatteryIntentBridgeTests`
  - `WattlyTests/GetBatteryIntentsTests`
  - `WattlyTests/SetBatteryLimitIntentsTests`
  - `WattlyTests/SpecialBatteryIntentsTests`
  - `WattlyTests/WattlyShortcutsTests`

### Manual Verification
1. Build and run Wattly app in Xcode or via `open .derivedData/Build/Products/Debug/Wattly.app`.
2. Open macOS **Shortcuts (단축어)** app.
3. Verify that **Wattly** actions appear in the action library:
   - "배터리 상태 가져오기"
   - "충전 제한 설정 가져오기"
   - "충전 한도 설정"
   - "충전 제한 켜기/끄기"
   - "Sailing 모드 설정"
   - "한 번만 완충 (Top Up)"
   - "발열 보호 설정"
4. Create a test shortcut executing "배터리 상태 가져오기" and verify output.
5. Create a test shortcut executing "충전 한도 설정" to 85% and verify Wattly GUI settings immediately update to 85%.
