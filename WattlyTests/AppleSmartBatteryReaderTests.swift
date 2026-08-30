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
