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
        let prefs = BatteryPreferences(defaults: userDefaults)
        let client = await clientProvider()
        let status = await client.refreshStatus()
        let isTopUp = status?.desiredConfiguration?.topUpActive == true || status?.activity == .topUp
        return BatteryLimitConfigEntity(
            isEnabled: prefs.limitEnabled,
            limitPercentage: prefs.limitPercentage,
            isSailingEnabled: prefs.sailingEnabled,
            sailingDelta: prefs.sailingDelta,
            isHeatProtectionEnabled: prefs.heatProtectionEnabled,
            isTopUpActive: isTopUp)
    }

    @discardableResult
    public func applyLimit(enabled: Bool? = nil, limitPercentage: Int? = nil) async throws -> BatteryControlServiceStatus {
        try await push { prefs in
            if let enabled { prefs.limitEnabled = enabled }
            if let limitPercentage { prefs.limitPercentage = limitPercentage }
        }
    }

    @discardableResult
    public func applySailing(enabled: Bool, delta: Int? = nil) async throws -> BatteryControlServiceStatus {
        try await push { prefs in
            prefs.sailingEnabled = enabled
            if let delta { prefs.sailingDelta = delta }
        }
    }

    @discardableResult
    public func applyTopUp(start: Bool) async throws -> BatteryControlServiceStatus {
        let prefs = BatteryPreferences(defaults: userDefaults)
        let client = await clientProvider()
        let status = start
            ? await client.startTopUp(preferences: prefs)
            : await client.cancelTopUp(preferences: prefs)
        return try Self.checked(status)
    }

    @discardableResult
    public func applyHeatProtection(enabled: Bool, thresholdCelsius: Int? = nil) async throws -> BatteryControlServiceStatus {
        try await push { prefs in
            prefs.heatProtectionEnabled = enabled
            if let thresholdCelsius { prefs.heatProtectionThresholdCelsius = thresholdCelsius }
        }
    }

    /// 설정 → 데몬 → 저장. 데몬이 거부하면 저장하지 않는다(예전 동작과 같다). 저장은 브리지를 깨워
    /// 같은 설정을 한 번 더 밀게 하지만, 데몬 `configure`는 멱등이고 인텐트는 분 단위 이벤트라 받아들인다.
    ///
    /// 값이 아니라 **변경 함수**를 받는다. XPC 왕복은 사용자가 슬라이더를 움직일 수 있는 시간이고,
    /// `write(to:)`는 넘겨받은 값 전체를 저장소와 대조해 다른 키를 전부 덮어쓴다. 왕복 전에 읽은
    /// 스냅샷을 그대로 쓰면 그 사이 사용자가 바꾼 한도가 옛 값으로 되돌아간다(`@AppStorage`가
    /// 관찰하므로 슬라이더가 눈앞에서 튕긴다). 그래서 저장 직전에 저장소를 **다시 읽고** 같은
    /// 변경만 다시 얹는다 — 인텐트가 실제로 건드린 필드만 남고 나머지는 사용자 값을 유지한다.
    /// 그러려면 변경 함수가 순수해야 한다(두 번 실행된다).
    private func push(
        _ mutate: (inout BatteryPreferences) -> Void
    ) async throws -> BatteryControlServiceStatus {
        var outgoing = BatteryPreferences(defaults: userDefaults)
        mutate(&outgoing)
        let client = await clientProvider()
        let status = try Self.checked(await client.apply(outgoing.configuration(clamshellDischargeAllowed: false)))
        var persisted = BatteryPreferences(defaults: userDefaults)
        mutate(&persisted)
        persisted.write(to: userDefaults)
        return status
    }

    private static func checked(_ status: BatteryControlServiceStatus?) throws -> BatteryControlServiceStatus {
        guard let status else { throw BatteryIntentError.helperNotInstalled }
        if status.mode == .unsupported || status.isHardwareSupported == false {
            throw BatteryIntentError.hardwareUnsupported
        }
        return status
    }
}
