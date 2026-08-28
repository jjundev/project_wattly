import Testing
import Foundation
@testable import Wattly

@Suite struct BatteryControlBridgeTests {

    // MARK: - 순수 설정 빌더

    /// The bug this file exists for: the bridge never read `batteryAutoDischargeEnabled` or
    /// `batteryManualDischargeTarget`, so `BatteryControlConfiguration`'s own defaults (false / 80)
    /// reached the daemon on every reconcile and switched auto-discharge back off once a minute.
    @Test func configurationCarriesEveryStoredPreference() {
        let config = BatteryControlBridge.makeConfiguration(
            enabled: true,
            limitPercentage: 85,
            sailingEnabled: true,
            sailingDelta: 5,
            heatProtectionEnabled: true,
            heatProtectionThresholdCelsius: 38,
            autoDischargeEnabled: true,
            manualDischargeTarget: 70)

        #expect(config.enabled == true)
        #expect(config.limitPercentage == 85)
        #expect(config.lowerHysteresisDelta == 5)
        #expect(config.heatProtectionEnabled == true)
        #expect(config.heatProtectionThresholdCelsius == 38)
        #expect(config.autoDischargeEnabled == true)
        #expect(config.manualDischargeTarget == 70)
        // Transient daemon-side activity is never asserted by the bridge; `shouldReapply`
        // preserves it from the helper's own status instead.
        #expect(config.topUpActive == false)
        #expect(config.manualDischargeActive == false)
    }

    /// Sailing off means the fixed 2-point hysteresis, regardless of the stored delta.
    @Test func sailingOffUsesTheFixedTwoPointDelta() {
        #expect(BatteryControlBridge.effectiveDelta(sailingEnabled: false, sailingDelta: 5) == 2)
        #expect(BatteryControlBridge.effectiveDelta(sailingEnabled: true, sailingDelta: 5) == 5)

        let config = BatteryControlBridge.makeConfiguration(
            enabled: true,
            limitPercentage: 80,
            sailingEnabled: false,
            sailingDelta: 5,
            heatProtectionEnabled: false,
            heatProtectionThresholdCelsius: 35,
            autoDischargeEnabled: false,
            manualDischargeTarget: 80)
        #expect(config.lowerHysteresisDelta == 2)
    }

    /// The stored defaults the bridge starts from, pinned so a Defaults edit cannot quietly
    /// re-create the original symptom.
    @Test func bridgeDischargeDefaultsMatchStoredDefaults() {
        #expect(Defaults.batteryAutoDischargeEnabled == false)
        #expect(Defaults.batteryManualDischargeTarget == 80)
        #expect(StorageKey.batteryAutoDischargeEnabled == "batteryAutoDischargeEnabled")
        #expect(StorageKey.batteryManualDischargeTarget == "batteryManualDischargeTarget")
    }

    // MARK: - 데몬 왕복 회귀

    /// The mechanism of the reported bug, pinned. A daemon that holds auto-discharge ON and a
    /// bridge configuration that says OFF is a mismatch `shouldReapply` acts on — it re-pushes,
    /// and auto-discharge dies. With the preference wired, the two agree and nothing is re-pushed.
    @Test func autoDischargeMismatchIsWhatTriggeredTheReapply() {
        let daemonConfig = BatteryControlConfiguration(
            enabled: true,
            limitPercentage: 85,
            lowerHysteresisDelta: 2,
            autoDischargeEnabled: true)
        let status = BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 100,
            isPowerAdapterConnected: true,
            detail: "충전 제한 85% 도달",
            updatedAt: 100.0,
            desiredConfiguration: daemonConfig,
            capabilities: [.persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1])

        let unwired = BatteryControlBridge.makeConfiguration(
            enabled: true, limitPercentage: 85,
            sailingEnabled: false, sailingDelta: 5,
            heatProtectionEnabled: false, heatProtectionThresholdCelsius: 35,
            autoDischargeEnabled: false, manualDischargeTarget: 80)
        #expect(BatteryControlPolicy.shouldReapply(configuration: unwired, status: status) == true)

        let wired = BatteryControlBridge.makeConfiguration(
            enabled: true, limitPercentage: 85,
            sailingEnabled: false, sailingDelta: 5,
            heatProtectionEnabled: false, heatProtectionThresholdCelsius: 35,
            autoDischargeEnabled: true, manualDischargeTarget: 80)
        #expect(BatteryControlPolicy.shouldReapply(configuration: wired, status: status) == false)
    }

    /// The second half of the same omission: while no discharge is running, `reconcile` keeps the
    /// caller's target, so the bridge passing the stored 70 is what stops the daemon's setting
    /// from drifting back to 80.
    @MainActor @Test func reconcileForwardsBothDischargePreferences() async throws {
        let receiver = BridgeRequestReceiver()
        let daemonConfig = BatteryControlConfiguration(
            enabled: true,
            limitPercentage: 85,
            lowerHysteresisDelta: 2,
            autoDischargeEnabled: false,
            manualDischargeActive: false,
            manualDischargeTarget: 80)
        let status = BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 100,
            isPowerAdapterConnected: true,
            detail: "충전 제한 85% 도달",
            updatedAt: 100.0,
            desiredConfiguration: daemonConfig,
            capabilities: [.persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1])
        let client = BatteryControlClient(requestHandler: { request in
            await receiver.set(request)
            return (try? BatteryControlCodec.encode(status), nil)
        })

        await client.reconcile(
            enabled: true,
            limitPercentage: 85,
            lowerHysteresisDelta: 2,
            heatProtectionEnabled: false,
            heatProtectionThresholdCelsius: 35,
            autoDischargeEnabled: true,
            manualDischargeTarget: 70)

        guard case .configure(let data) = await receiver.request else {
            Issue.record("Expected configure request")
            return
        }
        let sent = try BatteryControlCodec.decode(
            BatteryControlConfigurationRequest.self, from: data)
        #expect(sent.configuration.autoDischargeEnabled == true)
        #expect(sent.configuration.manualDischargeTarget == 70)
    }

    // MARK: - 재조정 루프 task id

    /// Guards a second copy of the same regression: `makeConfiguration` can carry every stored
    /// preference and still leave the bug in place if `.task(id:)` doesn't restart on all of them,
    /// since the loop body reads `self` at task-start and otherwise reconciles a stale value
    /// forever. Each of the eight inputs is varied one at a time from a fixed baseline; a
    /// preference dropped from `reconcileTaskID` would leave that one variant equal to the
    /// baseline and fail here the moment it's added below.
    @Test func reconcileTaskIDChangesWithEveryStoredPreference() {
        let baseline = BatteryControlBridge.reconcileTaskID(
            enabled: true,
            limitPercentage: 85,
            sailingEnabled: true,
            sailingDelta: 5,
            heatProtectionEnabled: true,
            heatProtectionThresholdCelsius: 38,
            autoDischargeEnabled: true,
            manualDischargeTarget: 70)

        #expect(BatteryControlBridge.reconcileTaskID(
            enabled: false, limitPercentage: 85, sailingEnabled: true, sailingDelta: 5,
            heatProtectionEnabled: true, heatProtectionThresholdCelsius: 38,
            autoDischargeEnabled: true, manualDischargeTarget: 70) != baseline)

        #expect(BatteryControlBridge.reconcileTaskID(
            enabled: true, limitPercentage: 86, sailingEnabled: true, sailingDelta: 5,
            heatProtectionEnabled: true, heatProtectionThresholdCelsius: 38,
            autoDischargeEnabled: true, manualDischargeTarget: 70) != baseline)

        #expect(BatteryControlBridge.reconcileTaskID(
            enabled: true, limitPercentage: 85, sailingEnabled: false, sailingDelta: 5,
            heatProtectionEnabled: true, heatProtectionThresholdCelsius: 38,
            autoDischargeEnabled: true, manualDischargeTarget: 70) != baseline)

        #expect(BatteryControlBridge.reconcileTaskID(
            enabled: true, limitPercentage: 85, sailingEnabled: true, sailingDelta: 6,
            heatProtectionEnabled: true, heatProtectionThresholdCelsius: 38,
            autoDischargeEnabled: true, manualDischargeTarget: 70) != baseline)

        #expect(BatteryControlBridge.reconcileTaskID(
            enabled: true, limitPercentage: 85, sailingEnabled: true, sailingDelta: 5,
            heatProtectionEnabled: false, heatProtectionThresholdCelsius: 38,
            autoDischargeEnabled: true, manualDischargeTarget: 70) != baseline)

        #expect(BatteryControlBridge.reconcileTaskID(
            enabled: true, limitPercentage: 85, sailingEnabled: true, sailingDelta: 5,
            heatProtectionEnabled: true, heatProtectionThresholdCelsius: 39,
            autoDischargeEnabled: true, manualDischargeTarget: 70) != baseline)

        #expect(BatteryControlBridge.reconcileTaskID(
            enabled: true, limitPercentage: 85, sailingEnabled: true, sailingDelta: 5,
            heatProtectionEnabled: true, heatProtectionThresholdCelsius: 38,
            autoDischargeEnabled: false, manualDischargeTarget: 70) != baseline)

        #expect(BatteryControlBridge.reconcileTaskID(
            enabled: true, limitPercentage: 85, sailingEnabled: true, sailingDelta: 5,
            heatProtectionEnabled: true, heatProtectionThresholdCelsius: 38,
            autoDischargeEnabled: true, manualDischargeTarget: 71) != baseline)
    }
}

private actor BridgeRequestReceiver {
    var request: BatteryControlClient.BatteryControlClientRequest?
    func set(_ request: BatteryControlClient.BatteryControlClientRequest) {
        self.request = request
    }
}
