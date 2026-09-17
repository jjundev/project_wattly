import Testing
@testable import Wattly

@Suite struct NativeChargeLimitPlanTests {
    private let limits = [80, 85, 90, 95, 100]

    private func command(
        _ configuration: BatteryControlConfiguration,
        plugged: Bool = true,
        native: NativeLimitSnapshot,
        owns: Bool = false
    ) -> NativeLimitCommand {
        NativeChargeLimitPlan.command(
            configuration: configuration,
            isPluggedIn: plugged,
            native: native,
            ownsNativeLimit: owns,
            availableLimits: limits)
    }

    // MARK: enabledState

    @Test func rawStateMapsTheThreeMeasuredValues() {
        #expect(NativeLimitEnabledState(rawState: 0) == .off)
        #expect(NativeLimitEnabledState(rawState: 1) == .on)
        #expect(NativeLimitEnabledState(rawState: 3) == .temporarilyDisabled)
        #expect(NativeLimitEnabledState(rawState: 2) == .unknown(2))
    }

    // MARK: snapped

    @Test func snappedKeepsAnAllowedValue() {
        #expect(NativeChargeLimitPlan.snapped(85, to: limits) == 85)
    }

    @Test func snappedRoundsUpToTheNextAllowedValue() {
        #expect(NativeChargeLimitPlan.snapped(70, to: limits) == 80)
        #expect(NativeChargeLimitPlan.snapped(81, to: limits) == 85)
    }

    @Test func snappedFallsBackWhenTheListIsEmptyOrTooLow() {
        #expect(NativeChargeLimitPlan.snapped(70, to: []) == 80)
        #expect(NativeChargeLimitPlan.snapped(99, to: [80, 85]) == 100)
    }

    // MARK: command — enabled

    @Test func armsTheLimitWhenNativeIsOff() {
        let result = command(.init(enabled: true, limitPercentage: 80),
                             native: .init(limit: 100, state: .off))
        #expect(result == .setLimit(80))
    }

    @Test func doesNothingWhenNativeAlreadyMatches() {
        let result = command(.init(enabled: true, limitPercentage: 90),
                             native: .init(limit: 90, state: .on))
        #expect(result == .none)
    }

    @Test func rearmsWhenSomeoneElseChangedTheValue() {
        let result = command(.init(enabled: true, limitPercentage: 80),
                             native: .init(limit: 95, state: .on))
        #expect(result == .setLimit(80))
    }

    @Test func rearmsAfterATopUpThatIsNoLongerRequested() {
        let result = command(.init(enabled: true, limitPercentage: 80),
                             native: .init(limit: 100, state: .temporarilyDisabled))
        #expect(result == .setLimit(80))
    }

    @Test func offListRequestIsRoundedUpBeforeComparing() {
        let result = command(.init(enabled: true, limitPercentage: 70),
                             native: .init(limit: 80, state: .on))
        #expect(result == .none)
    }

    @Test func enabledAtOneHundredWithNativeOffIsAlreadySatisfied() {
        let result = command(.init(enabled: true, limitPercentage: 100),
                             native: .init(limit: 100, state: .off))
        #expect(result == .none)
    }

    // MARK: command — Top Up

    @Test func topUpTemporarilyDisablesAnArmedLimit() {
        let result = command(.init(enabled: true, limitPercentage: 80, topUpActive: true),
                             native: .init(limit: 80, state: .on))
        #expect(result == .temporarilyDisable)
    }

    @Test func topUpIsIdempotent() {
        let result = command(.init(enabled: true, limitPercentage: 80, topUpActive: true),
                             native: .init(limit: 100, state: .temporarilyDisabled))
        #expect(result == .none)
    }

    @Test func topUpWithNothingArmedHasNothingToDisable() {
        let result = command(.init(enabled: true, limitPercentage: 80, topUpActive: true),
                             native: .init(limit: 100, state: .off))
        #expect(result == .none)
    }

    @Test func topUpOnBatteryPowerFallsThroughToTheOrdinaryLimit() {
        let result = command(.init(enabled: true, limitPercentage: 80, topUpActive: true),
                             plugged: false,
                             native: .init(limit: 100, state: .temporarilyDisabled))
        #expect(result == .setLimit(80))
    }

    // MARK: command — disabled

    @Test func disablingReleasesOnlyALimitThisAppArmed() {
        let armed = NativeLimitSnapshot(limit: 80, state: .on)
        #expect(command(.init(enabled: false), native: armed, owns: true) == .release)
        #expect(command(.init(enabled: false), native: armed, owns: false) == .none)
    }

    @Test func disablingWithNothingArmedStillClearsOwnershipThroughRelease() {
        // 소유 플래그가 남아 있으면 release가 한 번 나가고, 서비스가 그때 플래그를 내린다.
        #expect(command(.init(enabled: false), native: .init(limit: 100, state: .off), owns: true) == .release)
    }
}
