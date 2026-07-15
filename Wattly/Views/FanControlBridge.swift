import SwiftUI

/// Keeps fan-control configuration and its fail-safe heartbeat alive with the menu-bar label.
/// Settings and the popover may unmount freely: neither owns the helper connection or sends a
/// release merely because its UI disappears.
struct FanControlBridge: View {
    let client: FanControlClient

    @AppStorage(StorageKey.fanControlEnabled) private var enabled = Defaults.fanControlEnabled
    @AppStorage(StorageKey.fanCurve) private var curve = Defaults.fanCurve

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task {
                await client.apply(enabled: enabled, curve: curve)
            }
            .onChange(of: enabled) { _, value in
                Task { await client.apply(enabled: value, curve: curve) }
            }
            .onChange(of: curve) { _, value in
                Task { await client.apply(enabled: enabled, curve: value) }
            }
            .task(id: enabled) {
                guard enabled else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(FanControlPolicy.heartbeatCheckInterval))
                    guard !Task.isCancelled else { return }
                    await client.heartbeat()
                }
            }
    }
}
