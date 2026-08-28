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
                    await handleConfigChange(requested)
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
                    await handleConfigChange(requested)
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
                    await handleConfigChange(requested)
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
                    await handleConfigChange(requested)
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
                    await handleConfigChange(requested)
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
                    await handleConfigChange(requested)
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
                    await applyRequested(requested)
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
        await push(requested)
    }

    private func handleConfigChange(_ requested: BatteryControlConfiguration) async {
        await push(requested)
    }

    private func handleWake() async {
        let requested = configuration
        switch Self.wakeAction(configuration: requested, status: client.status) {
        case .refreshStatus:
            await client.refreshStatus()
        case .apply:
            await applyRequested(requested)
        case .disableAndConfirm:
            await disableRequested(requested)
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
            // exiting, same as the `.unsupported` mode case.
            let isUnsupported = client.status.mode == .unsupported
                || client.status.isHardwareSupported == false
            consecutiveUnsupported = isUnsupported ? consecutiveUnsupported + 1 : 0
            if client.status.isHardwareSupported == false {
                BatteryControlLog.battery.notice(
                    "reconcile loop backing off: hardware unsupported, streak=\(consecutiveUnsupported)")
            }
        }
        BatteryControlLog.battery.notice("reconcile loop ended: task cancelled")
    }

    /// The one place a bridge-built configuration turns into a daemon write. An inactive policy
    /// still carries the discharge preferences: the helper persists them, so the user's target
    /// survives the limit being switched off and back on.
    private func push(_ requested: BatteryControlConfiguration) async {
        if requested.enabled || requested.heatProtectionEnabled {
            await applyRequested(requested)
        } else {
            await disableRequested(requested)
        }
    }

    /// Reads the daemon's current status and folds its transient activity into `requested` before
    /// writing, via `preservingActivity` — without this, any push through here (a limit edit, a
    /// wake-triggered apply, the auto-discharge toggle) would default `topUpActive` and
    /// `manualDischargeActive` to `false` and silently cancel a Top Up or manual discharge in
    /// progress. Forwards all nine `BatteryControlConfiguration` fields so nothing the merge
    /// produced is dropped on the way to `client.apply`.
    private func applyRequested(_ requested: BatteryControlConfiguration) async {
        await client.refreshStatus()
        let merged = Self.preservingActivity(
            requested, daemon: client.status.desiredConfiguration)
        BatteryControlLog.battery.notice(
            "applyRequested push: autoDischarge=\(merged.autoDischargeEnabled) topUp=\(merged.topUpActive) manualActive=\(merged.manualDischargeActive)")
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
            "applyRequested result: accepted=\(result != nil)")
    }

    private func disableRequested(_ requested: BatteryControlConfiguration) async {
        _ = await client.disableAndConfirm(
            limitPercentage: requested.limitPercentage,
            lowerHysteresisDelta: requested.lowerHysteresisDelta,
            autoDischargeEnabled: requested.autoDischargeEnabled,
            manualDischargeTarget: requested.manualDischargeTarget)
    }
}
