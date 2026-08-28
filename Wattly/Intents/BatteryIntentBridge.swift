import Foundation
import AppKit

public final class BatteryIntentBridge: @unchecked Sendable {
    public static let shared = BatteryIntentBridge()

    private let userDefaults: UserDefaults
    private let clientProvider: @Sendable @MainActor () -> BatteryControlClient
    private let batteryProvider: any MetricProvider

    public init(
        userDefaults: UserDefaults = .standard,
        clientProvider: (@Sendable @MainActor () -> BatteryControlClient)? = nil
    ) {
        self.userDefaults = userDefaults
        self.clientProvider = clientProvider ?? { BatteryControlClient() }
        self.batteryProvider = BatteryProvider()
    }

    init(
        userDefaults: UserDefaults = .standard,
        clientProvider: (@Sendable @MainActor () -> BatteryControlClient)? = nil,
        batteryProvider: any MetricProvider
    ) {
        self.userDefaults = userDefaults
        self.clientProvider = clientProvider ?? { BatteryControlClient() }
        self.batteryProvider = batteryProvider
    }

    public func fetchBatteryState() async throws -> BatteryStateEntity {
        let reading = await batteryProvider.read(at: ContinuousClock.Instant.now)
        let client = await clientProvider()
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
                if let rem = sample.remainingWh, let max = sample.maxWh, max > 0 {
                    percentage = Int((rem / max * 100.0).rounded())
                }
            }
            isCharging = sample.charging
            isPluggedIn = sample.externalConnected
            if temp == nil { temp = sample.temperatureCelsius }
            netW = sample.netW
            timeRemaining = sample.timeRemainingMinutes
            if let efficiency = sample.efficiencyPercent {
                health = Int(efficiency.rounded())
            }
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

        let client = await clientProvider()
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
        let autoDischargeEnabled = userDefaults.object(forKey: StorageKey.batteryAutoDischargeEnabled) != nil
            ? userDefaults.bool(forKey: StorageKey.batteryAutoDischargeEnabled)
            : Defaults.batteryAutoDischargeEnabled
        let manualDischargeTarget = userDefaults.object(forKey: StorageKey.batteryManualDischargeTarget) != nil
            ? userDefaults.integer(forKey: StorageKey.batteryManualDischargeTarget)
            : Defaults.batteryManualDischargeTarget

        let newEnabled = enabled ?? curEnabled
        let newLimit = limitPercentage ?? curLimit
        let delta = sailingEnabled ? sailingDelta : 2

        let client = await clientProvider()
        guard let status = await client.apply(
            enabled: newEnabled,
            limitPercentage: newLimit,
            lowerHysteresisDelta: delta,
            heatProtectionEnabled: heatEnabled,
            heatProtectionThresholdCelsius: heatThreshold,
            autoDischargeEnabled: autoDischargeEnabled,
            manualDischargeTarget: manualDischargeTarget
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
        let autoDischargeEnabled = userDefaults.object(forKey: StorageKey.batteryAutoDischargeEnabled) != nil
            ? userDefaults.bool(forKey: StorageKey.batteryAutoDischargeEnabled)
            : Defaults.batteryAutoDischargeEnabled
        let manualDischargeTarget = userDefaults.object(forKey: StorageKey.batteryManualDischargeTarget) != nil
            ? userDefaults.integer(forKey: StorageKey.batteryManualDischargeTarget)
            : Defaults.batteryManualDischargeTarget

        let newDelta = delta ?? curDelta
        let effectiveDelta = enabled ? newDelta : 2

        let client = await clientProvider()
        guard let status = await client.apply(
            enabled: curEnabled,
            limitPercentage: curLimit,
            lowerHysteresisDelta: effectiveDelta,
            heatProtectionEnabled: heatEnabled,
            heatProtectionThresholdCelsius: heatThreshold,
            autoDischargeEnabled: autoDischargeEnabled,
            manualDischargeTarget: manualDischargeTarget
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
        let autoDischargeEnabled = userDefaults.object(forKey: StorageKey.batteryAutoDischargeEnabled) != nil
            ? userDefaults.bool(forKey: StorageKey.batteryAutoDischargeEnabled)
            : Defaults.batteryAutoDischargeEnabled
        let manualDischargeTarget = userDefaults.object(forKey: StorageKey.batteryManualDischargeTarget) != nil
            ? userDefaults.integer(forKey: StorageKey.batteryManualDischargeTarget)
            : Defaults.batteryManualDischargeTarget
        let delta = sailingEnabled ? sailingDelta : 2

        let client = await clientProvider()
        let status: BatteryControlServiceStatus?
        if start {
            status = await client.startTopUp(
                limitPercentage: curLimit,
                lowerHysteresisDelta: delta,
                heatProtectionEnabled: heatEnabled,
                heatProtectionThresholdCelsius: heatThreshold,
                autoDischargeEnabled: autoDischargeEnabled,
                manualDischargeTarget: manualDischargeTarget
            )
        } else {
            status = await client.cancelTopUp(
                limitPercentage: curLimit,
                lowerHysteresisDelta: delta,
                heatProtectionEnabled: heatEnabled,
                heatProtectionThresholdCelsius: heatThreshold,
                autoDischargeEnabled: autoDischargeEnabled,
                manualDischargeTarget: manualDischargeTarget
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
        let autoDischargeEnabled = userDefaults.object(forKey: StorageKey.batteryAutoDischargeEnabled) != nil
            ? userDefaults.bool(forKey: StorageKey.batteryAutoDischargeEnabled)
            : Defaults.batteryAutoDischargeEnabled
        let manualDischargeTarget = userDefaults.object(forKey: StorageKey.batteryManualDischargeTarget) != nil
            ? userDefaults.integer(forKey: StorageKey.batteryManualDischargeTarget)
            : Defaults.batteryManualDischargeTarget

        let newThreshold = thresholdCelsius ?? curThreshold
        let delta = sailingEnabled ? sailingDelta : 2

        let client = await clientProvider()
        guard let status = await client.apply(
            enabled: limitEnabled,
            limitPercentage: curLimit,
            lowerHysteresisDelta: delta,
            heatProtectionEnabled: enabled,
            heatProtectionThresholdCelsius: newThreshold,
            autoDischargeEnabled: autoDischargeEnabled,
            manualDischargeTarget: manualDischargeTarget
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
