import Testing
@testable import Wattly

@MainActor
struct MenuBarSnapshotTests {
    actor CPUOnce: MetricProvider {
        let kind: ProviderKind = .cpu
        func read(at instant: ContinuousClock.Instant) async -> ProviderReading {
            .value(.cpu(CPUSample(overall: 41.6, perfLevels: [])))
        }
    }

    @Test func snapshotCarriesVisibleAndAccessibilityText() async {
        let monitor = SystemMonitor(providers: [CPUOnce()], clock: ManualClock())
        await monitor.setShownCards([])
        await monitor.setMenubarMetrics([.cpu])
        await monitor.poll(targets: [.cpu])

        #expect(monitor.menuBarSnapshot.visibleText == "CPU 42%")
        #expect(monitor.menuBarSnapshot.accessibilityLabel == "Wattly, CPU 42%")
    }

    @Test func textOffKeepsAccessibilityFresh() async {
        let monitor = SystemMonitor(providers: [CPUOnce()], clock: ManualClock())
        await monitor.setShownCards([])
        await monitor.setMenubarMetrics([.cpu])
        await monitor.setMenubarTextEnabled(false)
        await monitor.poll(targets: [.cpu])

        #expect(monitor.menuBarSnapshot.visibleText == nil)
        #expect(monitor.menuBarSnapshot.accessibilityLabel == "Wattly, CPU 42%")
    }
}
