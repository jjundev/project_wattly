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

    @Test func batteryPlugInResetsHistory() async {
        // On battery (discharging), then the adapter is plugged in → ExternalConnected
        // flips → the battery sparkline resets at once (not when the lagging current
        // catches up 30–60 s later). Issue 07 §2.
        let onBattery = MetricSample.battery(BatterySample(
            netW: 9.6, milliamps: 754, volts: 12.7, charging: false, externalConnected: false))
        let pluggedIn = MetricSample.battery(BatterySample(
            netW: -13.4, milliamps: 1098, volts: 12.2, charging: true, externalConnected: true))
        let battery = ScriptedProvider(kind: .battery, [.value(onBattery), .value(onBattery), .value(pluggedIn)])
        let clock = ManualClock()
        let monitor = SystemMonitor(providers: [battery], clock: clock)

        await monitor.pollOnce()                 // on battery → [9.6]
        clock.advance(by: .seconds(2))
        await monitor.pollOnce()                 // still on battery (no plug change) → [9.6, 9.6]
        #expect(monitor.history[.battery]?.values == [9.6, 9.6])

        clock.advance(by: .seconds(2))
        await monitor.pollOnce()                 // plugged in (ExternalConnected flip) → reset → [-13.4]
        #expect(monitor.history[.battery]?.values == [-13.4])
    }
}
