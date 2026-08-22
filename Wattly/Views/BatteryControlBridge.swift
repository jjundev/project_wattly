import SwiftUI
import AppKit

struct BatteryControlBridge: View {
    let client: BatteryControlClient

    @AppStorage(StorageKey.batteryLimitEnabled) private var enabled = Defaults.batteryLimitEnabled
    @AppStorage(StorageKey.batteryLimitPercentage) private var limit = Defaults.batteryLimitPercentage

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            // Unconditional on purpose, unlike the fan bridge: a helper that survived the last app
            // session may still be holding an inhibit the user has since switched off, and this is
            // the push that clears it.
            .task {
                await client.apply(enabled: enabled, limitPercentage: limit)
            }
            .onChange(of: enabled) { _, val in
                Task { await client.apply(enabled: val, limitPercentage: limit) }
            }
            .onChange(of: limit) { _, val in
                Task { await client.apply(enabled: enabled, limitPercentage: val) }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                Task { await client.apply(enabled: enabled, limitPercentage: limit) }
            }
            // The helper restarts with an empty configuration (KeepAlive relaunch, kickstart, a
            // crash) and nothing else would notice: `onChange` needs a user edit, the wake handler
            // needs a sleep. The id covers BOTH values so an edit mid-loop restarts the task —
            // otherwise a stale captured `limit` could be reconciled back over the new one.
            .task(id: "\(enabled)-\(limit)") {
                guard enabled else { return }
                var consecutiveUnsupported = 0
                while !Task.isCancelled {
                    try? await Task.sleep(
                        for: .seconds(BatteryControlPolicy.reconcileInterval(
                            consecutiveUnsupported: consecutiveUnsupported))
                    )
                    guard !Task.isCancelled else { return }
                    await client.reconcile(enabled: enabled, limitPercentage: limit)
                    // A Mac that rejects the write will keep rejecting it; back the cadence off
                    // rather than re-arming its budget every minute forever.
                    consecutiveUnsupported = client.status.mode == .unsupported
                        ? consecutiveUnsupported + 1
                        : 0
                }
            }
    }
}
