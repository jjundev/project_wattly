// Wattly/Core/BatteryPreferences.swift
import Foundation

/// 사용자가 저장한 배터리 제어 선호값 전부. 읽기(존재 가드 + 기본값), 쓰기(바뀐 키만),
/// 데몬 설정으로의 변환(Sailing 규칙, 방전 목표 클램프)이 여기 한 곳에만 있다.
/// 브리지·스케줄·Shortcuts·캘리브레이션·재설치는 모두 이 타입을 지나 `BatteryControlConfiguration`을 만든다.
struct BatteryPreferences: Equatable, Sendable {
    var limitEnabled: Bool
    var limitPercentage: Int
    var sailingEnabled: Bool
    var sailingDelta: Int
    var heatProtectionEnabled: Bool
    var heatProtectionThresholdCelsius: Int
    var autoDischargeEnabled: Bool
    var manualDischargeTarget: Int
    var clamshellDischargeEnabled: Bool

    static let standard = BatteryPreferences(
        limitEnabled: Defaults.batteryLimitEnabled,
        limitPercentage: Defaults.batteryLimitPercentage,
        sailingEnabled: Defaults.batterySailingEnabled,
        sailingDelta: Defaults.batterySailingDelta,
        heatProtectionEnabled: Defaults.batteryHeatProtectionEnabled,
        heatProtectionThresholdCelsius: Defaults.batteryHeatProtectionThreshold,
        autoDischargeEnabled: Defaults.batteryAutoDischargeEnabled,
        manualDischargeTarget: Defaults.batteryManualDischargeTarget,
        clamshellDischargeEnabled: Defaults.batteryClamshellDischargeEnabled)

    init(
        limitEnabled: Bool, limitPercentage: Int,
        sailingEnabled: Bool, sailingDelta: Int,
        heatProtectionEnabled: Bool, heatProtectionThresholdCelsius: Int,
        autoDischargeEnabled: Bool, manualDischargeTarget: Int,
        clamshellDischargeEnabled: Bool
    ) {
        self.limitEnabled = limitEnabled
        self.limitPercentage = limitPercentage
        self.sailingEnabled = sailingEnabled
        self.sailingDelta = sailingDelta
        self.heatProtectionEnabled = heatProtectionEnabled
        self.heatProtectionThresholdCelsius = heatProtectionThresholdCelsius
        self.autoDischargeEnabled = autoDischargeEnabled
        self.manualDischargeTarget = manualDischargeTarget
        self.clamshellDischargeEnabled = clamshellDischargeEnabled
    }

    /// `@AppStorage`는 기본값을 저장하지 않으므로 없는 키는 `Defaults`로 읽는다.
    init(defaults: UserDefaults) {
        let d = Self.standard
        limitEnabled = defaults.wattlyBool(StorageKey.batteryLimitEnabled, default: d.limitEnabled)
        limitPercentage = defaults.wattlyInt(StorageKey.batteryLimitPercentage, default: d.limitPercentage)
        sailingEnabled = defaults.wattlyBool(StorageKey.batterySailingEnabled, default: d.sailingEnabled)
        sailingDelta = defaults.wattlyInt(StorageKey.batterySailingDelta, default: d.sailingDelta)
        heatProtectionEnabled = defaults.wattlyBool(StorageKey.batteryHeatProtectionEnabled, default: d.heatProtectionEnabled)
        heatProtectionThresholdCelsius = defaults.wattlyInt(StorageKey.batteryHeatProtectionThreshold, default: d.heatProtectionThresholdCelsius)
        autoDischargeEnabled = defaults.wattlyBool(StorageKey.batteryAutoDischargeEnabled, default: d.autoDischargeEnabled)
        manualDischargeTarget = defaults.wattlyInt(StorageKey.batteryManualDischargeTarget, default: d.manualDischargeTarget)
        clamshellDischargeEnabled = defaults.wattlyBool(StorageKey.batteryClamshellDischargeEnabled, default: d.clamshellDischargeEnabled)
    }

    /// 바뀐 키만 쓴다. 안 바뀐 키까지 쓰면 `@AppStorage` 관찰자들이 헛되이 깨어난다.
    func write(to defaults: UserDefaults) {
        let current = BatteryPreferences(defaults: defaults)
        func put<T: Equatable>(_ new: T, _ old: T, _ key: String) {
            if new != old { defaults.set(new, forKey: key) }
        }
        put(limitEnabled, current.limitEnabled, StorageKey.batteryLimitEnabled)
        put(limitPercentage, current.limitPercentage, StorageKey.batteryLimitPercentage)
        put(sailingEnabled, current.sailingEnabled, StorageKey.batterySailingEnabled)
        put(sailingDelta, current.sailingDelta, StorageKey.batterySailingDelta)
        put(heatProtectionEnabled, current.heatProtectionEnabled, StorageKey.batteryHeatProtectionEnabled)
        put(heatProtectionThresholdCelsius, current.heatProtectionThresholdCelsius, StorageKey.batteryHeatProtectionThreshold)
        put(autoDischargeEnabled, current.autoDischargeEnabled, StorageKey.batteryAutoDischargeEnabled)
        put(manualDischargeTarget, current.manualDischargeTarget, StorageKey.batteryManualDischargeTarget)
        put(clamshellDischargeEnabled, current.clamshellDischargeEnabled, StorageKey.batteryClamshellDischargeEnabled)
    }

    /// Sailing이 꺼져 있으면 데몬 기본 2포인트 히스테리시스.
    var effectiveHysteresisDelta: Int { sailingEnabled ? sailingDelta : 2 }

    /// 데몬으로 나가는 유일한 조립 규칙. 활동 플래그(topUp/manualDischarge/calibration)는 여기서 세우지 않는다 —
    /// 그건 데몬 상태에서 `preservingActivity`/`revivedConfiguration`이 되살린다.
    func configuration(clamshellDischargeAllowed: Bool) -> BatteryControlConfiguration {
        BatteryControlConfiguration(
            enabled: limitEnabled,
            limitPercentage: limitPercentage,
            lowerHysteresisDelta: effectiveHysteresisDelta,
            heatProtectionEnabled: heatProtectionEnabled,
            heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
            autoDischargeEnabled: autoDischargeEnabled,
            manualDischargeTarget: BatterySectionPresentation.clampedManualDischargeTarget(manualDischargeTarget),
            clamshellDischargeAllowed: clamshellDischargeAllowed)
    }

    /// 캘리브레이션 원복용 원값. 클램프하지 않는다.
    var calibrationSnapshot: CalibrationSnapshot {
        CalibrationSnapshot(
            limitEnabled: limitEnabled,
            limitPercentage: limitPercentage,
            sailingEnabled: sailingEnabled,
            sailingDelta: sailingDelta,
            heatProtectionEnabled: heatProtectionEnabled,
            heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
            autoDischargeEnabled: autoDischargeEnabled,
            manualDischargeTarget: manualDischargeTarget)
    }
}

extension UserDefaults {
    /// `bool(forKey:)`는 없는 키에 false를 준다. 기본값이 true인 키에는 반드시 이걸 쓴다.
    func wattlyBool(_ key: String, default fallback: Bool) -> Bool {
        object(forKey: key) != nil ? bool(forKey: key) : fallback
    }

    /// `integer(forKey:)`는 없는 키에 0을 준다. 0이 유효값이 아닌 모든 키에 이걸 쓴다.
    func wattlyInt(_ key: String, default fallback: Int) -> Int {
        object(forKey: key) != nil ? integer(forKey: key) : fallback
    }
}
