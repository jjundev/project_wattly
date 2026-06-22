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

    @Test func powerDisplaySmoothingTracksRawSeparately() async {
        // The headline reads EMA-smoothed (matches MX Power Gadget), but the raw
        // measurement is untouched: first sample seeds to raw, a jump is damped, and
        // the raw history/state still carry the true spiky values.
        func pw(_ w: Double) -> ProviderReading { .value(.power(PowerSample(totalW: w, cpuW: w, gpuW: 0, npuW: 0))) }
        let power = ScriptedProvider(kind: .power, [pw(10), pw(20)])
        let clock = ManualClock()
        let monitor = SystemMonitor(providers: [power], clock: clock)

        await monitor.pollOnce()                         // seed → smoothed == raw == 10
        #expect(monitor.powerOverlay.sample?.totalW == 10)

        clock.advance(by: .seconds(1))
        await monitor.pollOnce()                          // raw jumps to 20; smoothed damps
        let smoothed = monitor.powerOverlay.sample!.totalW
        #expect(smoothed > 10 && smoothed < 20)           // EMA, not the full jump
        // Raw stays exact in state + history; the smoothed series is its own buffer.
        #expect(monitor.historyValues(for: .power, smoothed: false) == [10, 20])
        #expect(monitor.powerOverlay.history.values.last == smoothed)

        // The toggle picks which the card shows.
        guard case .value(.power(let shown)) = monitor.cardState(.power, smoothed: true) else {
            Issue.record("smoothed power card should be a value"); return
        }
        #expect(shown.totalW == smoothed)
        guard case .value(.power(let rawShown)) = monitor.cardState(.power, smoothed: false) else {
            Issue.record("raw power card should be a value"); return
        }
        #expect(rawShown.totalW == 20)
    }

    @Test func batteryDisplaySmoothingDampsAndResetsOnPlug() async {
        func bat(_ netW: Double, ext: Bool = false) -> ProviderReading {
            .value(.battery(BatterySample(netW: netW, milliamps: Int((abs(netW) * 1000 / 12.0).rounded()),
                                          volts: 12.0, charging: netW < -0.2, externalConnected: ext)))
        }
        // Discharging 16 W then a 24 W spike, then plug in (charging −30 W).
        let battery = ScriptedProvider(kind: .battery, [bat(16), bat(24), bat(-30, ext: true)])
        let clock = ManualClock()
        let monitor = SystemMonitor(providers: [battery], clock: clock)

        await monitor.pollOnce()                          // seed → smoothed netW == 16
        #expect(monitor.batteryOverlay.sample?.netW == 16)

        clock.advance(by: .seconds(1))
        await monitor.pollOnce()                           // raw spikes to 24; smoothed damps between
        let sm = monitor.batteryOverlay.sample!
        #expect(sm.netW > 16 && sm.netW < 24)              // EMA, not the full spike
        #expect(sm.charging == false)                      // direction re-derived from smoothed netW
        #expect(sm.milliamps == Int((abs(sm.netW) * 1000 / 12.0).rounded()))  // mA consistent w/ smoothed netW
        #expect(monitor.historyValues(for: .battery, smoothed: false) == [16, 24])   // raw series untouched

        clock.advance(by: .seconds(1))
        await monitor.pollOnce()                           // plug in (ExternalConnected flip) → smoothing resets
        #expect(monitor.batteryOverlay.sample?.netW == -30)      // seeds to the charging value at once (no blend)
        #expect(monitor.batteryOverlay.sample?.charging == true)
        #expect(monitor.batteryOverlay.history.values == [-30])
        #expect(monitor.cardState(.battery, smoothed: true) == .value(.battery(monitor.batteryOverlay.sample!)))
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
        #expect(monitor.historyValues(for: .battery, smoothed: false) == [9.6, 9.6])

        clock.advance(by: .seconds(2))
        await monitor.pollOnce()                 // plugged in (ExternalConnected flip) → reset → [-13.4]
        #expect(monitor.historyValues(for: .battery, smoothed: false) == [-13.4])
    }

    // MARK: Issue 09 — adaptive polling / low power

    @Test func hiddenTemperatureCardsDoNoCPUGPUSensorIO() async {
        // 수용 #2: both temperature toggles OFF → zero CPU/GPU SMC I/O, but the provider
        // still runs for battery temp (independent source). Driven at the SystemMonitor
        // level via the real provider + a fake transport that counts I/O. `model:"Mac17,2"`
        // is pinned so the SMC path is genuinely live (else it's terminal → vacuous green).
        let tx = FakeTempTransport()
        tx.cpuCelsius = 80; tx.gpuCelsius = 70; tx.battery = .centiCelsius(3000)
        let temp = TemperatureProvider(transport: tx, model: "Mac17,2")
        let monitor = SystemMonitor(providers: [temp], clock: ManualClock())

        // Baseline: temp cards shown → the SMC path actually opens + reads (non-vacuous).
        await monitor.setShownCards(Set(CardKind.allCases))
        await monitor.pollOnce()
        #expect(tx.openCalls >= 1)
        #expect(tx.readCalls >= 1)

        // Hide both CPU/GPU temp cards (batTemp stays) → setEnabled(false) → no new SMC I/O.
        let openBefore = tx.openCalls, readBefore = tx.readCalls, batBefore = tx.batteryCalls
        await monitor.setShownCards(Set(CardKind.allCases).subtracting([.cpuTemp, .gpuTemp]))
        for _ in 0..<3 { await monitor.pollOnce() }

        #expect(tx.openCalls == openBefore)         // zero further SMC opens
        #expect(tx.readCalls == readBefore)         // zero further SMC key reads
        #expect(tx.batteryCalls == batBefore + 3)   // battery temp still read each poll
    }

    @Test func historyIsContinuousAcrossACadenceChange() async {
        // 수용 #3: cadence (open 1 s → closed 5 s) only changes the sleep between polls;
        // history is instant-keyed, so a full 60 s window survives the change with no reset
        // or gap. Simulated by advancing the clock 1 s then 5 s between direct polls.
        let provider = ScriptedProvider(kind: .cpu, [.value(.cpu(CPUSample(overall: 10, perfLevels: [])))])
        let clock = ManualClock()
        let monitor = SystemMonitor(providers: [provider], clock: clock)

        var elapsed = Duration.zero
        while elapsed < .seconds(30) {                       // 30 s at the open (1 s) cadence
            await monitor.pollOnce(); clock.advance(by: .seconds(1)); elapsed += .seconds(1)
        }
        while elapsed < .seconds(60) {                       // then 30 s at the closed (5 s) cadence
            await monitor.pollOnce(); clock.advance(by: .seconds(5)); elapsed += .seconds(5)
        }
        await monitor.pollOnce()                             // a final sample at t = 60 s

        let values = monitor.historyValues(for: .cpu, smoothed: false)
        #expect(values.count >= 2)                           // enough to draw
        #expect(values.count <= HistoryBuffer.cap)           // never over the cap
        #expect(values.allSatisfy { $0 == 10 })              // continuous — no reset/gap injected
    }
}
