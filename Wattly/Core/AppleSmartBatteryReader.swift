import Foundation
import IOKit

/// 캘리브레이션 코디네이터가 한 tick에 필요한 배터리 사실들.
struct CalibrationBatteryReading: Equatable, Sendable {
    /// SMC `B0AP` 기준 순전력(W). 양수 = 방전, 음수 = 충전. ETA 추정에만 쓴다 —
    /// 단계 전이 판정에는 쓰지 않는다(테이퍼가 절벽이라 임계값이 무의미하다).
    var netWatts: Double?
    /// 레지스트리 `IsCharging`. 완충 판정의 절반이다(`FullyCharged`는 완충 후에도 `No`).
    var isCharging: Bool?
    /// `AdapterDetails.Watts`. **어댑터 판정의 진실은 이 값 하나다** — CHIE 강제 방전 중
    /// `ExternalConnected`도 IOPS도 "배터리 전원"이라고 보고한다(실기 3회 재현).
    var adapterWatts: Int?
    /// `ChargingCurrent`. 외부 요인이 충전을 막고 있는지 판정한다.
    var chargingCurrentMilliamps: Int?
    var maxCapacityMilliampHours: Int?
    var designCapacityMilliampHours: Int?
    var cycleCount: Int?

    init(
        netWatts: Double? = nil,
        isCharging: Bool? = nil,
        adapterWatts: Int? = nil,
        chargingCurrentMilliamps: Int? = nil,
        maxCapacityMilliampHours: Int? = nil,
        designCapacityMilliampHours: Int? = nil,
        cycleCount: Int? = nil
    ) {
        self.netWatts = netWatts
        self.isCharging = isCharging
        self.adapterWatts = adapterWatts
        self.chargingCurrentMilliamps = chargingCurrentMilliamps
        self.maxCapacityMilliampHours = maxCapacityMilliampHours
        self.designCapacityMilliampHours = designCapacityMilliampHours
        self.cycleCount = cycleCount
    }

    var isAdapterPresent: Bool { (adapterWatts ?? 0) > 0 }

    /// 어댑터는 붙어 있는데 충전 전류가 바닥이다. 판독 실패(`nil`)는 정체가 아니다.
    var isChargeStalled: Bool {
        guard isAdapterPresent, let current = chargingCurrentMilliamps else { return false }
        return current < BatteryCalibration.chargeStallMilliamps
    }
}

/// 폴링 정책과 무관하게 배터리를 직접 읽는다.
///
/// `BatteryProvider`를 리팩터링해 공유하지 않는 이유: 순수 디코딩 함수(`BatteryPower.swift`)는
/// 이미 공유되고 있고 중복되는 것은 IOKit 배선뿐이다. 프로바이더를 건드리면 기존 배터리
/// 테스트 전체가 회귀 위험에 노출된다. SMC 연결은 읽기 전용이라 두 개가 공존해도 안전하다.
actor AppleSmartBatteryReader {
    private var smcAttempted = false
    private var smc: SMCConnection?

    func read() -> CalibrationBatteryReading {
        var reading = CalibrationBatteryReading()

        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            reading.isCharging = bool(service, "IsCharging")
            reading.adapterWatts = (dict(service, "AdapterDetails")?["Watts"] as? NSNumber)?.intValue
            reading.chargingCurrentMilliamps = number(service, "ChargingCurrent")?.intValue
            reading.maxCapacityMilliampHours = number(service, "AppleRawMaxCapacity")?.intValue
            reading.designCapacityMilliampHours = number(service, "DesignCapacity")?.intValue
            reading.cycleCount = number(service, "CycleCount")?.intValue
        }

        if !smcAttempted { smcAttempted = true; smc = SMCConnection() }
        if let smc, let power = smc.read("B0AP") {
            let milliwatts = Int(smcDouble(power.bytes, type: power.type).rounded())
            reading.netWatts = netWatts(batteryMilliwatts: milliwatts)
        }
        return reading
    }

    private func number(_ service: io_service_t, _ key: String) -> NSNumber? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber
    }
    private func bool(_ service: io_service_t, _ key: String) -> Bool? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }
    private func dict(_ service: io_service_t, _ key: String) -> [String: Any]? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
    }
}
