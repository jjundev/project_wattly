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
    }
}
