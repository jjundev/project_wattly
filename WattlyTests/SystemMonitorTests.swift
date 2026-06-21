import Testing
import Foundation
@testable import Wattly

/// Proves the single seam: a scripted fake provider + a manual clock drive the
/// model with no hardware (PRD Testing Decisions; issue 18).
@MainActor
struct SystemMonitorTests {
    /// A provider that returns a scripted sequence, repeating its last reading.
    actor ScriptedProvider: MetricProvider {
        let kind: ProviderKind
        private var queue: [ProviderReading]
        private let last: ProviderReading

        init(kind: ProviderKind, _ readings: [ProviderReading]) {
            self.kind = kind
            self.queue = readings
            self.last = readings.last ?? .pending
        }

        func read(at instant: ContinuousClock.Instant) async -> ProviderReading {
            queue.isEmpty ? last : queue.removeFirst()
        }
    }

    @Test func loadingThenValueTransition() async {
        let value = MetricSample.cpu(CPUSample(overall: 42, perfLevels: []))
        let cpu = ScriptedProvider(kind: .cpu, [.pending, .value(value)])
        let monitor = SystemMonitor(providers: [cpu], clock: ManualClock())

        await monitor.pollOnce()
        #expect(monitor.cardState(.cpu) == .loading)

        await monitor.pollOnce()
        #expect(monitor.cardState(.cpu) == .value(value))
    }

    @Test func partialFailureIsolation() async {
        let power = ScriptedProvider(kind: .power, [.unavailable(.channelUnreadable("x"))])
        let cpu = ScriptedProvider(kind: .cpu, [.value(.cpu(CPUSample(overall: 50, perfLevels: [])))])
        let monitor = SystemMonitor(providers: [power, cpu], clock: ManualClock())

        await monitor.pollOnce()

        guard case .unavailable = monitor.cardState(.power) else {
            Issue.record("power should be unavailable"); return
        }
        guard case .value = monitor.cardState(.cpu) else {
            Issue.record("cpu should keep its value despite power failing"); return
        }
    }

    @Test func temperatureFanOutIsolatesCategories() async {
        let snap = TemperatureSnapshot(
            cpu: .reading(TemperatureReading(celsius: 60)),
            gpu: .unavailable(.noVerifiedProfile),
            battery: .reading(TemperatureReading(celsius: 31)))
        let temp = ScriptedProvider(kind: .temperature, [.value(.temperature(snap))])
        let monitor = SystemMonitor(providers: [temp], clock: ManualClock())

        await monitor.pollOnce()

        guard case .value = monitor.cardState(.cpuTemp) else {
            Issue.record("cpuTemp should have a value"); return
        }
        guard case .unavailable(.temperature(.noVerifiedProfile)) = monitor.cardState(.gpuTemp) else {
            Issue.record("gpuTemp should be unavailable without affecting cpuTemp"); return
        }
        guard case .value = monitor.cardState(.batTemp) else {
            Issue.record("batTemp should have a value"); return
        }
    }

    @Test func desktopBatteryIsHidden() async {
        let battery = ScriptedProvider(kind: .battery, [.unavailable(.notPresent("배터리 없음 — 데스크톱 Mac"))])
        let monitor = SystemMonitor(providers: [battery], clock: ManualClock())

        await monitor.pollOnce()
        #expect(monitor.isPresent(.battery) == false)
    }
}
