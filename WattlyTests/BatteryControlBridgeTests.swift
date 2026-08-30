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

    // MARK: - 토글 푸시가 보존하는 것

    /// A toggle press must not cancel a Top Up or a manual discharge that the daemon is running —
    /// that was the whole reason the handler used to go through `reconcile`. The preservation is
    /// now explicit and pure, so it survives without the `shouldReapply` gate that was swallowing
    /// the user's press.
    @Test func preservingActivityCarriesDaemonTransientStateForward() {
        let requested = BatteryControlBridge.makeConfiguration(
            enabled: true, limitPercentage: 80,
            sailingEnabled: true, sailingDelta: 5,
            heatProtectionEnabled: true, heatProtectionThresholdCelsius: 35,
            autoDischargeEnabled: true, manualDischargeTarget: 80)
        let daemon = BatteryControlConfiguration(
            enabled: true,
            limitPercentage: 80,
            lowerHysteresisDelta: 5,
            topUpActive: true,
            autoDischargeEnabled: false,
            manualDischargeActive: true,
            manualDischargeTarget: 70)

        let merged = BatteryControlBridge.preservingActivity(requested, daemon: daemon)

        // Transient activity comes from the daemon.
        #expect(merged.topUpActive == true)
        #expect(merged.manualDischargeActive == true)
        // A running manual discharge owns its target; the stored preference must not yank it.
        #expect(merged.manualDischargeTarget == 70)
        // The user's own settings still win.
        #expect(merged.autoDischargeEnabled == true)
        #expect(merged.enabled == true)
        #expect(merged.limitPercentage == 80)
        #expect(merged.lowerHysteresisDelta == 5)
    }

    /// With nothing running on the daemon — and with no daemon answer at all — the request stands
    /// as written, including the stored manual-discharge target.
    @Test func preservingActivityLeavesAnIdleDaemonRequestAlone() {
        let requested = BatteryControlBridge.makeConfiguration(
            enabled: true, limitPercentage: 85,
            sailingEnabled: false, sailingDelta: 5,
            heatProtectionEnabled: false, heatProtectionThresholdCelsius: 35,
            autoDischargeEnabled: true, manualDischargeTarget: 70)
        let idle = BatteryControlConfiguration(
            enabled: true, limitPercentage: 85, lowerHysteresisDelta: 2,
            topUpActive: false, autoDischargeEnabled: false,
            manualDischargeActive: false, manualDischargeTarget: 80)

        let merged = BatteryControlBridge.preservingActivity(requested, daemon: idle)
        #expect(merged.topUpActive == false)
        #expect(merged.manualDischargeActive == false)
        #expect(merged.manualDischargeTarget == 70)
        #expect(merged.autoDischargeEnabled == true)

        let unknown = BatteryControlBridge.preservingActivity(requested, daemon: nil)
        #expect(unknown == requested)
    }

    // MARK: - 미지원 스트릭

    /// An explicit `false` readback is the one signal that means "this Mac cannot do this" —
    /// distinct from a daemon that simply hasn't answered yet. It must increment the streak.
    @Test func explicitHardwareUnsupportedIncrementsStreak() {
        #expect(BatteryControlBridge.unsupportedStreak(
            0, mode: .charging, isHardwareSupported: false) == 1)
        #expect(BatteryControlBridge.unsupportedStreak(
            3, mode: .charging, isHardwareSupported: false) == 4)
    }

    /// `.unsupported` mode is the other unsupported signal and must also increment, independent of
    /// `isHardwareSupported`.
    @Test func unsupportedModeIncrementsStreak() {
        #expect(BatteryControlBridge.unsupportedStreak(
            0, mode: .unsupported, isHardwareSupported: nil) == 1)
        #expect(BatteryControlBridge.unsupportedStreak(
            2, mode: .unsupported, isHardwareSupported: true) == 3)
    }

    /// `nil` means the helper hasn't answered — "unknown", not "unsupported" — so it must NOT
    /// count toward the streak. This is the exact distinction the loop-must-not-exit fix depends
    /// on: treating `nil` as unsupported would back the loop off (or worse, could regress into the
    /// removed `return`) on ordinary startup silence, not just a confirmed-incapable Mac.
    @Test func nilHardwareSupportDoesNotIncrementStreak() {
        #expect(BatteryControlBridge.unsupportedStreak(
            2, mode: .charging, isHardwareSupported: nil) == 0)
    }

    /// A daemon that comes back healthy resets a non-zero streak to zero, so backoff relaxes once
    /// the hardware is confirmed working again.
    @Test func healthyStatusResetsStreakToZero() {
        #expect(BatteryControlBridge.unsupportedStreak(
            5, mode: .inhibited, isHardwareSupported: true) == 0)
        #expect(BatteryControlBridge.unsupportedStreak(
            5, mode: .unavailable, isHardwareSupported: nil) == 0)
    }

    @Test func preservingActivityCarriesCalibrationForward() {
        let requested = BatteryControlConfiguration(enabled: false, limitPercentage: 80)
        let daemon = BatteryControlConfiguration(
            enabled: true, limitPercentage: 80, topUpActive: true,
            autoDischargeEnabled: true,
            calibrationActive: true, calibrationTargetPercentage: 20)

        let merged = BatteryControlBridge.preservingActivity(requested, daemon: daemon)

        #expect(merged.calibrationActive)
        #expect(merged.calibrationTargetPercentage == 20)
        // 어느 단계인지도 보존해야 한다 — 충전 단계를 방전 단계로 바꾸면 절차가 망가진다.
        #expect(merged.topUpActive)
        // 절차 중에는 정책이 활성이어야 하고 자동 방전은 서 있어야 한다.
        #expect(merged.enabled)
        #expect(merged.autoDischargeEnabled == false)
    }

    @Test func preservingActivityIsUnchangedWhenNoCalibrationRuns() {
        let requested = BatteryControlConfiguration(
            enabled: true, limitPercentage: 80, autoDischargeEnabled: true)
        let daemon = BatteryControlConfiguration(enabled: true, limitPercentage: 80)
        let merged = BatteryControlBridge.preservingActivity(requested, daemon: daemon)
        #expect(merged.calibrationActive == false)
        #expect(merged.autoDischargeEnabled)
    }

    // MARK: - 탑업 만료 알림 게이트

    /// An expiry that occurred while no calibration was running should announce.
    @Test func shouldAnnounceTopUpExpiryWhenNotCalibrating() {
        #expect(BatteryControlBridge.shouldAnnounceTopUpExpiry(
            didExpire: true,
            daemon: BatteryControlConfiguration(enabled: true, limitPercentage: 80)) == true)
    }

    /// An expiry that occurred during calibration should be suppressed.
    @Test func shouldNotAnnounceTopUpExpiryWhenCalibrating() {
        let daemon = BatteryControlConfiguration(
            enabled: true, limitPercentage: 80,
            calibrationActive: true, calibrationTargetPercentage: 20)
        #expect(BatteryControlBridge.shouldAnnounceTopUpExpiry(
            didExpire: true,
            daemon: daemon) == false)
    }

    /// No expiry detected means no announcement, calibrating or not.
    @Test func shouldNotAnnounceWhenNoExpiryDetected() {
        let daemon = BatteryControlConfiguration(
            enabled: true, limitPercentage: 80,
            calibrationActive: true, calibrationTargetPercentage: 20)
        #expect(BatteryControlBridge.shouldAnnounceTopUpExpiry(
            didExpire: false,
            daemon: daemon) == false)
    }

    /// A helper that has not answered must not silently swallow a real expiry.
    @Test func shouldAnnounceTopUpExpiryWhenHelperHasNotAnswered() {
        #expect(BatteryControlBridge.shouldAnnounceTopUpExpiry(
            didExpire: true,
            daemon: nil) == true)
    }
}

private actor BridgeRequestReceiver {
    var request: BatteryControlClient.BatteryControlClientRequest?
    func set(_ request: BatteryControlClient.BatteryControlClientRequest) {
        self.request = request
    }
}
