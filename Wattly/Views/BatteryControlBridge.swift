import SwiftUI
import AppKit

struct BatteryControlBridge: View {
    enum WakeAction: Equatable {
        case refreshStatus
        case apply
        case disableAndConfirm
    }

    let client: BatteryControlClient
    var monitor: SystemMonitor? = nil
    var scheduleCoordinator: BatteryScheduleCoordinator? = nil

    @AppStorage(StorageKey.batteryLimitEnabled) private var enabled = Defaults.batteryLimitEnabled
    @AppStorage(StorageKey.batteryLimitPercentage) private var limit = Defaults.batteryLimitPercentage
    @AppStorage(StorageKey.batterySailingEnabled) private var sailingEnabled = Defaults.batterySailingEnabled
    @AppStorage(StorageKey.batterySailingDelta) private var sailingDelta = Defaults.batterySailingDelta
    @AppStorage(StorageKey.batteryHeatProtectionEnabled) private var heatProtectionEnabled = Defaults.batteryHeatProtectionEnabled
    @AppStorage(StorageKey.batteryHeatProtectionThreshold) private var heatProtectionThreshold = Defaults.batteryHeatProtectionThreshold
    @AppStorage(StorageKey.batteryAutoDischargeEnabled) private var autoDischargeEnabled = Defaults.batteryAutoDischargeEnabled
    @AppStorage(StorageKey.batteryManualDischargeTarget) private var manualDischargeTarget = Defaults.batteryManualDischargeTarget

    @State private var topUpDetector = BatteryTopUpTransitionDetector()
    @State private var topUpExpiryDetector = BatteryTopUpExpiryDetector()

    /// Sailing off means the fixed 2-point hysteresis the daemon assumes by default.
    static func effectiveDelta(sailingEnabled: Bool, sailingDelta: Int) -> Int {
        sailingEnabled ? sailingDelta : 2
    }

    /// Every stored battery preference this bridge is responsible for, assembled in exactly one
    /// place. Pure, so a unit test can prove no `@AppStorage` value is dropped on the way to the
    /// daemon — the omission that had this always-alive bridge reconciling the user's
    /// auto-discharge opt-in back off once a minute. `topUpActive` and `manualDischargeActive` are
    /// deliberately absent: they are transient daemon activity, and `BatteryControlPolicy`
    /// preserves them from the helper's own status rather than from preferences.
    static func makeConfiguration(
        enabled: Bool,
        limitPercentage: Int,
        sailingEnabled: Bool,
        sailingDelta: Int,
        heatProtectionEnabled: Bool,
        heatProtectionThresholdCelsius: Int,
        autoDischargeEnabled: Bool,
        manualDischargeTarget: Int
    ) -> BatteryControlConfiguration {
        BatteryControlConfiguration(
            enabled: enabled,
            limitPercentage: limitPercentage,
            lowerHysteresisDelta: effectiveDelta(
                sailingEnabled: sailingEnabled, sailingDelta: sailingDelta),
            heatProtectionEnabled: heatProtectionEnabled,
            heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
            autoDischargeEnabled: autoDischargeEnabled,
            manualDischargeTarget: manualDischargeTarget)
    }

    /// Folds the daemon's transient activity into a configuration built from stored preferences.
    /// `topUpActive` and `manualDischargeActive` describe what the helper is *doing*, not what the
    /// user chose, so a push driven by a preference change must carry them forward or it cancels
    /// them as a side effect. A running manual discharge also owns its target — the stored
    /// preference must not yank a discharge in progress to a different number. `nil` means the
    /// helper has not answered, and then the request stands exactly as built.
    ///
    /// Unlike `BatteryControlClient.reconcile`, this does NOT compute
    /// `effectiveEnabled = enabled || isTopUp || isManualDischarge` — a caller here forwards
    /// `requested.enabled` as-is. If a Top Up or manual discharge is running while the user's
    /// stored `enabled` preference is off, the two diverge for at most one `reconcileInterval`
    /// tick, which self-corrects through `reconcile`'s own `effectiveEnabled` the next time the
    /// loop runs. Don't re-import that coupling here without re-checking why it was left out.
    static func preservingActivity(
        _ requested: BatteryControlConfiguration,
        daemon desired: BatteryControlConfiguration?
    ) -> BatteryControlConfiguration {
        guard let desired else { return requested }
        var merged = requested
        merged.topUpActive = desired.topUpActive
        merged.manualDischargeActive = desired.manualDischargeActive
        if desired.manualDischargeActive {
            merged.manualDischargeTarget = desired.manualDischargeTarget
        }
        // 캘리브레이션은 세 번째 활동이다. `topUpActive`까지 함께 보존해야 하는 이유는,
        // 절차에서 그 플래그가 "지금이 충전 단계인지"를 뜻하기 때문이다 — 여기서 떨어뜨리면
        // 충전 중이던 절차가 방전 단계로 뒤집힌다.
        merged.calibrationActive = desired.calibrationActive
        if desired.calibrationActive {
            merged.calibrationTargetPercentage = desired.calibrationTargetPercentage
            merged.topUpActive = desired.topUpActive
            merged.manualDischargeActive = false
            merged.enabled = true
            merged.autoDischargeEnabled = false
        }
        return merged
    }

    /// The `.task(id:)` identity for the reconcile loop below. Every preference `makeConfiguration`
    /// takes must appear here too — otherwise a change to that preference never restarts the loop,
    /// and it keeps reconciling the stale value it captured at launch. Pure so a test can catch a
    /// future preference silently missing from this list.
    static func reconcileTaskID(
        enabled: Bool,
        limitPercentage: Int,
        sailingEnabled: Bool,
        sailingDelta: Int,
        heatProtectionEnabled: Bool,
        heatProtectionThresholdCelsius: Int,
        autoDischargeEnabled: Bool,
        manualDischargeTarget: Int
    ) -> String {
        "\(enabled)-\(limitPercentage)-\(sailingEnabled)-\(sailingDelta)-\(heatProtectionEnabled)-\(heatProtectionThresholdCelsius)-\(autoDischargeEnabled)-\(manualDischargeTarget)"
    }

    private var configuration: BatteryControlConfiguration {
        Self.makeConfiguration(
            enabled: enabled,
            limitPercentage: limit,
            sailingEnabled: sailingEnabled,
            sailingDelta: sailingDelta,
            heatProtectionEnabled: heatProtectionEnabled,
            heatProtectionThresholdCelsius: heatProtectionThreshold,
            autoDischargeEnabled: autoDischargeEnabled,
            manualDischargeTarget: manualDischargeTarget)
    }

    private func syncMonitorTarget() {
        let isTopUp = client.status.desiredConfiguration?.topUpActive == true || client.status.activity == .topUp
        monitor?.setBatteryChargeTarget(enabled: enabled, limitPercentage: limit, topUpActive: isTopUp)
    }

    /// Pure so it can be tested outside the loop, and separate from the loop so it stays that way:
    /// the reconcile loop is the only thing that repairs divergence between stored preferences and
    /// the daemon's policy, nothing restarts it, and it must never `return` on unsupported
    /// hardware — only back off. An earlier version of this loop did exit on `.unsupported`, which
    /// killed all repair for the process lifetime; keeping the streak decision here, isolated and
    /// tested, is what stops that regression from silently coming back inline. `nil` hardware
    /// support means "the helper hasn't answered", not "unsupported", so it must not count.
    static func unsupportedStreak(
        _ current: Int,
        mode: BatteryControlServiceMode,
        isHardwareSupported: Bool?
    ) -> Int {
        let isUnsupported = mode == .unsupported || isHardwareSupported == false
        return isUnsupported ? current + 1 : 0
    }

    static func wakeAction(
        configuration: BatteryControlConfiguration,
        status: BatteryControlServiceStatus
    ) -> WakeAction {
        if BatteryControlPolicy.supportsPersistentPolicy(status: status) {
            return .refreshStatus
        }
        return configuration.isActive ? .apply : .disableAndConfirm
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task {
                await handleInitialTask()
            }
            .onChange(of: enabled) { _, val in
                syncMonitorTarget()
                let requested = Self.makeConfiguration(
                    enabled: val,
                    limitPercentage: limit,
                    sailingEnabled: sailingEnabled,
                    sailingDelta: sailingDelta,
                    heatProtectionEnabled: heatProtectionEnabled,
                    heatProtectionThresholdCelsius: heatProtectionThreshold,
                    autoDischargeEnabled: autoDischargeEnabled,
                    manualDischargeTarget: manualDischargeTarget)
                Task {
                    await handleConfigChange(requested, reason: "enabled-change")
                }
            }
            .onChange(of: limit) { _, val in
                syncMonitorTarget()
                let requested = Self.makeConfiguration(
                    enabled: enabled,
                    limitPercentage: val,
                    sailingEnabled: sailingEnabled,
                    sailingDelta: sailingDelta,
                    heatProtectionEnabled: heatProtectionEnabled,
                    heatProtectionThresholdCelsius: heatProtectionThreshold,
                    autoDischargeEnabled: autoDischargeEnabled,
                    manualDischargeTarget: manualDischargeTarget)
                Task {
                    await handleConfigChange(requested, reason: "limit-change")
                }
            }
            .onChange(of: sailingEnabled) { _, isSailing in
                let requested = Self.makeConfiguration(
                    enabled: enabled,
                    limitPercentage: limit,
                    sailingEnabled: isSailing,
                    sailingDelta: sailingDelta,
                    heatProtectionEnabled: heatProtectionEnabled,
                    heatProtectionThresholdCelsius: heatProtectionThreshold,
                    autoDischargeEnabled: autoDischargeEnabled,
                    manualDischargeTarget: manualDischargeTarget)
                Task {
                    await handleConfigChange(requested, reason: "sailing-enabled-change")
                }
            }
            .onChange(of: sailingDelta) { _, newDelta in
                guard sailingEnabled else { return }
                let requested = Self.makeConfiguration(
                    enabled: enabled,
                    limitPercentage: limit,
                    sailingEnabled: true,
                    sailingDelta: newDelta,
                    heatProtectionEnabled: heatProtectionEnabled,
                    heatProtectionThresholdCelsius: heatProtectionThreshold,
                    autoDischargeEnabled: autoDischargeEnabled,
                    manualDischargeTarget: manualDischargeTarget)
                Task {
                    await handleConfigChange(requested, reason: "sailing-delta-change")
                }
            }
            .onChange(of: heatProtectionEnabled) { _, isHeatEnabled in
                let requested = Self.makeConfiguration(
                    enabled: enabled,
                    limitPercentage: limit,
                    sailingEnabled: sailingEnabled,
                    sailingDelta: sailingDelta,
                    heatProtectionEnabled: isHeatEnabled,
                    heatProtectionThresholdCelsius: heatProtectionThreshold,
                    autoDischargeEnabled: autoDischargeEnabled,
                    manualDischargeTarget: manualDischargeTarget)
                Task {
                    await handleConfigChange(requested, reason: "heat-protection-enabled-change")
                }
            }
            .onChange(of: heatProtectionThreshold) { _, threshold in
                let requested = Self.makeConfiguration(
                    enabled: enabled,
                    limitPercentage: limit,
                    sailingEnabled: sailingEnabled,
                    sailingDelta: sailingDelta,
                    heatProtectionEnabled: heatProtectionEnabled,
                    heatProtectionThresholdCelsius: threshold,
                    autoDischargeEnabled: autoDischargeEnabled,
                    manualDischargeTarget: manualDischargeTarget)
                Task {
                    await handleConfigChange(requested, reason: "heat-protection-threshold-change")
                }
            }
            // A toggle the user just pressed is an explicit instruction, so it pushes
            // unconditionally. It deliberately does NOT go through `reconcile`: that path writes
            // only if `BatteryControlPolicy.shouldReapply` agrees, and a repair predicate deciding
            // "the daemon already matches" is right for a background pass and wrong for a button —
            // the press would vanish with nothing shown to the user. Preservation of a running Top
            // Up or manual discharge, which is why this once used `reconcile`, is now explicit via
            // `preservingActivity` over a freshly read status, inside `applyRequested`.
            //
            // KNOWN RACE (not fixed here — needs a design decision): with the Settings window
            // open, this handler and `SettingsBatterySection`'s own `.onChange(of:
            // autoDischargeEnabled)` both fire off unstructured `Task {}` writes for the same
            // toggle flip. `SettingsBatterySection` calls `batteryControl.setAutoDischarge(...)`,
            // which hardcodes `topUpActive: false, manualDischargeActive: false` — it does not
            // preserve daemon activity the way `applyRequested` does here. Neither write is
            // ordered against the other, and this handler's `await client.refreshStatus()` yields,
            // so a bad interleaving can have the Settings write cancel a running Top Up and then
            // have this handler's stale-read merge resurrect it (or vice versa). Making the bridge
            // the single writer would close this, but that is a design choice the user has not
            // made yet — see the plan-13-settings findings memory note.
            .onChange(of: autoDischargeEnabled) { _, isAutoDischarge in
                let requested = Self.makeConfiguration(
                    enabled: enabled,
                    limitPercentage: limit,
                    sailingEnabled: sailingEnabled,
                    sailingDelta: sailingDelta,
                    heatProtectionEnabled: heatProtectionEnabled,
                    heatProtectionThresholdCelsius: heatProtectionThreshold,
                    autoDischargeEnabled: isAutoDischarge,
                    manualDischargeTarget: manualDischargeTarget)
                Task {
                    await applyRequested(requested, reason: "auto-discharge-toggle")
                }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                Task {
                    await handleWake()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in
                Task {
                    if let scheduleCoordinator {
                        await scheduleCoordinator.evaluateSchedules(at: Date(), isWake: false)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                Task {
                    if let scheduleCoordinator {
                        await scheduleCoordinator.evaluateSchedules(at: Date(), isWake: false)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                Task {
                    if let scheduleCoordinator {
                        await scheduleCoordinator.evaluateSchedules(at: Date(), isWake: false)
                    }
                }
            }
            // The loop body reads the `self` captured when the task started, so every preference
            // it forwards must appear here — otherwise it reconciles stale values forever.
            .task(id: Self.reconcileTaskID(
                enabled: enabled,
                limitPercentage: limit,
                sailingEnabled: sailingEnabled,
                sailingDelta: sailingDelta,
                heatProtectionEnabled: heatProtectionEnabled,
                heatProtectionThresholdCelsius: heatProtectionThreshold,
                autoDischargeEnabled: autoDischargeEnabled,
                manualDischargeTarget: manualDischargeTarget)) {
                await handleReconcileLoop()
            }
            .onChange(of: client.status) { _, newStatus in
                syncMonitorTarget()
                if topUpDetector.update(reasonKind: newStatus.detailReason?.kind) {
                    BatteryNotificationManager.postTopUpCompleteNotification()
                }
                // 헬퍼가 스스로 Top Up을 끝낸 경우에만 참이 된다. 사용자가 버튼으로 취소한
                // 경우와 만료 후 상태가 동일하기 때문에 유지보수 레코드로 구분한다.
                // 캘리브레이션은 100% 홀드 단계에서 같은 `topUpActive`를 빌려 쓴다. 만료
                // 자체는 데몬이 막지만(`BatteryTopUpExpiry.decide(calibrationActive:)`),
                // 절차 직전에 남아 있던 레코드가 신선도 창 안에서 뒤늦게 뜨는 경우가 있다.
                // 감지기는 항상 돌려 레코드를 소비시키고, 알림만 건너뛴다.
                let didExpire = topUpExpiryDetector.update(
                    record: newStatus.lastMaintenance,
                    now: Date().timeIntervalSince1970)
                if didExpire, newStatus.desiredConfiguration?.calibrationActive != true {
                    BatteryNotificationManager.postTopUpExpiredNotification()
                }
            }
    }

    private func handleInitialTask() async {
        syncMonitorTarget()
        await client.refreshStatus()
        syncMonitorTarget()
        let requested = configuration
        let shouldReapply = BatteryControlPolicy.shouldReapply(
            configuration: requested, status: client.status)
        BatteryControlLog.battery.notice(
            "initial task verdict: shouldReapply=\(shouldReapply) requestedAutoDischarge=\(requested.autoDischargeEnabled)")
        guard shouldReapply else { return }
        await push(requested, reason: "initial")
    }

    private func handleConfigChange(_ requested: BatteryControlConfiguration, reason: StaticString) async {
        await push(requested, reason: reason)
    }

    private func handleWake() async {
        let requested = configuration
        switch Self.wakeAction(configuration: requested, status: client.status) {
        case .refreshStatus:
            await client.refreshStatus()
        case .apply:
            await applyRequested(requested, reason: "wake")
        case .disableAndConfirm:
            await disableRequested(requested, reason: "wake")
        }
        if let scheduleCoordinator {
            await scheduleCoordinator.evaluateSchedules(at: Date(), isWake: true)
        }
    }

    private func handleReconcileLoop() async {
        var consecutiveUnsupported = 0
        BatteryControlLog.battery.notice("reconcile loop started")
        while !Task.isCancelled {
            try? await Task.sleep(
                for: .seconds(BatteryControlPolicy.reconcileInterval(
                    consecutiveUnsupported: consecutiveUnsupported))
            )
            guard !Task.isCancelled else {
                BatteryControlLog.battery.notice("reconcile loop cancelled")
                return
            }
            let requested = configuration
            BatteryControlLog.battery.notice(
                """
                reconcile tick: enabled=\(requested.enabled) limit=\(requested.limitPercentage) \
                autoDischarge=\(requested.autoDischargeEnabled) \
                manualTarget=\(requested.manualDischargeTarget) \
                mode=\(String(describing: client.status.mode), privacy: .public) \
                unsupportedStreak=\(consecutiveUnsupported)
                """)
            await client.reconcile(
                enabled: requested.enabled,
                limitPercentage: requested.limitPercentage,
                lowerHysteresisDelta: requested.lowerHysteresisDelta,
                heatProtectionEnabled: requested.heatProtectionEnabled,
                heatProtectionThresholdCelsius: requested.heatProtectionThresholdCelsius,
                autoDischargeEnabled: requested.autoDischargeEnabled,
                manualDischargeTarget: requested.manualDischargeTarget)
            // `isHardwareSupported == false` also feeds the backoff counter below: a daemon that
            // relaunches with a transiently failing SMC probe must not kill this loop for the
            // process lifetime — that leaves a divergence (e.g. the user's auto-discharge opt-in)
            // unrepaired forever, even after the daemon comes back healthy. Back off instead of
            // exiting, same as the `.unsupported` mode case. See `unsupportedStreak` for why this
            // decision lives in a pure, tested function rather than inline here.
            consecutiveUnsupported = Self.unsupportedStreak(
                consecutiveUnsupported,
                mode: client.status.mode,
                isHardwareSupported: client.status.isHardwareSupported)
            if client.status.isHardwareSupported == false {
                BatteryControlLog.battery.notice(
                    "reconcile loop backing off: hardware unsupported, streak=\(consecutiveUnsupported)")
            }
        }
        BatteryControlLog.battery.notice("reconcile loop ended: task cancelled")
    }

    /// The one place a bridge-built configuration turns into a daemon write. An inactive policy
    /// still carries the discharge preferences: the helper persists them, so the user's target
    /// survives the limit being switched off and back on. `reason` identifies the caller in the
    /// OSLog trail and is simply forwarded — see `applyRequested`.
    private func push(_ requested: BatteryControlConfiguration, reason: StaticString) async {
        if requested.enabled || requested.heatProtectionEnabled {
            await applyRequested(requested, reason: reason)
        } else {
            await disableRequested(requested, reason: reason)
        }
    }

    /// Reads the daemon's current status and folds its transient activity into `requested` before
    /// writing, via `preservingActivity` — without this, any push through here (a limit edit, a
    /// wake-triggered apply, the auto-discharge toggle) would default `topUpActive` and
    /// `manualDischargeActive` to `false` and silently cancel a Top Up or manual discharge in
    /// progress. Forwards all nine `BatteryControlConfiguration` fields so nothing the merge
    /// produced is dropped on the way to `client.apply`.
    ///
    /// `reason` names the call site in the log line so a field log can identify which of the
    /// several paths that share this function — a toggle, a limit edit, a wake — actually wrote to
    /// the daemon. `StaticString` because it is always a source-literal label, never user data, so
    /// it needs no `privacy:` annotation and cannot leak anything even if one is omitted.
    private func applyRequested(_ requested: BatteryControlConfiguration, reason: StaticString) async {
        await client.refreshStatus()
        let merged = Self.preservingActivity(
            requested, daemon: client.status.desiredConfiguration)
        BatteryControlLog.battery.notice(
            "applyRequested push: reason=\(reason, privacy: .public) autoDischarge=\(merged.autoDischargeEnabled) topUp=\(merged.topUpActive) manualActive=\(merged.manualDischargeActive)")
        let result = await client.apply(
            enabled: merged.enabled,
            limitPercentage: merged.limitPercentage,
            lowerHysteresisDelta: merged.lowerHysteresisDelta,
            heatProtectionEnabled: merged.heatProtectionEnabled,
            heatProtectionThresholdCelsius: merged.heatProtectionThresholdCelsius,
            topUpActive: merged.topUpActive,
            autoDischargeEnabled: merged.autoDischargeEnabled,
            manualDischargeActive: merged.manualDischargeActive,
            manualDischargeTarget: merged.manualDischargeTarget)
        BatteryControlLog.battery.notice(
            "applyRequested result: reason=\(reason, privacy: .public) accepted=\(result != nil)")
    }

    /// Same caller-identity treatment as `applyRequested`: this is reached from more than one
    /// place (`push`, and directly from `handleWake`'s `.disableAndConfirm` case), so the disable
    /// path needs to be just as identifiable in the log trail.
    private func disableRequested(_ requested: BatteryControlConfiguration, reason: StaticString) async {
        BatteryControlLog.battery.notice(
            "disableRequested push: reason=\(reason, privacy: .public) limit=\(requested.limitPercentage) autoDischarge=\(requested.autoDischargeEnabled)")
        let result = await client.disableAndConfirm(
            limitPercentage: requested.limitPercentage,
            lowerHysteresisDelta: requested.lowerHysteresisDelta,
            autoDischargeEnabled: requested.autoDischargeEnabled,
            manualDischargeTarget: requested.manualDischargeTarget)
        BatteryControlLog.battery.notice(
            "disableRequested result: reason=\(reason, privacy: .public) accepted=\(result != nil)")
    }
}
