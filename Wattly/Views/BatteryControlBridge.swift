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

    private var effectiveDelta: Int {
        Self.effectiveDelta(sailingEnabled: sailingEnabled, sailingDelta: sailingDelta)
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
                Task {
                    await handleConfigChange(val: val, limit: limit, delta: effectiveDelta, heatEnabled: heatProtectionEnabled, heatThreshold: heatProtectionThreshold)
                }
            }
            .onChange(of: limit) { _, val in
                syncMonitorTarget()
                Task {
                    await handleConfigChange(val: enabled, limit: val, delta: effectiveDelta, heatEnabled: heatProtectionEnabled, heatThreshold: heatProtectionThreshold)
                }
            }
            .onChange(of: sailingEnabled) { _, isSailing in
                let delta = isSailing ? sailingDelta : 2
                Task {
                    await handleConfigChange(val: enabled, limit: limit, delta: delta, heatEnabled: heatProtectionEnabled, heatThreshold: heatProtectionThreshold)
                }
            }
            .onChange(of: sailingDelta) { _, newDelta in
                guard sailingEnabled else { return }
                Task {
                    await handleConfigChange(val: enabled, limit: limit, delta: newDelta, heatEnabled: heatProtectionEnabled, heatThreshold: heatProtectionThreshold)
                }
            }
            .onChange(of: heatProtectionEnabled) { _, isHeatEnabled in
                Task {
                    await handleConfigChange(val: enabled, limit: limit, delta: effectiveDelta, heatEnabled: isHeatEnabled, heatThreshold: heatProtectionThreshold)
                }
            }
            .onChange(of: heatProtectionThreshold) { _, threshold in
                Task {
                    await handleConfigChange(val: enabled, limit: limit, delta: effectiveDelta, heatEnabled: heatProtectionEnabled, heatThreshold: threshold)
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
            .task(id: "\(enabled)-\(limit)-\(sailingEnabled)-\(sailingDelta)-\(heatProtectionEnabled)-\(heatProtectionThreshold)") {
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
        if requested.isActive {
            await client.apply(
                enabled: requested.enabled,
                limitPercentage: requested.limitPercentage,
                lowerHysteresisDelta: requested.lowerHysteresisDelta,
                heatProtectionEnabled: requested.heatProtectionEnabled,
                heatProtectionThresholdCelsius: requested.heatProtectionThresholdCelsius)
        } else {
            _ = await client.disableAndConfirm(
                limitPercentage: requested.limitPercentage,
                lowerHysteresisDelta: requested.lowerHysteresisDelta)
        }
    }

    private func handleConfigChange(val: Bool, limit: Int, delta: Int, heatEnabled: Bool, heatThreshold: Int) async {
        if val || heatEnabled {
            await client.apply(
                enabled: val,
                limitPercentage: limit,
                lowerHysteresisDelta: delta,
                heatProtectionEnabled: heatEnabled,
                heatProtectionThresholdCelsius: heatThreshold)
        } else {
            _ = await client.disableAndConfirm(
                limitPercentage: limit,
                lowerHysteresisDelta: delta)
        }
    }

    private func handleWake() async {
        switch Self.wakeAction(configuration: configuration, status: client.status) {
        case .refreshStatus:
            await client.refreshStatus()
        case .apply:
            await client.apply(
                enabled: enabled, limitPercentage: limit,
                lowerHysteresisDelta: effectiveDelta,
                heatProtectionEnabled: heatProtectionEnabled,
                heatProtectionThresholdCelsius: heatProtectionThreshold)
        case .disableAndConfirm:
            let requested = configuration
            _ = await client.disableAndConfirm(
                limitPercentage: requested.limitPercentage,
                lowerHysteresisDelta: requested.lowerHysteresisDelta)
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
            await client.reconcile(
                enabled: enabled,
                limitPercentage: limit,
                lowerHysteresisDelta: effectiveDelta,
                heatProtectionEnabled: heatProtectionEnabled,
                heatProtectionThresholdCelsius: heatProtectionThreshold)
            consecutiveUnsupported = client.status.mode == .unsupported
                ? consecutiveUnsupported + 1
                : 0
            if client.status.isHardwareSupported == false { return }
        }
    }
}
