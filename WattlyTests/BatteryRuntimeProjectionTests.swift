import Foundation
import Testing
@testable import Wattly

struct BatteryRuntimeProjectionTests {
    private let clock = ContinuousClock()

    private func discharging(time: Int? = nil,
                             remainingWh: Double? = 60,
                             netW: Double = 30,
                             average1mW: Double? = nil) -> BatterySample {
        BatterySample(netW: netW,
                      milliamps: Int((netW * 1_000 / 12).rounded()),
                      volts: 12,
                      charging: false,
                      externalConnected: false,
                      remainingWh: remainingWh,
                      timeRemainingMinutes: time,
                      average1mW: average1mW)
    }

    @Test func unchangedRegistryMinutesCountDownFromTheirFirstObservation() {
        var projection = BatteryRuntimeProjection()
        let now = clock.now
        let sample = discharging(time: 210)

        #expect(projection.ingest(sample, at: now) == 210)
        for seconds in stride(from: 5, through: 55, by: 5) {
            #expect(projection.ingest(sample, at: now.advanced(by: .seconds(seconds))) == 210)
        }
        #expect(projection.ingest(sample, at: now.advanced(by: .seconds(60))) == 209)
    }

    @Test func changedRegistryMinutesReanchorImmediately() {
        var projection = BatteryRuntimeProjection()
        let now = clock.now

        #expect(projection.ingest(discharging(time: 210), at: now) == 210)
        #expect(projection.ingest(discharging(time: 230), at: now.advanced(by: .seconds(5))) == 230)
        for seconds in stride(from: 10, through: 60, by: 5) {
            #expect(projection.ingest(discharging(time: 230), at: now.advanced(by: .seconds(seconds))) == 230)
        }
        #expect(projection.ingest(discharging(time: 230), at: now.advanced(by: .seconds(65))) == 229)
    }

    @Test func fallbackPrefersValidOneMinuteAverageThenCountsDown() {
        var projection = BatteryRuntimeProjection()
        let now = clock.now
        // 60 Wh / 30 W * 60 = 120 min. The 60 W instantaneous value would be 60 min.
        let sample = discharging(remainingWh: 60, netW: 60, average1mW: 30)

        #expect(projection.ingest(sample, at: now) == 120)
        for seconds in stride(from: 5, through: 55, by: 5) {
            #expect(projection.ingest(sample, at: now.advanced(by: .seconds(seconds))) == 120)
        }
        #expect(projection.ingest(sample, at: now.advanced(by: .seconds(60))) == 119)
    }

    @Test func invalidAverageFallsBackToCurrentDischargePower() {
        var projection = BatteryRuntimeProjection()
        let now = clock.now
        // The non-discharging average is unusable; 60 Wh / 20 W * 60 = 180 min.
        let sample = discharging(remainingWh: 60, netW: 20, average1mW: -2)

        #expect(projection.ingest(sample, at: now) == 180)
    }

    @Test func chargingAndLongGapsDiscardTheOldAnchor() {
        var projection = BatteryRuntimeProjection()
        let now = clock.now
        let sample = discharging(time: 210)
        let charging = BatterySample(netW: -20, milliamps: 1_667, volts: 12,
                                     charging: true, externalConnected: true,
                                     timeRemainingMinutes: 210)

        #expect(projection.ingest(sample, at: now) == 210)
        // A 31-second sleep/wake-sized gap is re-anchored, not decremented by elapsed time.
        #expect(projection.ingest(sample, at: now.advanced(by: .seconds(31))) == 210)
        #expect(projection.ingest(charging, at: now.advanced(by: .seconds(32))) == 210)
        #expect(projection.ingest(sample, at: now.advanced(by: .seconds(33))) == 210)
    }

    @Test func ingestProjectsChargingTimeToFull() {
        var projection = BatteryRuntimeProjection()
        let now = ContinuousClock.now
        let chargingSample = BatterySample(
            netW: -20.0,
            milliamps: 1500,
            volts: 12.5,
            charging: true,
            externalConnected: true,
            remainingWh: 30.0,
            maxWh: 60.0
        )
        let minutes = projection.ingest(chargingSample, at: now)
        #expect(minutes == 90)
    }
}
