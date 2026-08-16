import Testing
import Foundation
@testable import Wattly

@Suite struct BatteryTelemetryPipelineTests {
    @Test func suppressStaleRemainingTimeOnAdapterDisconnect() {
        var pipeline = BatteryTelemetryPipeline()
        let clock = ContinuousClock()
        let t0 = clock.now

        // Connected state
        let sampleConnected = BatterySample(netW: -20, milliamps: 1500, volts: 12, charging: true, externalConnected: true, timeRemainingMinutes: 45)
        let out1 = pipeline.ingest(sampleConnected, at: t0)
        #expect(out1.timeRemainingMinutes == 45)

        // Immediate disconnect with stale 45 min
        let sampleDisconnected = BatterySample(netW: 15, milliamps: 1200, volts: 12, charging: false, externalConnected: false, timeRemainingMinutes: 45)
        let out2 = pipeline.ingest(sampleDisconnected, at: t0.advanced(by: .seconds(1)))
        #expect(out2.timeRemainingMinutes == nil, "Stale time from connected era must be suppressed")

        // Once a new non-stale time is reported by registry
        let sampleNewEstimate = BatterySample(netW: 15, milliamps: 1200, volts: 12, charging: false, externalConnected: false, timeRemainingMinutes: 210)
        let out3 = pipeline.ingest(sampleNewEstimate, at: t0.advanced(by: .seconds(2)))
        #expect(out3.timeRemainingMinutes == 210, "Fresh estimate should be accepted")
    }

    @Test func oneMinuteAverageAndRegimeReset() {
        var pipeline = BatteryTelemetryPipeline()
        let clock = ContinuousClock()
        let t0 = clock.now

        let s1 = BatterySample(netW: 16, milliamps: 1200, volts: 12, charging: false, externalConnected: false)
        let out1 = pipeline.ingest(s1, at: t0)
        #expect(out1.average1mW == 16)
        #expect(pipeline.oneMinuteAverage == 16)

        let s2 = BatterySample(netW: 24, milliamps: 1800, volts: 12, charging: false, externalConnected: false)
        let out2 = pipeline.ingest(s2, at: t0.advanced(by: .seconds(1)))
        let expected1m = PowerSmoothing.emaStep(previous: 16, raw: 24, dt: 1, tau: 60)
        #expect(abs((out2.average1mW ?? 0) - expected1m) < 1e-12)
        #expect(abs((pipeline.oneMinuteAverage ?? 0) - expected1m) < 1e-12)

        // Plug in -> connection state changes -> 1-minute average resets to new raw value
        let s3 = BatterySample(netW: -30, milliamps: 2500, volts: 12, charging: true, externalConnected: true)
        let out3 = pipeline.ingest(s3, at: t0.advanced(by: .seconds(2)))
        #expect(pipeline.hasConnectionChanged == true)
        #expect(out3.average1mW == -30)
        #expect(pipeline.oneMinuteAverage == -30)
    }

    @Test func resetClearsAllPipelineTracking() {
        var pipeline = BatteryTelemetryPipeline()
        let clock = ContinuousClock()
        let t0 = clock.now

        let sample = BatterySample(netW: 10, milliamps: 800, volts: 12, charging: false, externalConnected: false)
        _ = pipeline.ingest(sample, at: t0)
        #expect(pipeline.oneMinuteAverage != nil)

        pipeline.reset()
        #expect(pipeline.oneMinuteAverage == nil)
        #expect(pipeline.lastExternalConnected == nil)
        #expect(pipeline.hasConnectionChanged == false)
    }
}
