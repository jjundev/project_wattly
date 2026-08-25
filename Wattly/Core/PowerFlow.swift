import Foundation

/// 5가지 전력 흐름 시나리오
public enum PowerFlowScenario: String, Sendable, Equatable, CaseIterable {
    /// 1. 어댑터가 시스템 공급 및 배터리 충전
    case charging
    /// 2. 어댑터가 시스템만 직결 공급하고 배터리는 유휴 대기 (상한 유지 / Sailing)
    case adapterBypass
    /// 3. 배터리만으로 시스템 단독 구동
    case batteryOnly
    /// 4. 어댑터 연결 상태에서 충전 억제 후 능동 방전
    case activeDischarge
    /// 5. 어댑터 출력 부족으로 배터리가 보조 방전 (Power Assist)
    case powerAssist
}

/// 단일 시점의 전력 흐름 텔레메트리 스냅샷
public struct PowerFlowSnapshot: Sendable, Equatable {
    public let scenario: PowerFlowScenario
    public let adapterWatts: Double
    public let systemWatts: Double
    public let batteryNetWatts: Double
    public let isSynchronized: Bool

    public init(
        scenario: PowerFlowScenario,
        adapterWatts: Double,
        systemWatts: Double,
        batteryNetWatts: Double,
        isSynchronized: Bool = true
    ) {
        self.scenario = scenario
        self.adapterWatts = adapterWatts
        self.systemWatts = systemWatts
        self.batteryNetWatts = batteryNetWatts
        self.isSynchronized = isSynchronized
    }
}

/// 전원 연결 상태, 어댑터 전력, 배터리 순전력, 충전 억제 여부로부터 전력 흐름 시나리오 판정
public func resolvePowerFlowScenario(
    externalConnected: Bool,
    adapterWatts: Double,
    batteryNetWatts: Double,
    isChargeInhibited: Bool
) -> PowerFlowScenario {
    guard externalConnected else {
        return .batteryOnly
    }

    if isChargeInhibited && batteryNetWatts > 0.2 {
        return .activeDischarge
    }

    if batteryNetWatts < -0.2 {
        return .charging
    }

    if abs(batteryNetWatts) <= 0.2 {
        return .adapterBypass
    }

    // batteryNetWatts > 0.2 on AC without inhibition
    if adapterWatts > 0.5 {
        return .powerAssist
    } else {
        return .activeDischarge
    }
}

/// 시스템 총 소비 전력 계산 (측정 센서 PSTR 우선, 미지원 시 에너지 평형 방정식으로 계산)
public func calculateSystemWatts(
    adapterWatts: Double,
    batteryNetWatts: Double,
    measuredSystemWatts: Double?
) -> Double {
    if let measured = measuredSystemWatts, measured > 0.0, measured.isFinite {
        return measured
    }
    // Energy balance: P_system = P_adapter + P_batteryDischarge - P_batteryCharge
    // Since batteryNetWatts > 0 is discharging and < 0 is charging:
    // P_system = adapterWatts + batteryNetWatts
    let calculated = adapterWatts + batteryNetWatts
    return max(0.0, calculated)
}
