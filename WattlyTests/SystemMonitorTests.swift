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

    actor CountingProvider: MetricProvider {
        let kind: ProviderKind
        private(set) var reads = 0

        init(kind: ProviderKind) { self.kind = kind }

        func read(at: ContinuousClock.Instant) async -> ProviderReading {
            reads += 1
            return .pending
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
        #expect(monitor.batteryOneMinuteAverage == 16)

        clock.advance(by: .seconds(1))
        await monitor.pollOnce()                           // raw spikes to 24; smoothed damps between
        let sm = monitor.batteryOverlay.sample!
        #expect(sm.netW > 16 && sm.netW < 24)              // EMA, not the full spike
        #expect(sm.charging == false)                      // direction re-derived from smoothed netW
        #expect(sm.milliamps == Int((abs(sm.netW) * 1000 / 12.0).rounded()))  // mA consistent w/ smoothed netW
        #expect(monitor.historyValues(for: .battery, smoothed: false) == [16, 24])   // raw series untouched
        let expected1m = PowerSmoothing.emaStep(previous: 16, raw: 24, dt: 1, tau: 60)
        #expect(abs((monitor.batteryOneMinuteAverage ?? 0) - expected1m) < 1e-12)
        guard case .value(.battery(let shownWithAverage)) = monitor.cardState(.battery, smoothed: true) else {
            Issue.record("smoothed battery card should carry the one-minute average"); return
        }
        #expect(shownWithAverage.average1mW == monitor.batteryOneMinuteAverage)

        clock.advance(by: .seconds(1))
        await monitor.pollOnce()                           // plug in (ExternalConnected flip) → smoothing resets
        #expect(monitor.batteryOverlay.sample?.netW == -30)      // seeds to the charging value at once (no blend)
        #expect(monitor.batteryOneMinuteAverage == -30)          // 1-minute trend resets across regimes too
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

    @Test func scheduledClosedMenubarPollReadsOnlySelectedProvider() async {
        let cpu = CountingProvider(kind: .cpu)
        let power = CountingProvider(kind: .power)
        let monitor = SystemMonitor(providers: [cpu, power], clock: ManualClock())

        await monitor.pollScheduled(force: false)

        #expect(await cpu.reads == 1)
        #expect(await power.reads == 0)
    }

    @Test func switchingToPerformancePollsClosedActiveProviders() async {
        let cpu = CountingProvider(kind: .cpu)
        let power = CountingProvider(kind: .power)
        let monitor = SystemMonitor(providers: [cpu, power], clock: ManualClock())

        monitor.start()
        monitor.setPowerMode(.performance)
        monitor.stop() // Stop the replacement loop; drive the schedule deterministically below.
        await monitor.pollScheduled(force: false)

        #expect(await cpu.reads > 0)
        #expect(await power.reads > 0)
    }

    @Test func configurationBeforeStartDoesNotPollProviders() async {
        let cpu = CountingProvider(kind: .cpu)
        let monitor = SystemMonitor(providers: [cpu], clock: ManualClock())

        monitor.setPowerMode(.performance)
        await monitor.setShownCards([.cpu])
        await Task.yield()

        #expect(await cpu.reads == 0)
    }

    @Test func manualPollOnceStillReadsEveryActiveProvider() async {
        let cpu = CountingProvider(kind: .cpu)
        let power = CountingProvider(kind: .power)
        let monitor = SystemMonitor(providers: [cpu, power], clock: ManualClock())

        await monitor.pollOnce()

        #expect(await cpu.reads == 1)
        #expect(await power.reads == 1)
    }

    @Test func scheduledPollWaitsForTheProviderInterval() async {
        let cpu = CountingProvider(kind: .cpu)
        let clock = ManualClock()
        let monitor = SystemMonitor(providers: [cpu], clock: clock)

        await monitor.pollScheduled(force: false)
        clock.advance(by: .seconds(1))
        await monitor.pollScheduled(force: false)
        #expect(await cpu.reads == 1)

        clock.advance(by: .seconds(1))
        await monitor.pollScheduled(force: false)
        #expect(await cpu.reads == 2)
    }

    @Test func textOffPerformsNoMetricReads() async {
        let cpu = CountingProvider(kind: .cpu)
        let monitor = SystemMonitor(providers: [cpu], clock: ManualClock())

        await monitor.setMenubarTextEnabled(false)
        monitor.stop()
        await monitor.pollScheduled(force: false)

        #expect(await cpu.reads == 0)
    }

    @Test func forcedProviderRefreshDoesNotReadOtherScheduledProviders() async {
        let cpu = CountingProvider(kind: .cpu)
        let power = CountingProvider(kind: .power)
        let monitor = SystemMonitor(providers: [cpu, power], clock: ManualClock())

        await monitor.pollScheduled(forceProviders: [.power])

        #expect(await cpu.reads == 1)
        #expect(await power.reads == 1)
    }

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

    @Test func menubarMetricKeepsHiddenProviderPolled() async {
        // Issue 14: a metric shown ONLY in the menubar keeps its provider polled — and its
        // CPU/GPU SMC path enabled — even when every card is hidden. The inverse of
        // `hiddenTemperatureCardsDoNoCPUGPUSensorIO`. `model:"Mac17,2"` pins a live SMC path.
        let tx = FakeTempTransport()
        tx.cpuCelsius = 80; tx.gpuCelsius = 70; tx.battery = .centiCelsius(3000)
        let temp = TemperatureProvider(transport: tx, model: "Mac17,2")
        let monitor = SystemMonitor(providers: [temp], clock: ManualClock())

        // Hide every card, but keep GPU temp on the menubar → SMC must stay live.
        await monitor.setShownCards([])
        await monitor.setMenubarMetrics([.gpuTemp])
        await monitor.pollOnce()
        #expect(tx.openCalls >= 1)                  // SMC opened for the menubar's sake

        let readBefore = tx.readCalls
        for _ in 0..<3 { await monitor.pollOnce() }
        #expect(tx.readCalls > readBefore)          // keeps reading CPU/GPU keys despite no visible card
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

    // MARK: Self-power (issue 16) — fake energy source + manual clock, no libproc

    /// A scripted self-energy counter: the test sets `next` before each `sampleSelfPower`.
    final class FakeSelfEnergy: SelfEnergySampling, @unchecked Sendable {
        var next: UInt64?
        private(set) var reads = 0
        init(_ start: UInt64?) { next = start }
        func energyNanojoules() -> UInt64? {
            reads += 1
            return next
        }
    }

    @Test func selfPowerComputesWattsFromEnergyDelta() {
        let energy = FakeSelfEnergy(1_000_000_000)           // 1 J baseline
        let clock = ManualClock()
        let monitor = SystemMonitor(providers: [], clock: clock, selfEnergy: energy)

        monitor.sampleSelfPower(at: clock.now())             // first sample → baseline only
        #expect(monitor.selfPower == nil)

        clock.advance(by: .seconds(2))
        energy.next = 1_000_000_000 + 5_000_000_000          // +5 J over 2 s = 2.5 W
        monitor.sampleSelfPower(at: clock.now())
        // No previous → the first EMA step re-seeds to the raw value exactly.
        #expect(monitor.selfPower != nil)
        #expect(abs((monitor.selfPower ?? -1) - 2.5) < 1e-9)
    }

    @Test func selfPowerRebaselinesAcrossASleepGap() {
        let energy = FakeSelfEnergy(0)
        let clock = ManualClock()
        let monitor = SystemMonitor(providers: [], clock: clock, selfEnergy: energy)
        monitor.sampleSelfPower(at: clock.now())             // baseline
        clock.advance(by: .seconds(120))                     // > 30 s gap (sleep/wake)
        energy.next = 10_000_000_000
        monitor.sampleSelfPower(at: clock.now())
        #expect(monitor.selfPower == nil)                    // anomaly → no value emitted
    }

    @Test func selfPowerKeepsLastValueOnTransientAnomaly() {
        let energy = FakeSelfEnergy(0)
        let clock = ManualClock()
        let monitor = SystemMonitor(providers: [], clock: clock, selfEnergy: energy)
        monitor.sampleSelfPower(at: clock.now())             // baseline
        clock.advance(by: .seconds(1))
        energy.next = 3_000_000_000                          // +3 J / 1 s = 3 W
        monitor.sampleSelfPower(at: clock.now())
        let warm = monitor.selfPower
        #expect(warm != nil)

        clock.advance(by: .seconds(1))
        energy.next = 0                                      // curr < prev → counter reset (anomaly)
        monitor.sampleSelfPower(at: clock.now())
        #expect(monitor.selfPower == warm)                   // a transient must not blank a working value
    }

    @Test func scheduledSelfEnergySamplingIsCappedAtThirtySeconds() {
        let energy = FakeSelfEnergy(0)
        let clock = ManualClock()
        let monitor = SystemMonitor(providers: [], clock: clock, selfEnergy: energy)

        monitor.sampleSelfPowerIfDue(at: clock.now())
        clock.advance(by: .seconds(29))
        monitor.sampleSelfPowerIfDue(at: clock.now())
        #expect(energy.reads == 1)

        clock.advance(by: .seconds(1))
        monitor.sampleSelfPowerIfDue(at: clock.now())
        #expect(energy.reads == 2)
    }

    // MARK: Per-app power gating (issue 16 follow-up) — kind-routed enumerator

    /// A provider that records its enumeration gate, for either kind.
    actor FakeEnumProvider: MetricProvider, ProcessEnumerating {
        let kind: ProviderKind
        private(set) var enumerating = false
        init(kind: ProviderKind) { self.kind = kind }
        func setEnumerating(_ enabled: Bool) { enumerating = enabled }
        func read(at instant: ContinuousClock.Instant) async -> ProviderReading { .pending }
    }

    @Test func processEnumerationRoutesByKind() async {
        // Both memory and power conform to ProcessEnumerating. The power gate must reach the
        // POWER provider — a `.first` extraction would always pick memory (earlier in
        // ProviderKind.allCases), leaving the power gate wired to nil.
        let mem = FakeEnumProvider(kind: .memory)
        let pow = FakeEnumProvider(kind: .power)
        let monitor = SystemMonitor(providers: [mem, pow], clock: ManualClock())

        monitor.setPowerProcessEnumeration(true)            // spawns a MainActor Task internally
        for _ in 0..<50 where !(await pow.enumerating) { await Task.yield() }
        #expect(await pow.enumerating == true)              // power gate enabled…
        #expect(await mem.enumerating == false)             // …and NOT the memory provider

        monitor.setMemoryProcessEnumeration(true)
        for _ in 0..<50 where !(await mem.enumerating) { await Task.yield() }
        #expect(await mem.enumerating == true)              // memory gate routes to memory

        monitor.setPowerProcessEnumeration(false)
        for _ in 0..<50 where (await pow.enumerating) { await Task.yield() }
        #expect(await pow.enumerating == false)             // …and turns back off on collapse
    }
}
