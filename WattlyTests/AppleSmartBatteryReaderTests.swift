import Foundation
import Testing
@testable import Wattly

struct AppleSmartBatteryReaderTests {
    @Test func adapterPresenceComesFromWattsNotFromExternalConnected() {
        // CHIE 강제 방전 중 실측: ExternalConnected=No, IOPS=Battery Power, Watts=68.
        // 어댑터 판정을 Watts로 하지 않으면 방전이 정상 작동하는 순간에 절차가 스스로
        // 일시정지한다.
        var reading = CalibrationBatteryReading()
        reading.adapterWatts = 68
        #expect(reading.isAdapterPresent)

        reading.adapterWatts = 0
        #expect(reading.isAdapterPresent == false)

        reading.adapterWatts = nil
        #expect(reading.isAdapterPresent == false)
    }

    @Test func chargeStallUsesTheMeasuredCurrentThreshold() {
        var reading = CalibrationBatteryReading()
        reading.adapterWatts = 68
        reading.chargingCurrentMilliamps = 100      // 실측: 최적화된 배터리 충전이 켜졌을 때
        #expect(reading.isChargeStalled)

        reading.chargingCurrentMilliamps = 2500
        #expect(reading.isChargeStalled == false)

        // 전류를 못 읽으면 정체라고 단정하지 않는다 — 판독 실패로 절차를 세우면 안 된다.
        reading.chargingCurrentMilliamps = nil
        #expect(reading.isChargeStalled == false)
    }

    @Test func chargingCurrentPrefersRegistryThenClampsSMCCurrent() {
        // macOS 26 이하: 레지스트리 `ChargingCurrent`(설정 전류)가 그대로 이긴다.
        #expect(CalibrationBatteryReading.chargingCurrent(registry: 100, smcBatteryCurrent: 3265) == 100)
        // macOS 27: 레지스트리가 없으면 SMC `B0AC` 실전류. 충전 중 양수는 그대로.
        #expect(CalibrationBatteryReading.chargingCurrent(registry: nil, smcBatteryCurrent: 3265) == 3265)
        // 방전 중(음수)은 "충전 전류 0" — 게이트가 열렸는데 안 들어오면 정체로 보여야 한다.
        #expect(CalibrationBatteryReading.chargingCurrent(registry: nil, smcBatteryCurrent: -2030) == 0)
        // 둘 다 없으면 nil — 판독 실패를 정체로 단정하지 않는다(isChargeStalled == false).
        #expect(CalibrationBatteryReading.chargingCurrent(registry: nil, smcBatteryCurrent: nil) == nil)
    }

    @Test func liveReadEitherAnswersOrDegradesToNils() async {
        // 실제 하드웨어 판독은 CI 환경(배터리 없는 Mac 포함)에서 값이 달라진다. 검증할 수 있는
        // 계약은 "크래시하지 않고, 못 읽은 항목은 nil로 남는다" 하나다.
        let reading = await AppleSmartBatteryReader().read()
        if let cycles = reading.cycleCount { #expect(cycles >= 0) }
        if let capacity = reading.maxCapacityMilliampHours { #expect(capacity > 0) }

        // Unconditional assertion: verify second read completes and returns consistent shape
        let reading2 = await AppleSmartBatteryReader().read()
        #expect((reading2.adapterWatts == nil || reading2.adapterWatts! >= 0))
    }
}
