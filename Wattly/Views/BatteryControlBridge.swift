import SwiftUI
import AppKit

struct BatteryControlBridge: View {
    enum WakeAction: Equatable {
        case refreshStatus
        case apply
        case disableAndConfirm
    }

    let client: BatteryControlClient

    @AppStorage(StorageKey.batteryLimitEnabled) private var enabled = Defaults.batteryLimitEnabled
    @AppStorage(StorageKey.batteryLimitPercentage) private var limit = Defaults.batteryLimitPercentage
    @AppStorage(StorageKey.batterySailingEnabled) private var sailingEnabled = Defaults.batterySailingEnabled
    @AppStorage(StorageKey.batterySailingDelta) private var sailingDelta = Defaults.batterySailingDelta

    private var effectiveDelta: Int {
        sailingEnabled ? sailingDelta : 2
    }

    private var configuration: BatteryControlConfiguration {
        BatteryControlConfiguration(
            enabled: enabled,
            limitPercentage: limit,
            lowerHysteresisDelta: effectiveDelta)
    }

    static func wakeAction(
        configuration: BatteryControlConfiguration,
        status: BatteryControlServiceStatus
    ) -> WakeAction {
        if BatteryControlPolicy.supportsPersistentPolicy(status: status) {
            return .refreshStatus
        }
        return configuration.enabled ? .apply : .disableAndConfirm
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task {
                await client.refreshStatus()
                let requested = configuration
                guard BatteryControlPolicy.shouldReapply(
                    configuration: requested, status: client.status) else { return }
                if requested.enabled {
                    await client.apply(
                        enabled: true,
                        limitPercentage: requested.limitPercentage,
                        lowerHysteresisDelta: requested.lowerHysteresisDelta)
                } else {
                    _ = await client.disableAndConfirm(
                        limitPercentage: requested.limitPercentage,
                        lowerHysteresisDelta: requested.lowerHysteresisDelta)
                }
            }
            .onChange(of: enabled) { _, val in
                Task {
                    if val {
                        await client.apply(
                            enabled: true, limitPercentage: limit,
                            lowerHysteresisDelta: effectiveDelta)
                    } else {
                        _ = await client.disableAndConfirm(
                            limitPercentage: limit,
                            lowerHysteresisDelta: effectiveDelta)
                    }
                }
            }
            .onChange(of: limit) { _, val in
                Task {
                    if enabled {
                        await client.apply(
                            enabled: true, limitPercentage: val,
                            lowerHysteresisDelta: effectiveDelta)
                    } else {
                        _ = await client.disableAndConfirm(
                            limitPercentage: val,
                            lowerHysteresisDelta: effectiveDelta)
                    }
                }
            }
            .onChange(of: sailingEnabled) { _, isSailing in
                let delta = isSailing ? sailingDelta : 2
                Task {
                    if enabled {
                        await client.apply(
                            enabled: true, limitPercentage: limit,
                            lowerHysteresisDelta: delta)
                    } else {
                        _ = await client.disableAndConfirm(
                            limitPercentage: limit,
                            lowerHysteresisDelta: delta)
                    }
                }
            }
            .onChange(of: sailingDelta) { _, newDelta in
                guard sailingEnabled else { return }
                Task {
                    if enabled {
                        await client.apply(
                            enabled: true, limitPercentage: limit,
                            lowerHysteresisDelta: newDelta)
                    } else {
                        _ = await client.disableAndConfirm(
                            limitPercentage: limit,
                            lowerHysteresisDelta: newDelta)
                    }
                }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                Task {
                    switch Self.wakeAction(configuration: configuration, status: client.status) {
                    case .refreshStatus:
                        await client.refreshStatus()
                    case .apply:
                        await client.apply(
                            enabled: enabled, limitPercentage: limit,
                            lowerHysteresisDelta: effectiveDelta)
                    case .disableAndConfirm:
                        let requested = configuration
                        _ = await client.disableAndConfirm(
                            limitPercentage: requested.limitPercentage,
                            lowerHysteresisDelta: requested.lowerHysteresisDelta)
                    }
                }
            }
            // The helper restarts with an empty configuration (KeepAlive relaunch, kickstart, a
            // crash) and nothing else would notice: `onChange` needs a user edit, the wake handler
            // needs a sleep. The id covers BOTH values so an edit mid-loop restarts the task —
            // otherwise a stale captured `limit` could be reconciled back over the new one.
            .task(id: "\(enabled)-\(limit)-\(sailingEnabled)-\(sailingDelta)") {
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
                        lowerHysteresisDelta: effectiveDelta)
                    // A Mac that rejects the write will keep rejecting it; back the cadence off
                    // rather than re-arming its budget every minute forever.
                    consecutiveUnsupported = client.status.mode == .unsupported
                        ? consecutiveUnsupported + 1
                        : 0
                    // A Mac with no charge-control register will report the same thing forever, and
                    // the register set is probed once per helper process. Stop rather than back off.
                    if client.status.isHardwareSupported == false { return }
                }
            }
    }
}
