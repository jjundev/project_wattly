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
            // Auto-discharge is a user setting, not transient activity, so nothing in
            // `BatteryControlPolicy` preserves it for us — flipping it has to push. `reconcile`
            // rather than `apply`: it reads the helper first, so it keeps a running Top Up or
            // manual discharge intact and writes nothing at all when the settings screen already
            // pushed the same change a moment ago.
            .onChange(of: autoDischargeEnabled) { _, isAutoDischarge in
                Task {
                    await client.reconcile(
                        enabled: enabled,
                        limitPercentage: limit,
                        lowerHysteresisDelta: Self.effectiveDelta(
                            sailingEnabled: sailingEnabled, sailingDelta: sailingDelta),
                        heatProtectionEnabled: heatProtectionEnabled,
                        heatProtectionThresholdCelsius: heatProtectionThreshold,
                        autoDischargeEnabled: isAutoDischarge,
                        manualDischargeTarget: manualDischargeTarget)
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
            .task(id: "\(enabled)-\(limit)-\(sailingEnabled)-\(sailingDelta)-\(heatProtectionEnabled)-\(heatProtectionThreshold)-\(autoDischargeEnabled)-\(manualDischargeTarget)") {
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
        guard BatteryControlPolicy.shouldReapply(
            configuration: requested, status: client.status) else { return }
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
        while !Task.isCancelled {
            try? await Task.sleep(
                for: .seconds(BatteryControlPolicy.reconcileInterval(
                    consecutiveUnsupported: consecutiveUnsupported))
            )
            guard !Task.isCancelled else { return }
            let requested = configuration
            await client.reconcile(
                enabled: requested.enabled,
                limitPercentage: requested.limitPercentage,
                lowerHysteresisDelta: requested.lowerHysteresisDelta,
                heatProtectionEnabled: requested.heatProtectionEnabled,
                heatProtectionThresholdCelsius: requested.heatProtectionThresholdCelsius,
                autoDischargeEnabled: requested.autoDischargeEnabled,
                manualDischargeTarget: requested.manualDischargeTarget)
            consecutiveUnsupported = client.status.mode == .unsupported
                ? consecutiveUnsupported + 1
                : 0
            if client.status.isHardwareSupported == false { return }
        }
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

    private func applyRequested(_ requested: BatteryControlConfiguration) async {
        await client.apply(
            enabled: requested.enabled,
            limitPercentage: requested.limitPercentage,
            lowerHysteresisDelta: requested.lowerHysteresisDelta,
            heatProtectionEnabled: requested.heatProtectionEnabled,
            heatProtectionThresholdCelsius: requested.heatProtectionThresholdCelsius,
            autoDischargeEnabled: requested.autoDischargeEnabled,
            manualDischargeTarget: requested.manualDischargeTarget)
    }

    private func disableRequested(_ requested: BatteryControlConfiguration) async {
        _ = await client.disableAndConfirm(
            limitPercentage: requested.limitPercentage,
            lowerHysteresisDelta: requested.lowerHysteresisDelta,
            autoDischargeEnabled: requested.autoDischargeEnabled,
            manualDischargeTarget: requested.manualDischargeTarget)
    }
}
