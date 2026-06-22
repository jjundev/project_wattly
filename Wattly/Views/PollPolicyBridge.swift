import SwiftUI

/// Pushes the adaptive-poll policy (issue 09) from `@AppStorage` into the `SystemMonitor`.
///
/// It lives on the **menubar label** (always rendered), NOT in the popover (which unmounts
/// on close): card-visibility and the cadence setting must reach the monitor even while the
/// panel is closed — that closed steady state is the whole point of the power saving. Being
/// `@AppStorage`-backed, it observes external writes (the settings window today, issue 13's
/// per-card toggles and issue 14's menubar metrics later) via KVO, so the gating activates
/// automatically the moment those keys change — no extra wiring in 13/14.
///
/// Renders nothing (a zero-size clear view); it exists only to host the seeding `.task` and
/// the live-update observers.
struct PollPolicyBridge: View {
    let monitor: SystemMonitor

    @AppStorage(StorageKey.pollInterval) private var pollInterval: PollInterval = Defaults.pollInterval
    @AppStorage(StorageKey.menubarTextEnabled) private var menubarTextEnabled = Defaults.menubarTextEnabled
    @AppStorage(StorageKey.show(.power))   private var showPower   = Defaults.show[.power]   ?? true
    @AppStorage(StorageKey.show(.battery)) private var showBattery = Defaults.show[.battery] ?? true
    @AppStorage(StorageKey.show(.cpu))     private var showCPU     = Defaults.show[.cpu]     ?? true
    @AppStorage(StorageKey.show(.mem))     private var showMem     = Defaults.show[.mem]     ?? true
    @AppStorage(StorageKey.show(.cpuTemp)) private var showCpuTemp = Defaults.show[.cpuTemp] ?? true
    @AppStorage(StorageKey.show(.gpuTemp)) private var showGpuTemp = Defaults.show[.gpuTemp] ?? true
    @AppStorage(StorageKey.show(.batTemp)) private var showBatTemp = Defaults.show[.batTemp] ?? true

    /// The shown set, assembled from the per-card flags (mirrors `PopoverContentView.isShown`).
    private var shownCards: Set<CardKind> {
        var s = Set<CardKind>()
        if showPower   { s.insert(.power) }
        if showBattery { s.insert(.battery) }
        if showCPU     { s.insert(.cpu) }
        if showMem     { s.insert(.mem) }
        if showCpuTemp { s.insert(.cpuTemp) }
        if showGpuTemp { s.insert(.gpuTemp) }
        if showBatTemp { s.insert(.batTemp) }
        return s
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            // Seed the monitor from current settings, THEN start the loop — one task, so the
            // seed lands before the first poll and there's no start()/seed race (B5). The
            // monitor also seeds safe defaults at init, so even an early start() is correct.
            .task {
                monitor.setPollInterval(pollInterval)
                await monitor.setMenubarTextEnabled(menubarTextEnabled)
                await monitor.setShownCards(shownCards)
                monitor.start()
            }
            // Live updates only (`.onChange` doesn't fire on first appear, so no redundant
            // re-push of the seed). Async setters hop through a Task; the seeded value already
            // landed above, so ordering here is benign.
            .onChange(of: pollInterval) { _, v in monitor.setPollInterval(v) }
            .onChange(of: menubarTextEnabled) { _, v in Task { await monitor.setMenubarTextEnabled(v) } }
            .onChange(of: shownCards) { _, v in Task { await monitor.setShownCards(v) } }
    }
}
