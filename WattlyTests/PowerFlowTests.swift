import XCTest
@testable import Wattly

final class PowerFlowTests: XCTestCase {
    func testBatteryOnlyScenarioWhenUnplugged() {
        let scenario = resolvePowerFlowScenario(
            externalConnected: false,
            adapterWatts: 0.0,
            batteryNetWatts: 14.5,
            isChargeInhibited: false
        )
        XCTAssertEqual(scenario, .batteryOnly)
    }

    func testChargingScenarioWhenAdapterSuppliesSystemAndBattery() {
        let scenario = resolvePowerFlowScenario(
            externalConnected: true,
            adapterWatts: 48.5,
            batteryNetWatts: -32.4, // negative = charging
            isChargeInhibited: false
        )
        XCTAssertEqual(scenario, .charging)
    }

    func testAdapterBypassScenarioWhenBatteryIsIdle() {
        let scenario = resolvePowerFlowScenario(
            externalConnected: true,
            adapterWatts: 15.8,
            batteryNetWatts: 0.05, // within idle deadband |netW| <= 0.2W
            isChargeInhibited: false
        )
        XCTAssertEqual(scenario, .adapterBypass)
    }

    func testActiveDischargeScenarioWhenInhibitedOnAC() {
        let scenario = resolvePowerFlowScenario(
            externalConnected: true,
            adapterWatts: 0.0,
            batteryNetWatts: 15.6, // positive = discharging
            isChargeInhibited: true
        )
        XCTAssertEqual(scenario, .activeDischarge)
    }

    func testPowerAssistScenarioWhenUnderpoweredAdapterBoostedByBattery() {
        let scenario = resolvePowerFlowScenario(
            externalConnected: true,
            adapterWatts: 28.5,
            batteryNetWatts: 18.2, // discharging while on AC without inhibition
            isChargeInhibited: false
        )
        XCTAssertEqual(scenario, .powerAssist)
    }

    func testCalculateSystemWattsPrefersMeasuredWithFallback() {
        // When measured PSTR is available and plausible
        let measured = calculateSystemWatts(adapterWatts: 48.5, batteryNetWatts: -32.4, measuredSystemWatts: 16.1)
        XCTAssertEqual(measured, 16.1, accuracy: 0.01)

        // Fallback to power balance equation when measured is nil: Pin - (-Pcharge) = 48.5 - 32.4 = 16.1
        let fallback = calculateSystemWatts(adapterWatts: 48.5, batteryNetWatts: -32.4, measuredSystemWatts: nil)
        XCTAssertEqual(fallback, 16.1, accuracy: 0.01)
    }
}
