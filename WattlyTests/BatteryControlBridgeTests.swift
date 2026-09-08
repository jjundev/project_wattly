import Testing
import Foundation
@testable import Wattly

@Suite struct BatteryControlBridgeTests {

    // MARK: - pushAction

    private var on: BatteryPreferences {
        var p = BatteryPreferences.standard; p.limitEnabled = true; p.limitPercentage = 80; return p
    }

    @Test func unchangedConfigurationIsNotPushed() {
        var new = on; new.sailingDelta = 7                      // sailing off → delta는 설정에 안 실린다
        #expect(BatteryControlBridge.pushAction(from: on, to: new, hasExternalDisplay: false) == .none)
        #expect(BatteryControlBridge.pushAction(from: on, to: on, hasExternalDisplay: false) == .none)
    }

    @Test func activeLimitOrHeatProtectionAlwaysApplies() {
        var new = on; new.limitPercentage = 85
        #expect(BatteryControlBridge.pushAction(from: on, to: new, hasExternalDisplay: false) == .apply)
        var heatOnly = BatteryPreferences.standard; heatOnly.heatProtectionEnabled = true
        #expect(BatteryControlBridge.pushAction(from: .standard, to: heatOnly, hasExternalDisplay: false) == .apply)
    }

    @Test func turningEverythingOffDisables() {
        var off = on; off.limitEnabled = false
        #expect(BatteryControlBridge.pushAction(from: on, to: off, hasExternalDisplay: false) == .disable)
    }

    /// 한도가 꺼진 채로도 수동 방전은 돌 수 있다. 방전 쪽 토글만 바뀌면 `disable`이 아니라 활동을
    /// 보존하는 `apply`로 가야 방전이 취소되지 않는다(예전 `applyRequested` 직행 경로와 같다).
    @Test func dischargeSideChangesWhileLimitOffStillApply() {
        var a = BatteryPreferences.standard; a.autoDischargeEnabled = true
        #expect(BatteryControlBridge.pushAction(from: .standard, to: a, hasExternalDisplay: false) == .apply)
        var c = BatteryPreferences.standard; c.clamshellDischargeEnabled = true
        #expect(BatteryControlBridge.pushAction(from: .standard, to: c, hasExternalDisplay: true) == .apply)
        // 외장 디스플레이가 없으면 클램쉘 옵트인은 설정값을 바꾸지 않는다 → none
        #expect(BatteryControlBridge.pushAction(from: .standard, to: c, hasExternalDisplay: false) == .none)
        var t = BatteryPreferences.standard; t.manualDischargeTarget = 70
        #expect(BatteryControlBridge.pushAction(from: .standard, to: t, hasExternalDisplay: false) == .apply)
    }

    // MARK: - windowPush (디바운스 창)

    /// 250 ms 창 안에서 열 보호를 껐다 켰다(A→B→A) 하면 순변화가 없다. 창의 기준점에서 재면
    /// `.none`이 나온다 — 마지막 `old→new` 쌍으로 재던 예전 방식은 여기서 `.disable`을 내보내
    /// 돌고 있던 수동 방전을 취소했다(`disableAndConfirm`은 `manualDischargeActive: false`를 박아 넣는다).
    @Test func bouncedToggleWithinOneWindowNetsToNothing() {
        var baseline = BatteryPreferences.standard
        baseline.manualDischargeTarget = 70            // 한도는 꺼진 채 수동 방전이 돌고 있는 상태
        var heatOn = baseline; heatOn.heatProtectionEnabled = true   // 창 안 첫 변경: 켰다
        let settled = baseline                                       // 창 안 둘째 변경: 도로 껐다

        // 창의 마지막 `old→new` 쌍만 보면 `.disable`이 나간다 — 그게 고친 결함이다.
        #expect(BatteryControlBridge.pushAction(
            from: heatOn, to: settled, hasExternalDisplay: false) == .disable)

        let decision = BatteryControlBridge.windowPush(
            from: baseline, to: settled, hasExternalDisplay: false)
        #expect(decision.action == .none)
        #expect(decision.limitOptInStarted == false)
        #expect(decision.heatOptInStarted == false)
    }

    /// 하드웨어 미지원 되돌림은 **전이**에만 걸린다. 이미 켜져 있던 한도를 그대로 둔 채 퍼센트만
    /// 바꾼 창은 `.apply`지만 되돌릴 옵트인은 없다 — SMC 프로브가 일시적으로 실패한 순간에
    /// 스위치가 스스로 OFF가 되면 reconcile 루프(저장된 선호값 쪽으로 맞춘다)도 되살리지 못한다.
    @Test func unsupportedRevertOnlyTargetsOptInsStartedInThisWindow() {
        var edited = on; edited.limitPercentage = 85
        let sliderDrag = BatteryControlBridge.windowPush(
            from: on, to: edited, hasExternalDisplay: false)
        #expect(sliderDrag.action == .apply)
        #expect(sliderDrag.limitOptInStarted == false)

        let turnedOn = BatteryControlBridge.windowPush(
            from: .standard, to: on, hasExternalDisplay: false)
        #expect(turnedOn.action == .apply)
        #expect(turnedOn.limitOptInStarted == true)
        #expect(turnedOn.heatOptInStarted == false)

        var heatOn = BatteryPreferences.standard; heatOn.heatProtectionEnabled = true
        let heatTurnedOn = BatteryControlBridge.windowPush(
            from: .standard, to: heatOn, hasExternalDisplay: false)
        #expect(heatTurnedOn.heatOptInStarted == true)
        #expect(heatTurnedOn.limitOptInStarted == false)
    }

    // MARK: - 저장된 방전 기본값

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

        let unwired = BatteryPreferences(
            limitEnabled: true, limitPercentage: 85,
            sailingEnabled: false, sailingDelta: 5,
            heatProtectionEnabled: false, heatProtectionThresholdCelsius: 35,
            autoDischargeEnabled: false, manualDischargeTarget: 80,
            clamshellDischargeEnabled: false
        ).configuration(clamshellDischargeAllowed: false)
        #expect(BatteryControlPolicy.shouldReapply(configuration: unwired, status: status) == true)

        let wired = BatteryPreferences(
            limitEnabled: true, limitPercentage: 85,
            sailingEnabled: false, sailingDelta: 5,
            heatProtectionEnabled: false, heatProtectionThresholdCelsius: 35,
            autoDischargeEnabled: true, manualDischargeTarget: 80,
            clamshellDischargeEnabled: false
        ).configuration(clamshellDischargeAllowed: false)
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

    // MARK: - 토글 푸시가 보존하는 것

    /// A toggle press must not cancel a Top Up or a manual discharge that the daemon is running —
    /// that was the whole reason the handler used to go through `reconcile`. The preservation is
    /// now explicit and pure, so it survives without the `shouldReapply` gate that was swallowing
    /// the user's press.
    @Test func preservingActivityCarriesDaemonTransientStateForward() {
        let requested = BatteryPreferences(
            limitEnabled: true, limitPercentage: 80,
            sailingEnabled: true, sailingDelta: 5,
            heatProtectionEnabled: true, heatProtectionThresholdCelsius: 35,
            autoDischargeEnabled: true, manualDischargeTarget: 80,
            clamshellDischargeEnabled: false
        ).configuration(clamshellDischargeAllowed: false)
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
        let requested = BatteryPreferences(
            limitEnabled: true, limitPercentage: 85,
            sailingEnabled: false, sailingDelta: 5,
            heatProtectionEnabled: false, heatProtectionThresholdCelsius: 35,
            autoDischargeEnabled: true, manualDischargeTarget: 70,
            clamshellDischargeEnabled: false
        ).configuration(clamshellDischargeAllowed: false)
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

    // MARK: - 클램쉘 방전

    /// 데몬이 true를 들고 있고 브리지도 true를 만들면 재적용이 없다. 브리지가 이 값을 빠뜨리면
    /// 매분 재적용이 나서 파일 쓰기와 SMC 판독이 60초마다 반복된다.
    @Test func clamshellAllowanceMismatchIsWhatWouldTriggerAReapply() {
        let daemonConfig = BatteryControlConfiguration(
            enabled: true, limitPercentage: 85, lowerHysteresisDelta: 2,
            clamshellDischargeAllowed: true)
        let status = BatteryControlServiceStatus(
            mode: .inhibited, currentPercentage: 100, isPowerAdapterConnected: true,
            detail: "충전 제한 85% 도달", updatedAt: 100.0,
            desiredConfiguration: daemonConfig,
            capabilities: [.persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1])

        let preferences = BatteryPreferences(
            limitEnabled: true, limitPercentage: 85,
            sailingEnabled: false, sailingDelta: 5,
            heatProtectionEnabled: false, heatProtectionThresholdCelsius: 35,
            autoDischargeEnabled: false, manualDischargeTarget: 80,
            clamshellDischargeEnabled: true)

        let unwired = preferences.configuration(clamshellDischargeAllowed: false)
        #expect(BatteryControlPolicy.shouldReapply(configuration: unwired, status: status) == true)

        let wired = preferences.configuration(clamshellDischargeAllowed: true)
        #expect(BatteryControlPolicy.shouldReapply(configuration: wired, status: status) == false)
    }

    /// 활동 보존은 허용값을 덮어쓰지 않는다 — 허용값은 데몬 활동이 아니라 앱이 계산한 사실이다.
    @Test func preservingActivityKeepsTheRequestedClamshellAllowance() {
        let requested = BatteryControlConfiguration(
            enabled: true, limitPercentage: 80, clamshellDischargeAllowed: true)
        let daemon = BatteryControlConfiguration(
            enabled: true, limitPercentage: 80,
            manualDischargeActive: true, manualDischargeTarget: 70,
            clamshellDischargeAllowed: false)
        let merged = BatteryControlBridge.preservingActivity(requested, daemon: daemon)
        #expect(merged.manualDischargeActive == true)
        #expect(merged.clamshellDischargeAllowed == true)
    }
}

private actor BridgeRequestReceiver {
    var request: BatteryControlClient.BatteryControlClientRequest?
    func set(_ request: BatteryControlClient.BatteryControlClientRequest) {
        self.request = request
    }
}
