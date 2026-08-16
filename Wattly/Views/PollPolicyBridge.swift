import SwiftUI

/// Pushes the adaptive-poll policy (issue 09) from preferences into the `SystemMonitor`.
///
/// It lives on the **menubar label** (always rendered), NOT in the popover (which unmounts
/// on close): card-visibility and the cadence setting must reach the monitor even while the
/// panel is closed — that closed steady state is the whole point of the power saving.
///
/// Observed via `VisibilitySettings` to propagate card visibility and menubar selection changes.
struct PollPolicyBridge: View {
    let monitor: SystemMonitor

    @State private var visibilitySettings = VisibilitySettings.shared
    @AppStorage(StorageKey.pollInterval) private var pollInterval: PollInterval = Defaults.pollInterval
    @AppStorage(StorageKey.powerMode) private var powerMode: PowerMode = Defaults.powerMode
    @AppStorage(StorageKey.menubarTextEnabled) private var menubarTextEnabled = Defaults.menubarTextEnabled

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            // Seed the monitor from current settings, THEN start the loop — one task, so the
            // seed lands before the first poll and there's no start()/seed race (B5). The
            // monitor also seeds safe defaults at init, so even an early start() is correct.
            .task {
                monitor.setPowerMode(powerMode)
                monitor.setPollInterval(pollInterval)
                await monitor.setMenubarTextEnabled(menubarTextEnabled)
                await monitor.setShownCards(visibilitySettings.activeCards)
                await monitor.setMenubarMetrics(visibilitySettings.requiredMenuCards)   // before start() (B5): first poll sees the persisted chips
                monitor.start()
            }
            // Live updates only (`.onChange` doesn't fire on first appear, so no redundant
            // re-push of the seed). Async setters hop through a Task; the seeded value already
            // landed above, so ordering here is benign.
            .onChange(of: powerMode) { _, v in monitor.setPowerMode(v) }
            .onChange(of: pollInterval) { _, v in monitor.setPollInterval(v) }
            .onChange(of: menubarTextEnabled) { _, v in Task { await monitor.setMenubarTextEnabled(v) } }
            .onChange(of: visibilitySettings.activeCards) { _, v in Task { await monitor.setShownCards(v) } }
            .onChange(of: visibilitySettings.requiredMenuCards) { _, v in Task { await monitor.setMenubarMetrics(v) } }
    }
}
