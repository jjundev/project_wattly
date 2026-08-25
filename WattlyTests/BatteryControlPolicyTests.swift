import Foundation
import Testing
@testable import Wattly

@Suite struct BatteryControlPolicyTests {
    private func status(mode: BatteryControlServiceMode, applied: Int?) -> BatteryControlServiceStatus {
        BatteryControlServiceStatus(
            mode: mode,
            currentPercentage: 70,
            isPowerAdapterConnected: true,
            detail: "테스트",
            updatedAt: 0,
            appliedLimitPercentage: applied
        )
    }

    @Test func policyAcceptsHeatProtectionWithoutChargeLimit() {
        let config = BatteryControlConfiguration(
            enabled: false,
            heatProtectionEnabled: true,
            heatProtectionThresholdCelsius: 36
        )
        let status = BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 80,
            isPowerAdapterConnected: true,
            detail: "OK",
            updatedAt: 1000,
            desiredConfiguration: config,
            actualGate: .inhibited(appliedLimitPercentage: nil),
            lastMaintenance: .init(trigger: .clientConfiguration, result: .applied, occurredAt: 1000, reason: nil)
        )
        #expect(BatteryControlPolicy.accepted(configuration: config, by: status) == true)
    }

    @Test func reapplyWhenPersistedHysteresisDiffers() {
        let requested = BatteryControlConfiguration(
            enabled: true, limitPercentage: 85, lowerHysteresisDelta: 5)
        let current = BatteryControlServiceStatus(
            mode: .charging,
            currentPercentage: 80,
            isPowerAdapterConnected: true,
            detail: "OK",
            updatedAt: 1,
            desiredConfiguration: .init(
                enabled: true, limitPercentage: 85, lowerHysteresisDelta: 2),
            capabilities: [.persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1])

        #expect(BatteryControlPolicy.shouldReapply(configuration: requested, status: current))
    }

    @Test func persistentHelperWithExactConfigurationNeedsOnlyStatusRead() {
        let requested = BatteryControlConfiguration(
            enabled: true, limitPercentage: 85, lowerHysteresisDelta: 5)
        let current = BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 85,
            isPowerAdapterConnected: true,
            detail: "OK",
            updatedAt: 1,
            desiredConfiguration: requested,
            capabilities: [.persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1])

        #expect(!BatteryControlPolicy.shouldReapply(configuration: requested, status: current))
    }

    @Test func persistenceClaimsRequireEveryDurabilityCapability() {
        let incomplete = BatteryControlServiceStatus(
            mode: .charging, currentPercentage: 80, isPowerAdapterConnected: true,
            detail: "OK", updatedAt: 1,
            capabilities: [.persistedPolicyV1, .hardwareGateReadbackV1])
        #expect(!BatteryControlPolicy.supportsPersistentPolicy(status: incomplete))
    }

    @Test func legacyHelperFallsBackToAppliedLimitComparison() {
        let requested = BatteryControlConfiguration(
            enabled: true, limitPercentage: 85, lowerHysteresisDelta: 5)
        #expect(!BatteryControlPolicy.shouldReapply(
            configuration: requested, status: status(mode: .charging, applied: 85)))
    }

    @Test func disabledPolicyIsNotAcceptedUntilTheGateIsReleased() {
        let requested = BatteryControlConfiguration(enabled: false, limitPercentage: 85)
        let status = BatteryControlServiceStatus(
            mode: .charging, currentPercentage: 70, isPowerAdapterConnected: true,
            detail: "release failed", updatedAt: 1, desiredConfiguration: requested,
            actualGate: .inhibited(appliedLimitPercentage: 85), releaseVerdict: .failed)

        #expect(!BatteryControlPolicy.accepted(configuration: requested, by: status))
    }

    @Test func enabledPolicyIsNotAcceptedWithoutActualGateEvidence() {
        let requested = BatteryControlConfiguration(enabled: true, limitPercentage: 85)
        let status = BatteryControlServiceStatus(
            mode: .charging, currentPercentage: 80, isPowerAdapterConnected: true,
            detail: "OK", updatedAt: 1, desiredConfiguration: requested,
            lastMaintenance: .init(
                trigger: .clientConfiguration, result: .applied, occurredAt: 1, reason: nil))

        #expect(!BatteryControlPolicy.accepted(configuration: requested, by: status))
    }

    @Test func enabledPolicyIsNotAcceptedWithoutMaintenanceEvidence() {
        let requested = BatteryControlConfiguration(enabled: true, limitPercentage: 85)
        let status = BatteryControlServiceStatus(
            mode: .charging, currentPercentage: 80, isPowerAdapterConnected: true,
            detail: "OK", updatedAt: 1, desiredConfiguration: requested,
            actualGate: .inhibited(appliedLimitPercentage: 85))

        #expect(!BatteryControlPolicy.accepted(configuration: requested, by: status))
    }

    @Test func enabledPolicyRejectsUnreadableActualGate() {
        let requested = BatteryControlConfiguration(enabled: true, limitPercentage: 85)
        let status = acceptedEnabledStatus(configuration: requested, gate: .unreadable)

        #expect(!BatteryControlPolicy.accepted(configuration: requested, by: status))
    }

    @Test func enabledPolicyRejectsUnrecognizedActualGate() {
        let requested = BatteryControlConfiguration(enabled: true, limitPercentage: 85)
        let status = acceptedEnabledStatus(configuration: requested, gate: .init(
            state: .unrecognized, appliedLimitPercentage: nil))

        #expect(!BatteryControlPolicy.accepted(configuration: requested, by: status))
    }

    @Test func enabledPolicyRejectsFailedMaintenance() {
        let requested = BatteryControlConfiguration(enabled: true, limitPercentage: 85)
        var status = acceptedEnabledStatus(
            configuration: requested, gate: .inhibited(appliedLimitPercentage: 85))
        status.lastMaintenance?.result = .failed

        #expect(!BatteryControlPolicy.accepted(configuration: requested, by: status))
    }

    @Test func reapplyWhenHelperRestartedAndForgotTheLimit() {
        // A KeepAlive relaunch brings the helper back with an empty configuration.
        let forgotten = status(mode: .charging, applied: nil)
        #expect(BatteryControlPolicy.shouldReapply(
            configuration: .init(enabled: true, limitPercentage: 85), status: forgotten))
    }

    @Test func reapplyWhenHelperHoldsADifferentLimit() {
        let stale = status(mode: .charging, applied: 80)
        #expect(BatteryControlPolicy.shouldReapply(
            configuration: .init(enabled: true, limitPercentage: 85), status: stale))
    }

    @Test func doNotReapplyWhenHelperAlreadyAgrees() {
        #expect(!BatteryControlPolicy.shouldReapply(
            configuration: .init(enabled: true, limitPercentage: 85),
            status: status(mode: .charging, applied: 85)))
        #expect(!BatteryControlPolicy.shouldReapply(
            configuration: .init(enabled: true, limitPercentage: 85),
            status: status(mode: .inhibited, applied: 85)))
    }

    @Test func settledDisabledHelperNeedsNoWrite() {
        let disabled = BatteryControlConfiguration(enabled: false, limitPercentage: 85)
        let settled = BatteryControlServiceStatus(
            mode: .charging, currentPercentage: 70, isPowerAdapterConnected: true,
            detail: "OK", updatedAt: 0, appliedLimitPercentage: nil,
            desiredConfiguration: disabled,
            capabilities: [.persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1])
        #expect(!BatteryControlPolicy.shouldReapply(configuration: disabled, status: settled))
    }

    @Test func disabledRequestReplacesPersistedEnabledPolicy() {
        let disabled = BatteryControlConfiguration(enabled: false, limitPercentage: 85)
        let current = BatteryControlServiceStatus(
            mode: .charging, currentPercentage: 70, isPowerAdapterConnected: true,
            detail: "OK", updatedAt: 0,
            desiredConfiguration: .init(enabled: true, limitPercentage: 85),
            capabilities: [.persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1])
        #expect(BatteryControlPolicy.shouldReapply(configuration: disabled, status: current))
    }

    @Test func doNotReapplyIntoAnUnreachableHelper() {
        // Connecting or installing is the settings screen's job, not a background loop's.
        #expect(!BatteryControlPolicy.shouldReapply(
            configuration: .init(enabled: true, limitPercentage: 85),
            status: status(mode: .unavailable, applied: nil)))
    }

    @Test func reapplyEvenWhenTheHardwareRejectedTheWrite() {
        // `.unsupported` still means the helper is answering; re-pushing is how a transient
        // failure gets another chance.
        #expect(BatteryControlPolicy.shouldReapply(
            configuration: .init(enabled: true, limitPercentage: 85),
            status: status(mode: .unsupported, applied: nil)))
    }

    @Test func installerRunsOnlyWhenTheHelperIsUnreachable() {
        #expect(BatteryControlPolicy.shouldRunInstaller(mode: .unavailable))
        #expect(!BatteryControlPolicy.shouldRunInstaller(mode: .charging))
        #expect(!BatteryControlPolicy.shouldRunInstaller(mode: .inhibited))
        #expect(!BatteryControlPolicy.shouldRunInstaller(mode: .unsupported))
    }

    @Test func reconcileBacksOffWhenTheHelperKeepsRejectingTheWrite() {
        // A healthy helper is re-checked every minute...
        #expect(BatteryControlPolicy.reconcileInterval(consecutiveUnsupported: 0) == 60.0)
        // ...but a Mac that will never accept the write must not have its write budget re-armed
        // every minute forever.
        #expect(BatteryControlPolicy.reconcileInterval(consecutiveUnsupported: 1) == 300.0)
        #expect(BatteryControlPolicy.reconcileInterval(consecutiveUnsupported: 3) == 300.0)
        #expect(BatteryControlPolicy.reconcileInterval(consecutiveUnsupported: 4) == 900.0)
        #expect(BatteryControlPolicy.reconcileInterval(consecutiveUnsupported: 99) == 900.0)
    }

    @Test func reassertIsThrottledBecauseItIsNotAStateTransition() {
        // The first re-assert of a process always runs.
        #expect(BatteryControlPolicy.shouldReassert(now: 1_000, lastReassertAt: nil))

        // A caller driving the XPC entry point faster than the floor gets one write, not many.
        #expect(!BatteryControlPolicy.shouldReassert(now: 1_000, lastReassertAt: 1_000))
        #expect(!BatteryControlPolicy.shouldReassert(now: 1_059, lastReassertAt: 1_000))

        // The real callers — a launch, a wake, a settings edit — are far past the floor.
        #expect(BatteryControlPolicy.shouldReassert(now: 1_060, lastReassertAt: 1_000))
        #expect(BatteryControlPolicy.shouldReassert(now: 9_999, lastReassertAt: 1_000))
    }

    @Test func doNotReapplyIntoHardwareThatCanNeverAcceptIt() {
        let noRegister = BatteryControlServiceStatus(
            mode: .unsupported,
            currentPercentage: 70,
            isPowerAdapterConnected: true,
            detail: "이 Mac은 충전 제어를 지원하지 않습니다",
            updatedAt: 0,
            appliedLimitPercentage: nil,
            isHardwareSupported: false
        )
        #expect(!BatteryControlPolicy.shouldReapply(
            configuration: .init(enabled: true, limitPercentage: 85), status: noRegister))
    }

    @Test func stillReapplyWhenCapabilityIsUnknown() {
        // An older helper reports nil. That is "unknown", and giving up on it would strand a
        // perfectly capable Mac behind a field its helper is simply too old to send.
        let olderHelper = BatteryControlServiceStatus(
            mode: .unsupported,
            currentPercentage: 70,
            isPowerAdapterConnected: true,
            detail: "이 Mac에서 충전 제어를 적용하지 못했습니다",
            updatedAt: 0,
            appliedLimitPercentage: nil,
            isHardwareSupported: nil
        )
        #expect(BatteryControlPolicy.shouldReapply(
            configuration: .init(enabled: true, limitPercentage: 85), status: olderHelper))
    }

    private func acceptedEnabledStatus(
        configuration: BatteryControlConfiguration,
        gate: BatteryHardwareGate
    ) -> BatteryControlServiceStatus {
        BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 85,
            isPowerAdapterConnected: true,
            detail: "OK",
            updatedAt: 1,
            desiredConfiguration: configuration,
            actualGate: gate,
            lastMaintenance: .init(
                trigger: .clientConfiguration,
                result: .applied,
                occurredAt: 1,
                reason: nil))
    }

    @Test func shouldReapplyPreservesActiveTopUpWhenBaseSettingsMatch() {
        let appConfig = BatteryControlConfiguration(enabled: true, limitPercentage: 80, lowerHysteresisDelta: 2, topUpActive: false)
        let daemonConfig = BatteryControlConfiguration(enabled: true, limitPercentage: 80, lowerHysteresisDelta: 2, topUpActive: true)

        let status = BatteryControlServiceStatus(
            mode: .charging,
            currentPercentage: 70,
            isPowerAdapterConnected: true,
            detail: "Top Up 중 (100%까지 충전)",
            updatedAt: 100.0,
            desiredConfiguration: daemonConfig,
            capabilities: [.persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1]
        )

        // When helper holds topUpActive == true, background client check with same base settings must NOT trigger reapply
        #expect(BatteryControlPolicy.shouldReapply(configuration: appConfig, status: status) == false)
    }

    @Test func shouldReapplyPreservesActiveManualDischargeWhenBaseSettingsMatch() {
        let appConfig = BatteryControlConfiguration(
            enabled: true,
            limitPercentage: 80,
            lowerHysteresisDelta: 2,
            autoDischargeEnabled: true,
            manualDischargeActive: false,
            manualDischargeTarget: 80
        )
        let daemonConfig = BatteryControlConfiguration(
            enabled: true,
            limitPercentage: 80,
            lowerHysteresisDelta: 2,
            autoDischargeEnabled: true,
            manualDischargeActive: true,
            manualDischargeTarget: 70
        )

        let status = BatteryControlServiceStatus(
            mode: .charging,
            currentPercentage: 85,
            isPowerAdapterConnected: true,
            detail: "수동 방전 중 (70%까지 방전)",
            updatedAt: 100.0,
            desiredConfiguration: daemonConfig,
            capabilities: [.persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1]
        )

        // When helper holds manualDischargeActive == true, background client check with same base settings must NOT trigger reapply
        #expect(BatteryControlPolicy.shouldReapply(configuration: appConfig, status: status) == false)
    }
}

@Suite struct BatteryControlDischargePolicyTests {
    @Test func dischargeConfigurationProperties() {
        let config = BatteryControlConfiguration(
            enabled: true,
            limitPercentage: 80,
            autoDischargeEnabled: true,
            manualDischargeActive: true,
            manualDischargeTarget: 70
        )
        #expect(config.clampedManualDischargeTarget == 70)
        #expect(config.autoDischargeEnabled == true)
        #expect(config.manualDischargeActive == true)
        #expect(config.isActive == true)
    }

    @Test func dischargeConfigurationDefaults() {
        let config = BatteryControlConfiguration()
        #expect(config.autoDischargeEnabled == true)
        #expect(config.manualDischargeActive == false)
        #expect(config.manualDischargeTarget == 80)
        #expect(config.clampedManualDischargeTarget == 80)
    }

    @Test func dischargeConfigurationClampingAndNormalization() {
        let configUnder = BatteryControlConfiguration(
            enabled: false,
            limitPercentage: 80,
            autoDischargeEnabled: false,
            manualDischargeActive: true,
            manualDischargeTarget: 30
        )
        #expect(configUnder.clampedManualDischargeTarget == 50)
        #expect(configUnder.normalized.manualDischargeTarget == 50)
        #expect(configUnder.normalized.autoDischargeEnabled == false)
        #expect(configUnder.normalized.manualDischargeActive == true)
        #expect(configUnder.isActive == true)

        let configOver = BatteryControlConfiguration(
            enabled: false,
            limitPercentage: 80,
            autoDischargeEnabled: true,
            manualDischargeActive: true,
            manualDischargeTarget: 120
        )
        #expect(configOver.clampedManualDischargeTarget == 100)
        #expect(configOver.normalized.manualDischargeTarget == 100)
    }
}
