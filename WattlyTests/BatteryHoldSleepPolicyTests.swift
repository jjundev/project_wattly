import Foundation
import Testing
@testable import Wattly

@Suite struct BatteryHoldSleepPolicyTests {
    @Test func defaultDurationIsFourHours() {
        #expect(BatteryHoldSleepPolicy.duration == 4 * 3600)
        #expect(BatteryHoldSleepPolicy.durationHours == 4)
    }

    @Test func doesNothingWhenNotAllowed() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: false, isPluggedIn: true, limitEnabled: true,
            currentSoC: 70, targetLimit: 90, isCharging: true, isInHeatProtection: false,
            inhibitedAt: nil, expiredForCurrentSession: false, now: 1_000) == .none)
    }

    @Test func doesNothingWhenNotPluggedIn() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: true, isPluggedIn: false, limitEnabled: true,
            currentSoC: 70, targetLimit: 90, isCharging: true, isInHeatProtection: false,
            inhibitedAt: nil, expiredForCurrentSession: false, now: 1_000) == .none)
    }

    @Test func doesNothingWhenLimitDisabled() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: true, isPluggedIn: true, limitEnabled: false,
            currentSoC: 70, targetLimit: 90, isCharging: true, isInHeatProtection: false,
            inhibitedAt: nil, expiredForCurrentSession: false, now: 1_000) == .none)
    }

    @Test func doesNothingWhenAlreadyAtOrAboveTarget() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: true, isPluggedIn: true, limitEnabled: true,
            currentSoC: 90, targetLimit: 90, isCharging: false, isInHeatProtection: false,
            inhibitedAt: nil, expiredForCurrentSession: false, now: 1_000) == .none)
    }

    @Test func doesNothingWhenInHeatProtection() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: true, isPluggedIn: true, limitEnabled: true,
            currentSoC: 70, targetLimit: 90, isCharging: true, isInHeatProtection: true,
            inhibitedAt: nil, expiredForCurrentSession: false, now: 1_000) == .none)
    }

    @Test func engagesWhenAllConditionsMet() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: true, isPluggedIn: true, limitEnabled: true,
            currentSoC: 70, targetLimit: 90, isCharging: true, isInHeatProtection: false,
            inhibitedAt: nil, expiredForCurrentSession: false, now: 1_000) == .engage)
    }

    @Test func staysEngagedWhileConditionsHold() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: true, isPluggedIn: true, limitEnabled: true,
            currentSoC: 80, targetLimit: 90, isCharging: true, isInHeatProtection: false,
            inhibitedAt: 1_000, expiredForCurrentSession: false, now: 2_000) == .none)
    }

    @Test func disengagesWhenTargetReached() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: true, isPluggedIn: true, limitEnabled: true,
            currentSoC: 90, targetLimit: 90, isCharging: false, isInHeatProtection: false,
            inhibitedAt: 1_000, expiredForCurrentSession: false, now: 3_000) == .disengage)
    }

    @Test func disengagesWhenAdapterUnplugged() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: true, isPluggedIn: false, limitEnabled: true,
            currentSoC: 80, targetLimit: 90, isCharging: false, isInHeatProtection: false,
            inhibitedAt: 1_000, expiredForCurrentSession: false, now: 2_000) == .disengage)
    }

    @Test func disengagesImmediatelyWhenHeatProtectionTriggers() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: true, isPluggedIn: true, limitEnabled: true,
            currentSoC: 80, targetLimit: 90, isCharging: false, isInHeatProtection: true,
            inhibitedAt: 1_000, expiredForCurrentSession: false, now: 2_000) == .disengage)
    }

    @Test func expiresWhenFourHoursElapsed() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: true, isPluggedIn: true, limitEnabled: true,
            currentSoC: 80, targetLimit: 90, isCharging: true, isInHeatProtection: false,
            inhibitedAt: 1_000, expiredForCurrentSession: false, now: 1_000 + 4 * 3600) == .expire)
    }

    @Test func doesNotReengageAfterExpiryInSameSession() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: true, isPluggedIn: true, limitEnabled: true,
            currentSoC: 80, targetLimit: 90, isCharging: true, isInHeatProtection: false,
            inhibitedAt: nil, expiredForCurrentSession: true, now: 2_000) == .none)
    }

    @Test func restampsWhenClockRollsBack() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: true, isPluggedIn: true, limitEnabled: true,
            currentSoC: 80, targetLimit: 90, isCharging: true, isInHeatProtection: false,
            inhibitedAt: 5_000, expiredForCurrentSession: false, now: 2_000) == .restamp(2_000))
    }
}
