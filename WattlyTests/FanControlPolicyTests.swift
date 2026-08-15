import Testing
@testable import Wattly

struct FanControlPolicyTests {
    let curve = FanCurve(rpms: [800,900,1000,1200,1500,1900,2400,3000,3600,4200,4800,5500,6200,6800,7400])
    let limits = FanLimits(minimum: 2317, maximum: 6550)

    @Test func targetClampsToFanMaximum() {
        let aggressiveCurve = FanCurve(rpms: Array(repeating: 8000, count: 15))
        #expect(FanControlPolicy.targetRPM(curve: aggressiveCurve, hottestCPU: 90,
                                           limits: limits, wasZeroRPM: false) == 6550)
    }

    @Test func zeroCurveEntersAndExitsWithHysteresis() {
        let zeroCurve = FanCurve(rpms: Array(repeating: 0, count: FanCurve.anchorsCelsius.count))
        #expect(FanControlPolicy.targetRPM(curve: zeroCurve, hottestCPU: 47.9,
                                           limits: limits, wasZeroRPM: false) == 0)
        #expect(FanControlPolicy.targetRPM(curve: zeroCurve, hottestCPU: 48.0,
                                           limits: limits, wasZeroRPM: false) == 2317)
        #expect(FanControlPolicy.targetRPM(curve: zeroCurve, hottestCPU: 54.9,
                                           limits: limits, wasZeroRPM: true) == 0)
        #expect(FanControlPolicy.targetRPM(curve: zeroCurve, hottestCPU: 55.0,
                                           limits: limits, wasZeroRPM: true) == 2317)
    }

    @Test func nonzeroCurveStillUsesTheHardwareMinimum() {
        #expect(FanControlPolicy.targetRPM(curve: curve, hottestCPU: 40,
                                           limits: limits, wasZeroRPM: false) == 2317)
    }

    @Test func curveStillControlsAtIts100CelsiusEndpoint() {
        let conservativeCurve = FanCurve(rpms: Array(repeating: 3000, count: FanCurve.anchorsCelsius.count))
        #expect(FanControlPolicy.targetRPM(curve: conservativeCurve, hottestCPU: 100,
                                           limits: limits, wasZeroRPM: false) == 3000)
    }

    @Test func temperatureAboveTheCurveRangeForcesMaximum() {
        #expect(FanControlPolicy.targetRPM(curve: curve, hottestCPU: 100.001,
                                           limits: limits, wasZeroRPM: false) == 6550)
    }

    @Test func heartbeatExpiresAtFifteenSeconds() {
        #expect(FanControlPolicy.heartbeatExpired(last: 10, now: 24.999) == false)
        #expect(FanControlPolicy.heartbeatExpired(last: 10, now: 25) == true)
    }

    @Test func invalidPolicyInputsReturnNilNotAZeroCommand() {
        #expect(FanControlPolicy.targetRPM(curve: curve, hottestCPU: .nan,
                                           limits: limits, wasZeroRPM: false) == nil)
        #expect(FanControlPolicy.targetRPM(curve: curve, hottestCPU: 70,
                                           limits: .init(minimum: 0, maximum: 6550),
                                           wasZeroRPM: false) == nil)
    }

    @Test func malformedCurveReturnsNilNotAZeroCommand() {
        let malformedCurve = FanCurve(rpms: [])
        #expect(FanControlPolicy.targetRPM(curve: malformedCurve, hottestCPU: 40,
                                           limits: limits, wasZeroRPM: false) == nil)
    }

    @Test func malformedCurveRemainsRejectedAboveTheCurveRange() {
        let malformedCurve = FanCurve(rpms: [])
        #expect(FanControlPolicy.targetRPM(curve: malformedCurve, hottestCPU: 100.001,
                                           limits: limits, wasZeroRPM: false) == nil)
    }

    @Test func malformedNegativeToPositiveCurveCannotInterpolateToZeroRPM() {
        var rpms = Array(repeating: 1000.0, count: FanCurve.anchorsCelsius.count)
        rpms[0] = -100
        rpms[1] = 100
        let malformedCurve = FanCurve(rpms: rpms)

        #expect(FanControlPolicy.targetRPM(curve: malformedCurve, hottestCPU: 32.5,
                                           limits: limits, wasZeroRPM: false) == nil)
    }

    @Test func nonFiniteRPMOutsideSampledSegmentRejectsCurve() {
        var rpms = Array(repeating: 1000.0, count: FanCurve.anchorsCelsius.count)
        rpms[FanCurve.anchorsCelsius.count - 1] = .nan
        let malformedCurve = FanCurve(rpms: rpms)

        #expect(FanControlPolicy.targetRPM(curve: malformedCurve, hottestCPU: 32.5,
                                           limits: limits, wasZeroRPM: false) == nil)
    }

    @Test func temperatureAboveTheCurveRangeOverridesAZeroCurve() {
        let zeroCurve = FanCurve(rpms: Array(repeating: 0, count: FanCurve.anchorsCelsius.count))
        #expect(FanControlPolicy.targetRPM(curve: zeroCurve, hottestCPU: 100.001,
                                           limits: limits, wasZeroRPM: true) == 6550)
    }

    @Test func policyTimingConstantsMatchSafetySpecification() {
        #expect(FanControlPolicy.heartbeatCheckInterval == 5)
        #expect(FanControlPolicy.controlInterval == 1)
        #expect(FanControlPolicy.modeRetryDeadline == 10)
        #expect(FanControlPolicy.modeRetryDelay == 0.5)
    }
}
