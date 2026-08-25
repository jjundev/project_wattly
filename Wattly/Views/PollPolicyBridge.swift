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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visibilitySettings = VisibilitySettings.shared
    @AppStorage(StorageKey.pollInterval) private var pollInterval: PollInterval = Defaults.pollInterval
    @AppStorage(StorageKey.powerMode) private var powerMode: PowerMode = Defaults.powerMode
    @AppStorage(StorageKey.panelMode) private var panelMode: PanelMode = Defaults.panelMode
    @AppStorage(StorageKey.heroMetric) private var heroMetric: CardKind = Defaults.heroMetric
    @AppStorage(StorageKey.cardOrder) private var cardOrder: CardOrder = Defaults.cardOrder
    @AppStorage(StorageKey.menubarTextEnabled) private var menubarTextEnabled = Defaults.menubarTextEnabled
    @AppStorage(StorageKey.kineticNotchMotionEnabled) private var kineticNotchMotionEnabled = Defaults.kineticNotchMotionEnabled
    @AppStorage(StorageKey.kineticNotchSource) private var kineticNotchSource = Defaults.kineticNotchSource

    private var motionMetrics: Set<CardKind> {
        guard kineticNotchMotionEnabled, !reduceMotion else { return [] }
        return kineticNotchSource.requiredCards
    }

    private var resolvedHeroCard: CardKind? {
        guard panelMode == .c else { return nil }
        let visible = cardOrder.visible(present: { monitor.isPresent($0) }, shown: { visibilitySettings.isShown($0) })
        return CardPresentation.resolveHero(persisted: heroMetric, visible: visible)
    }

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
                await monitor.setMenubarMotionMetrics(motionMetrics)
                monitor.setHeroCard(resolvedHeroCard)
                monitor.start()
            }
            // Live updates only (`.onChange` doesn't fire on first appear, so no redundant
            // re-push of the seed). Async setters hop through a Task; the seeded value already
            // landed above, so ordering here is benign.
            .onChange(of: powerMode) { _, v in monitor.setPowerMode(v) }
            .onChange(of: pollInterval) { _, v in monitor.setPollInterval(v) }
            .onChange(of: menubarTextEnabled) { _, v in Task { await monitor.setMenubarTextEnabled(v) } }
            .onChange(of: visibilitySettings.activeCards) { _, v in
                Task {
                    await monitor.setShownCards(v)
                    monitor.setHeroCard(resolvedHeroCard)
                }
            }
            .onChange(of: visibilitySettings.requiredMenuCards) { _, v in Task { await monitor.setMenubarMetrics(v) } }
            .onChange(of: kineticNotchMotionEnabled) { _, _ in Task { await monitor.setMenubarMotionMetrics(motionMetrics) } }
            .onChange(of: kineticNotchSource) { _, _ in Task { await monitor.setMenubarMotionMetrics(motionMetrics) } }
            .onChange(of: reduceMotion) { _, _ in Task { await monitor.setMenubarMotionMetrics(motionMetrics) } }
            .onChange(of: panelMode) { _, _ in monitor.setHeroCard(resolvedHeroCard) }
            .onChange(of: heroMetric) { _, _ in monitor.setHeroCard(resolvedHeroCard) }
            .onChange(of: cardOrder) { _, _ in monitor.setHeroCard(resolvedHeroCard) }
    }
}
