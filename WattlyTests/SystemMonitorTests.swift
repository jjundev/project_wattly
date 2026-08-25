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
            gpu: .unavailable(.noVerifiedProfile))
        let temp = ScriptedProvider(kind: .temperature, [.value(.temperature(snap))])
        let monitor = SystemMonitor(providers: [temp], clock: ManualClock())

        await monitor.pollOnce()

        guard case .value = monitor.cardState(.cpuTemp) else {
            Issue.record("cpuTemp should have a value"); return
        }
        guard case .unavailable(.temperature(.noVerifiedProfile)) = monitor.cardState(.gpuTemp) else {
            Issue.record("gpuTemp should be unavailable without affecting cpuTemp"); return
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
            .value(.battery(BatterySample(
                netW: netW,
                milliamps: Int((abs(netW) * 1000 / 12.0).rounded()),
                volts: 12.0,
                charging: netW < -0.2,
                externalConnected: ext,
                remainingWh: 48.0,
                timeRemainingMinutes: netW > 0.05 ? 180 : nil,
                efficiencyPercent: 99.6,
                cycleCount: 77)))
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
        #expect(sm.remainingWh == 48.0)
        #expect(sm.timeRemainingMinutes == 180)
        #expect(sm.efficiencyPercent == 99.6)
        #expect(sm.cycleCount == 77)
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
        #expect(monitor.batteryOverlay.sample?.remainingWh == 48.0)
        #expect(monitor.batteryOverlay.sample?.timeRemainingMinutes == nil)
        #expect(monitor.batteryOverlay.sample?.efficiencyPercent == 99.6)
        #expect(monitor.batteryOverlay.sample?.cycleCount == 77)
        #expect(monitor.batteryOverlay.history.values == [-30])
        #expect(monitor.cardState(.battery, smoothed: true) == .value(.battery(monitor.batteryOverlay.sample!)))
    }

    @Test func batteryDisconnectSuppressesUnchangedChargingTimeUntilRegistryChanges() async {
        func battery(netW: Double, connected: Bool, time: Int?) -> ProviderReading {
            .value(.battery(BatterySample(
                netW: netW,
                milliamps: Int((abs(netW) * 1_000 / 12.5).rounded()),
                volts: 12.5,
                charging: netW < -0.2,
                externalConnected: connected,
                remainingWh: 63.8,
                timeRemainingMinutes: time)))
        }

        let provider = ScriptedProvider(kind: .battery, [
            battery(netW: -16.9, connected: true, time: 58),
            battery(netW: 16.9, connected: false, time: 58),
            battery(netW: 16.9, connected: false, time: 58),
            battery(netW: 16.9, connected: false, time: 230),
        ])
        let clock = ManualClock()
        let monitor = SystemMonitor(providers: [provider], clock: clock)

        await monitor.pollOnce()
        clock.advance(by: .seconds(1))
        await monitor.pollOnce()
        guard case .value(.battery(let afterUnplug)) = monitor.cardState(.battery, smoothed: true) else {
            Issue.record("battery card should have a value after unplug"); return
        }
        #expect(afterUnplug.timeRemainingMinutes == nil)
        #expect(CardPresentation.batteryRemainingTimeSummary(afterUnplug) == "약 3시간 47분 남음")

        clock.advance(by: .seconds(1))
        await monitor.pollOnce()
        guard case .value(.battery(let repeatedStaleTime)) = monitor.cardState(.battery, smoothed: true) else {
            Issue.record("battery card should retain a value while stale time repeats"); return
        }
        #expect(repeatedStaleTime.timeRemainingMinutes == nil)
        #expect(CardPresentation.batteryRemainingTimeSummary(repeatedStaleTime) == "약 3시간 47분 남음")

        clock.advance(by: .seconds(1))
        await monitor.pollOnce()
        guard case .value(.battery(let updatedRegistryTime)) = monitor.cardState(.battery, smoothed: true) else {
            Issue.record("battery card should have a value after registry time changes"); return
        }
        #expect(updatedRegistryTime.timeRemainingMinutes == 230)
        #expect(CardPresentation.batteryRemainingTimeSummary(updatedRegistryTime) == "약 3시간 50분 남음")
    }

    @Test func batteryProjectedMinutesSurviveTheSmoothedCardState() async {
        func battery() -> ProviderReading {
            .value(.battery(BatterySample(
                netW: 30,
                milliamps: 2_400,
                volts: 12.5,
                charging: false,
                externalConnected: false,
                remainingWh: 60,
                timeRemainingMinutes: nil)))
        }

        let provider = ScriptedProvider(kind: .battery, [battery(), battery()])
        let clock = ManualClock()
        let monitor = SystemMonitor(providers: [provider], clock: clock)

        await monitor.pollOnce()
        // Mirror the open panel's normal five-second battery reads. This keeps every
        // observation below the projection module's 30-second sleep/wake gap limit.
        for _ in 1...12 {
            clock.advance(by: .seconds(5))
            await monitor.pollOnce()
        }

        guard case .value(.battery(let sample)) = monitor.cardState(.battery, smoothed: true) else {
            Issue.record("smoothed battery card should have a value"); return
        }
        #expect(sample.projectedTimeRemainingMinutes == 119)
        #expect(CardPresentation.batteryRemainingTimeSummary(sample) == "약 1시간 59분 남음")
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
        await monitor.setMenubarMotionMetrics([])

        await monitor.pollScheduled(force: false)

        #expect(await cpu.reads == 0)
        #expect(await power.reads == 1)
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
        let power = CountingProvider(kind: .power)
        let clock = ManualClock()
        let monitor = SystemMonitor(providers: [power], clock: clock)

        await monitor.pollScheduled(force: false)
        clock.advance(by: .seconds(1))
        await monitor.pollScheduled(force: false)
        #expect(await power.reads == 1)

        clock.advance(by: .seconds(1))
        await monitor.pollScheduled(force: false)
        #expect(await power.reads == 2)
    }

    @Test func textAndMotionOffPerformNoMetricReads() async {
        let cpu = CountingProvider(kind: .cpu)
        let monitor = SystemMonitor(providers: [cpu], clock: ManualClock())

        await monitor.setMenubarTextEnabled(false)
        await monitor.setMenubarMotionMetrics([])
        monitor.stop()
        await monitor.pollScheduled(force: false)

        #expect(await cpu.reads == 0)
    }

    @Test func forcedProviderRefreshDoesNotReadOtherScheduledProviders() async {
        let cpu = CountingProvider(kind: .cpu)
        let power = CountingProvider(kind: .power)
        let monitor = SystemMonitor(providers: [cpu, power], clock: ManualClock())

        await monitor.pollScheduled(forceProviders: [.power])

        #expect(await cpu.reads == 0)
        #expect(await power.reads == 1)
    }

    @Test func hiddenTemperatureCardsDoNoCPUGPUSensorIO() async {
        // Both temperature toggles OFF → zero CPU/GPU SMC I/O.
        // Driven at the SystemMonitor level via the real provider + a fake transport that counts I/O.
        // `model:"Mac17,2"` is pinned so the SMC path is genuinely live (else it's terminal → vacuous green).
        let tx = FakeTempTransport()
        tx.cpuCelsius = 80; tx.gpuCelsius = 70
        let temp = TemperatureProvider(transport: tx, model: "Mac17,2")
        let monitor = SystemMonitor(providers: [temp], clock: ManualClock())

        // Baseline: temp cards shown → the SMC path actually opens + reads (non-vacuous).
        await monitor.setShownCards(Set(CardKind.allCases))
        await monitor.pollOnce()
        #expect(tx.openCalls >= 1)
        #expect(tx.readCalls >= 1)

        // Hide both CPU/GPU temp cards → setEnabled(false) → no new SMC I/O.
        let openBefore = tx.openCalls, readBefore = tx.readCalls
        await monitor.setShownCards(Set(CardKind.allCases).subtracting([.cpuTemp, .gpuTemp]))
        for _ in 0..<3 { await monitor.pollOnce() }

        #expect(tx.openCalls == openBefore)         // zero further SMC opens
        #expect(tx.readCalls == readBefore)         // zero further SMC key reads
    }

    @Test func menubarMetricKeepsHiddenProviderPolled() async {
        // Issue 14: a metric shown ONLY in the menubar keeps its provider polled — and its
        // CPU/GPU SMC path enabled — even when every card is hidden. The inverse of
        // `hiddenTemperatureCardsDoNoCPUGPUSensorIO`. `model:"Mac17,2"` pins a live SMC path.
        let tx = FakeTempTransport()
        tx.cpuCelsius = 80; tx.gpuCelsius = 70
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

    @Test func panelOpenTriggersRapidPowerDoubleSample() async {
        let power = CountingProvider(kind: .power)
        let clock = ManualClock()
        let monitor = SystemMonitor(providers: [power], clock: clock)
        monitor.setPollInterval(.auto)
        monitor.start()

        #expect(await power.reads == 0) // Closed eco mode: power is absent from current closed-menu demands.
        monitor.setPanelVisible(true)
        // t = 0 immediate poll triggered by reschedule
        for _ in 0..<50 where (await power.reads < 1) { await Task.yield() }
        #expect(await power.reads >= 1)
        // Let async 250ms double-sample execute
        try? await Task.sleep(for: .milliseconds(350))
        #expect(await power.reads >= 2)
        monitor.stop()
    }

    @Test func batteryStateChangeReschedulesOnACConnection() async {
        let batterySample = BatterySample(netW: -10, milliamps: 1000, volts: 12, charging: true, externalConnected: true)
        let batteryProvider = ScriptedProvider(kind: .battery, [.value(.battery(batterySample))])
        let mem = CountingProvider(kind: .memory)
        let clock = ManualClock()
        let monitor = SystemMonitor(providers: [batteryProvider, mem], clock: clock)
        monitor.setPowerMode(.performance)
        monitor.start()

        // Ingest battery sample with AC connected
        await monitor.pollOnce()
        #expect(await mem.reads >= 1)
        monitor.stop()
    }

    // MARK: Battery target synchronization

    @Test func batteryTargetPercentageDefaultAndSetter() {
        let monitor = SystemMonitor(providers: [], clock: ManualClock())
        #expect(monitor.batteryTargetPercentage == 100)

        monitor.setBatteryChargeTarget(enabled: true, limitPercentage: 80, topUpActive: false)
        #expect(monitor.batteryTargetPercentage == 80)

        // Clamping to 50...100
        monitor.setBatteryChargeTarget(enabled: true, limitPercentage: 40, topUpActive: false)
        #expect(monitor.batteryTargetPercentage == 50)

        monitor.setBatteryChargeTarget(enabled: true, limitPercentage: 110, topUpActive: false)
        #expect(monitor.batteryTargetPercentage == 100)

        // Disabled returns 100
        monitor.setBatteryChargeTarget(enabled: false, limitPercentage: 80, topUpActive: false)
        #expect(monitor.batteryTargetPercentage == 100)

        // topUpActive overrides to 100
        monitor.setBatteryChargeTarget(enabled: true, limitPercentage: 80, topUpActive: true)
        #expect(monitor.batteryTargetPercentage == 100)
    }

    @Test func setBatteryChargeTargetUpdatesExistingBatterySampleState() async {
        let batterySample = BatterySample(
            netW: -20, milliamps: 1500, volts: 12.5, charging: true,
            externalConnected: true, remainingWh: 30, maxWh: 60)
        let batteryProvider = ScriptedProvider(kind: .battery, [.value(.battery(batterySample))])
        let monitor = SystemMonitor(providers: [batteryProvider], clock: ManualClock())

        await monitor.pollOnce()
        guard case .value(.battery(let sampleBefore)) = monitor.cardState(.battery) else {
            Issue.record("Expected battery sample"); return
        }
        #expect(sampleBefore.targetPercentage == 100)

        monitor.setBatteryChargeTarget(enabled: true, limitPercentage: 85, topUpActive: false)
        #expect(monitor.batteryTargetPercentage == 85)

        guard case .value(.battery(let sampleAfter)) = monitor.cardState(.battery) else {
            Issue.record("Expected battery sample"); return
        }
        #expect(sampleAfter.targetPercentage == 85)
    }

    @Test func pollIngestsBatterySampleWithTargetPercentageAndSmoothedOverlayCarriesIt() async {
        let batterySample = BatterySample(
            netW: -20, milliamps: 1500, volts: 12.5, charging: true,
            externalConnected: true, remainingWh: 30, maxWh: 60)
        let batteryProvider = ScriptedProvider(kind: .battery, [.value(.battery(batterySample))])
        let monitor = SystemMonitor(providers: [batteryProvider], clock: ManualClock())

        monitor.setBatteryChargeTarget(enabled: true, limitPercentage: 85, topUpActive: false)
        await monitor.pollOnce()

        guard case .value(.battery(let rawSample)) = monitor.cardState(.battery, smoothed: false) else {
            Issue.record("Expected raw battery sample"); return
        }
        #expect(rawSample.targetPercentage == 85)

        guard case .value(.battery(let smoothedSample)) = monitor.cardState(.battery, smoothed: true) else {
            Issue.record("Expected smoothed battery sample"); return
        }
        #expect(smoothedSample.targetPercentage == 85)
        // 60 Wh * 0.85 = 51 Wh target. Needed = 21 Wh. 21 / 20 * 60 = 63 min.
        #expect(smoothedSample.projectedTimeRemainingMinutes == 63)
    }

    @Test func smoothedBatteryCardStateCarriesPowerFlowSnapshot() async {
        let flow = PowerFlowSnapshot(
            scenario: .charging,
            adapterWatts: 48.5,
            systemWatts: 16.1,
            batteryNetWatts: -32.4
        )
        let batterySample = BatterySample(
            netW: -32.4, milliamps: 2612, volts: 12.4, charging: true,
            externalConnected: true, remainingWh: 40, maxWh: 60,
            powerFlow: flow
        )
        let batteryProvider = ScriptedProvider(kind: .battery, [.value(.battery(batterySample))])
        let monitor = SystemMonitor(providers: [batteryProvider], clock: ManualClock())

        await monitor.pollOnce()

        guard case .value(.battery(let smoothedSample)) = monitor.cardState(.battery, smoothed: true) else {
            Issue.record("Expected smoothed battery sample"); return
        }
        #expect(smoothedSample.powerFlow != nil)
        #expect(smoothedSample.powerFlow?.scenario == .charging)
        #expect(smoothedSample.powerFlow?.adapterWatts == 48.5)
        #expect(smoothedSample.powerFlow?.systemWatts == 16.1)
    }
}


