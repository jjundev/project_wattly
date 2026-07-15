import Testing
@testable import Wattly

struct FanControlPolicyTests {
    let curve = FanCurve(rpms: [1200, 2500, 4500, 6000])
    let limits = FanLimits(minimum: 2317, maximum: 6550)

    @Test func curveOnlyRaisesFloor() {
        #expect(FanControlPolicy.targetRPM(curve: curve, hottestCPU: 40, limits: limits) == 2317)
        #expect(FanControlPolicy.targetRPM(curve: curve, hottestCPU: 70, limits: limits) == 3500)
    }

    @Test func targetClampsToFanMaximum() {
        let aggressiveCurve = FanCurve(rpms: [1200, 2500, 4500, 8000])
        #expect(FanControlPolicy.targetRPM(curve: aggressiveCurve, hottestCPU: 90, limits: limits) == 6550)
    }

    @Test func criticalTemperatureForcesMaximum() {
        #expect(FanControlPolicy.targetRPM(curve: curve, hottestCPU: 95, limits: limits) == 6550)
    }

    @Test func heartbeatExpiresAtFifteenSeconds() {
        #expect(FanControlPolicy.heartbeatExpired(last: 10, now: 24.999) == false)
        #expect(FanControlPolicy.heartbeatExpired(last: 10, now: 25) == true)
    }

    @Test func nonFiniteTemperatureReturnsSafeZero() {
        #expect(FanControlPolicy.targetRPM(curve: curve, hottestCPU: .nan, limits: limits) == 0)
    }

    @Test func nonpositiveMinimumLimitReturnsSafeZero() {
        #expect(FanControlPolicy.targetRPM(
            curve: curve,
            hottestCPU: 70,
            limits: FanLimits(minimum: 0, maximum: 6550)) == 0)
    }

    @Test func maximumBelowMinimumReturnsSafeZero() {
        #expect(FanControlPolicy.targetRPM(
            curve: curve,
            hottestCPU: 70,
            limits: FanLimits(minimum: 3000, maximum: 2500)) == 0)
    }

    @Test func nonFiniteLimitsReturnSafeZero() {
        #expect(FanControlPolicy.targetRPM(
            curve: curve,
            hottestCPU: 70,
            limits: FanLimits(minimum: .infinity, maximum: .infinity)) == 0)
        #expect(FanControlPolicy.targetRPM(
            curve: curve,
            hottestCPU: 70,
            limits: FanLimits(minimum: 2317, maximum: .infinity)) == 0)
    }

    @Test func policyTimingConstantsMatchSafetySpecification() {
        #expect(FanControlPolicy.heartbeatCheckInterval == 5)
        #expect(FanControlPolicy.controlInterval == 1)
        #expect(FanControlPolicy.modeRetryDeadline == 10)
        #expect(FanControlPolicy.modeRetryDelay == 0.5)
    }
}
