import Testing
@testable import Wattly

@Suite struct NativeChargeLimitStatusTests {
    private let limits = [80, 85, 90, 95, 100]
    private let armed80 = NativeLimitSnapshot(limit: 80, state: .on)

    private func make(
        _ configuration: BatteryControlConfiguration,
        pct: Int,
        plugged: Bool = true,
        mA: Int? = 0,
        native: NativeLimitSnapshot?,
        outcome: NativeLimitWriteOutcome = .none
    ) -> BatteryControlServiceStatus {
        NativeChargeLimitStatus.make(
            configuration: configuration,
            reading: .init(percentage: pct, isPluggedIn: plugged, batteryMilliamps: mA),
            native: native,
            availableLimits: limits,
            outcome: outcome,
            now: 1_000)
    }

    @Test func everyStatusCarriesTheFixedFacts() {
        let status = make(.init(enabled: true, limitPercentage: 80), pct: 60, native: armed80)
        #expect(status.controlBackend == .nativeLimit)
        #expect(status.isHardwareSupported == true)
        #expect(status.isDischargeHardwareSupported == false)
        #expect(status.capabilities == [.persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1])
        #expect(status.desiredConfiguration == BatteryControlConfiguration(enabled: true, limitPercentage: 80).normalized)
        #expect(status.currentPercentage == 60)
        #expect(status.isPowerAdapterConnected == true)
        #expect(status.updatedAt == 1_000)
        #expect(status.mode != .unavailable)
        #expect(status.mode != .unsupported)
    }

    @Test func chargingTowardTheLimit() {
        let status = make(.init(enabled: true, limitPercentage: 80), pct: 60, mA: 4_100, native: armed80)
        #expect(status.activity == .chargingToLimit)
        #expect(status.detailReason == .init(kind: .chargingToTarget, limitPercentage: 80))
        #expect(status.mode == .charging)
        #expect(status.actualGate == .allowed)
        #expect(status.appliedLimitPercentage == 80)
    }

    @Test func holdingAtTheLimit() {
        let status = make(.init(enabled: true, limitPercentage: 80), pct: 80, mA: 0, native: armed80)
        #expect(status.activity == .holdingAtLimit)
        #expect(status.detailReason == .init(kind: .inhibitedAtLimit, limitPercentage: 80))
        #expect(status.mode == .inhibited)
        #expect(status.actualGate == .inhibited(appliedLimitPercentage: 80))
    }

    @Test func firmwareDrainAboveTheLimitReadsAsDischarging() {
        let status = make(.init(enabled: true, limitPercentage: 80), pct: 96, mA: -850, native: armed80)
        #expect(status.activity == .discharging)
        #expect(status.detailReason == .init(kind: .dischargingToTarget, limitPercentage: 80))
        #expect(status.mode == .inhibited)
    }

    @Test func aboveTheLimitWithoutNegativeCurrentIsJustHolding() {
        let status = make(.init(enabled: true, limitPercentage: 80), pct: 96, mA: -40, native: armed80)
        #expect(status.activity == .holdingAtLimit)
        let unknownCurrent = make(.init(enabled: true, limitPercentage: 80), pct: 96, mA: nil, native: armed80)
        #expect(unknownCurrent.activity == .holdingAtLimit)
    }

    @Test func onBatteryPower() {
        let status = make(.init(enabled: true, limitPercentage: 80), pct: 70, plugged: false, mA: -500, native: armed80)
        #expect(status.activity == .onBatteryPower)
        #expect(status.detailReason == .init(kind: .onBatteryPower))
        #expect(status.actualGate == .allowed)
    }

    @Test func disabledLimit() {
        let status = make(.init(enabled: false), pct: 70, native: .init(limit: 100, state: .off))
        #expect(status.activity == .inactive)
        #expect(status.detailReason == .init(kind: .limitDisabled))
        #expect(status.appliedLimitPercentage == nil)
        #expect(status.actualGate == .allowed)
    }

    @Test func topUpChargingThenComplete() {
        let config = BatteryControlConfiguration(enabled: true, limitPercentage: 80, topUpActive: true)
        let tempDisabled = NativeLimitSnapshot(limit: 100, state: .temporarilyDisabled)
        let charging = make(config, pct: 90, mA: 2_800, native: tempDisabled)
        #expect(charging.activity == .topUp)
        #expect(charging.detailReason == .init(kind: .topUpCharging))
        #expect(charging.appliedLimitPercentage == nil)
        let full = make(config, pct: 100, mA: 0, native: tempDisabled)
        #expect(full.activity == .topUp)
        #expect(full.detailReason == .init(kind: .topUpComplete))
        #expect(full.mode == .inhibited)
    }

    @Test func writeFailureWhileEnablingIsApplyFailed() {
        let status = make(.init(enabled: true, limitPercentage: 80), pct: 60,
                          native: .init(limit: 100, state: .off), outcome: .failed)
        #expect(status.detailReason == .init(kind: .applyFailed))
        #expect(status.activity == .inactive)
    }

    @Test func writeFailureWhileDisablingIsReleaseFailed() {
        let status = make(.init(enabled: false), pct: 60, native: armed80, outcome: .failed)
        #expect(status.detailReason == .init(kind: .releaseFailed))
    }

    @Test func unreadableNativeStateIsAReadbackFailure() {
        let status = make(.init(enabled: true, limitPercentage: 80), pct: 60, native: nil)
        #expect(status.detailReason == .init(kind: .hardwareReadbackFailed))
        #expect(status.actualGate == .unreadable)
        #expect(status.appliedLimitPercentage == nil)
    }

    @Test func powerSourceUnreadable() {
        let status = NativeChargeLimitStatus.powerSourceUnreadable(
            configuration: .init(enabled: true, limitPercentage: 80), now: 5)
        #expect(status.detailReason == .init(kind: .powerSourceUnreadable))
        #expect(status.controlBackend == .nativeLimit)
        #expect(status.isHardwareSupported == true)
    }

    // The contract that lets every existing caller work unmodified.

    @Test func anAppliedConfigureIsAcceptedByTheExistingPolicy() {
        let config = BatteryControlConfiguration(enabled: true, limitPercentage: 80).normalized
        var status = make(config, pct: 60, native: armed80, outcome: .applied)
        status.lastMaintenance = .init(trigger: .clientConfiguration, result: .applied, occurredAt: 1_000, reason: nil)
        #expect(BatteryControlPolicy.accepted(configuration: config, by: status))
        #expect(BatteryControlPolicy.shouldReapply(configuration: config, status: status) == false)
        #expect(BatteryControlPolicy.shouldRunInstaller(mode: status.mode) == false)
    }

    @Test func aDisableIsAcceptedBecauseTheGateReadsAllowed() {
        let config = BatteryControlConfiguration(enabled: false).normalized
        var status = make(config, pct: 60, native: .init(limit: 100, state: .off), outcome: .applied)
        status.lastMaintenance = .init(trigger: .clientConfiguration, result: .applied, occurredAt: 1_000, reason: nil)
        #expect(BatteryControlPolicy.accepted(configuration: config, by: status))
    }
}
