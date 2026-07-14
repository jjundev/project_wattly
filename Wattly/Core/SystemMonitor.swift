import Foundation
import Observation

/// The one model SwiftUI views observe. Polls the injected providers off the
/// MainActor, keeps per-provider `MetricState`, derives the 7 card states (with
/// the temperature fan-out), and maintains per-card history.
@MainActor
@Observable
final class SystemMonitor {
    /// Per-provider state (5 keys). The 7 cards derive from these.
    private(set) var states: [ProviderKind: MetricState]
    /// Per-card sparkline history (7 keys). Private — callers read a series only via
    /// `historyValues(for:smoothed:)`, never the dict directly.
    private var history: [CardKind: HistoryBuffer]

    /// Display-smoothing overlays for the two smoothable cards. Each holds the
    /// EMA-smoothed sample + its sparkline series, kept parallel to the raw
    /// `states`/`history` so the headline reads as steady as MX Power Gadget's moving
    /// average without touching the (exact) measurement. Value types, so each
    /// `ingest`/`reset` is a tracked `@Observable` write (see `SmoothingOverlay`).
    private(set) var powerOverlay = SmoothingOverlay<PowerSample>()
    private(set) var batteryOverlay = SmoothingOverlay<BatterySample>()
    /// Longer battery trend for comparison with slowly changing charge percentage.
    /// Kept separate from the 4 s headline EMA; reset on adapter regime changes.
    private(set) var batteryOneMinuteAverage: Double?
    private var batteryOneMinuteInstant: ContinuousClock.Instant?

    /// Wattly's own EMA-smoothed power draw in watts (issue 16), or nil until the first
    /// valid interval (the settings footer shows "—"). Doubles as the EMA's previous
    /// value, so it is never blanked by a transient anomaly — only the cold start is nil.
    private(set) var selfPower: Double?

    private let providers: [any MetricProvider]
    /// The providers (if any) that support on-demand process enumeration — the memory
    /// provider's Top-3 (issue 05 §M18) and the power provider's per-app Top-3 (issue 16
    /// follow-up). Extracted once at init BY KIND: both conform to `ProcessEnumerating`, so
    /// a `.first` extraction would always pick memory (it precedes power in `allCases`) and
    /// the power gate would be wired to nil — each must be looked up by its own kind.
    private let memEnumerator: (any ProcessEnumerating)?
    private let powerEnumerator: (any ProcessEnumerating)?
    /// The provider (if any) whose sensor I/O can be gated when its cards are hidden — the
    /// temperature provider (issue 08 supplies the `setEnabled` hook; issue 09 decides when
    /// to call it). Extracted once at init, mirroring `memEnumerator`.
    private let tempGater: (any TemperatureGating)?
    private let clock: MonotonicClock
    private var pollTask: Task<Void, Never>?
    private static let selfPowerInterval: Duration = .seconds(30)
    private var lastProviderRead: [ProviderKind: ContinuousClock.Instant] = [:]
    private var lastSelfPowerSample: ContinuousClock.Instant?

    /// Self-power measurement state (issue 16). The injected energy source plus the prior
    /// nanojoule counter + its instant; `sampleSelfPower` diffs them into `selfPower`.
    private let selfEnergy: any SelfEnergySampling
    private var prevSelfNJ: UInt64?
    private var prevSelfInstant: ContinuousClock.Instant?

    // MARK: Adaptive-poll policy (issue 09) — pushed in from the views, never read from
    // `UserDefaults` here, so the cadence and gating stay deterministically testable.

    /// The user's cadence choice; only `.auto` adapts to panel/menubar state.
    private var pollSetting: PollInterval = Defaults.pollInterval
    /// Whether the popover is on-screen (pushed by `PopoverContentView`'s lifecycle).
    private var panelVisible = false
    /// Whether the menubar shows a metric number (keeps a closed panel at 2 s, not 5 s).
    private var menubarTextEnabled = Defaults.menubarTextEnabled
    /// The cards whose metric is shown in the menubar text (issue 14). When the text is
    /// enabled, their providers stay polled even if the matching card is hidden — that is
    /// what makes a menubar-only metric (e.g. GPU temp with its card off) keep updating.
    /// Seeded to the default-selected set (= `[.cpu]`) so `menubarNeeds` matches the prior
    /// hardcode until `PollPolicyBridge` pushes the user's chips.
    private var menubarMetrics = Set(Defaults.menuMetrics.filter(\.value).map(\.key))
    /// The cards currently shown. Providers feeding no shown (or menubar-needed) card drop
    /// out of the poll. Seeded to every card so the filter is a no-op until a card is hidden
    /// (issue 13's toggles) — never empty, which would skip every provider at launch.
    private var shownCards = Set(CardKind.allCases)
    /// Derived from `shownCards` (via the pure `activeProviders(shown:menubarNeeds:)`) — the
    /// providers `pollOnce` actually reads.
    private var activeProviderKinds = Set(ProviderKind.allCases)
    /// Last value pushed to `tempGater.setEnabled`, to detect an off→on transition.
    private var tempEnabled = true

    init(providers: [any MetricProvider],
         clock: MonotonicClock = LiveClock(),
         selfEnergy: any SelfEnergySampling = LiveSelfEnergy()) {
        self.providers = providers
        self.memEnumerator = providers.first { $0.kind == .memory } as? ProcessEnumerating
        self.powerEnumerator = providers.first { $0.kind == .power } as? ProcessEnumerating
        self.tempGater = providers.compactMap { $0 as? TemperatureGating }.first
        self.clock = clock
        self.selfEnergy = selfEnergy
        self.states = Dictionary(uniqueKeysWithValues: ProviderKind.allCases.map { ($0, .loading) })
        self.history = Dictionary(uniqueKeysWithValues: CardKind.allCases.map { ($0, HistoryBuffer()) })
    }

    // MARK: Lifecycle

    func start() {
        start(forceProviders: nil)
    }

    private func start(forceProviders: Set<ProviderKind>?) {
        guard pollTask == nil else { return }
        let initial = forceProviders ?? Set(currentProviderIntervals.keys)
        pollTask = Task(priority: .utility) { [weak self] in
            var forced = initial
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollScheduled(forceProviders: forced)
                self.sampleSelfPowerIfDue(at: self.clock.now())
                forced = []
                let delay = self.nextScheduledDelay(at: self.clock.now())
                try? await Task.sleep(for: delay, tolerance: delay / 5)
            }
        }
    }

    private var currentProviderIntervals: [ProviderKind: Duration] {
        let needs: Set<CardKind> = menubarTextEnabled ? menubarMetrics : []
        return providerIntervals(mode: .eco, setting: pollSetting, panelVisible: panelVisible,
                                 menubarTextEnabled: menubarTextEnabled,
                                 active: activeProviderKinds, menubarNeeds: needs)
    }

    private func nextScheduledDelay(at instant: ContinuousClock.Instant) -> Duration {
        nextPollDelay(intervals: currentProviderIntervals, lastRead: lastProviderRead,
                      now: instant, housekeeping: Self.selfPowerInterval)
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Enable/disable top-process enumeration on the memory provider (issue 05
    /// §M11). The popover calls this when the memory expand appears/disappears.
    /// Enabling fires an immediate poll so the list shows without waiting for the
    /// next interval (§M15). No-op when no provider supports enumeration (tests).
    func setMemoryProcessEnumeration(_ on: Bool) {
        guard let memEnumerator else { return }
        Task { [weak self] in
            await memEnumerator.setEnumerating(on)
            if on, let self { await self.poll(kinds: [.memory], at: self.clock.now()) }
        }
    }

    /// Enable/disable per-app power enumeration on the power provider (issue 16 follow-up).
    /// The popover calls this when the power card's expand appears/disappears. Mirrors
    /// `setMemoryProcessEnumeration`: enabling fires an immediate poll to baseline at once
    /// (per-app watts then appear on the next interval, the energy counter being cumulative).
    func setPowerProcessEnumeration(_ on: Bool) {
        guard let powerEnumerator else { return }
        Task { [weak self] in
            await powerEnumerator.setEnumerating(on)
            if on, let self { await self.poll(kinds: [.power], at: self.clock.now()) }
        }
    }

    // MARK: Adaptive-poll control (issue 09)

    func setPanelVisible(_ visible: Bool) {
        guard visible != panelVisible else { return }
        let before = currentProviderIntervals
        panelVisible = visible
        let after = currentProviderIntervals
        guard after != before else { return }
        let forced = visible ? Set(after.keys) : Set(after.keys).subtracting(before.keys)
        reschedule(forceProviders: forced)
    }

    /// The user picked a cadence in settings.
    func setPollInterval(_ setting: PollInterval) {
        guard setting != pollSetting else { return }
        let before = currentProviderIntervals
        pollSetting = setting
        let after = currentProviderIntervals
        if after != before { reschedule(forceProviders: Set(after.keys).subtracting(before.keys)) }
    }

    /// The menubar metric text was turned on/off — affects both the closed-panel cadence
    /// and which providers the menubar needs (so it is a gating input too).
    func setMenubarTextEnabled(_ enabled: Bool) async {
        guard enabled != menubarTextEnabled else { return }
        let before = currentProviderIntervals
        menubarTextEnabled = enabled
        let newlyActivated = await recomputeGating()
        let after = currentProviderIntervals
        let forced = Set(after.keys).subtracting(before.keys)
            .union(newlyActivated.intersection(Set(after.keys)))
        if after != before || !forced.isEmpty { reschedule(forceProviders: forced) }
    }

    func setShownCards(_ cards: Set<CardKind>) async {
        guard cards != shownCards else { return }
        let before = currentProviderIntervals
        shownCards = cards
        let newlyActivated = await recomputeGating()
        let after = currentProviderIntervals
        let forced = Set(after.keys).subtracting(before.keys)
            .union(newlyActivated.intersection(Set(after.keys)))
        if after != before || !forced.isEmpty { reschedule(forceProviders: forced) }
    }

    func setMenubarMetrics(_ cards: Set<CardKind>) async {
        guard cards != menubarMetrics else { return }
        let before = currentProviderIntervals
        menubarMetrics = cards
        let newlyActivated = await recomputeGating()
        let after = currentProviderIntervals
        let forced = Set(after.keys).subtracting(before.keys)
            .union(newlyActivated.intersection(Set(after.keys)))
        if after != before || !forced.isEmpty { reschedule(forceProviders: forced) }
    }

    private func recomputeGating() async -> Set<ProviderKind> {
        let menubarNeeds: Set<CardKind> = menubarTextEnabled ? menubarMetrics : []
        let needed = activeProviders(shown: shownCards, menubarNeeds: menubarNeeds)
        var newlyActivated = needed.subtracting(activeProviderKinds)
        activeProviderKinds = needed

        let neededCards = shownCards.union(menubarNeeds)
        let want = neededCards.contains(.cpuTemp) || neededCards.contains(.gpuTemp)
        let tempTurnedOn = want && !tempEnabled
        tempEnabled = want
        await tempGater?.setEnabled(want)
        if tempTurnedOn { newlyActivated.insert(.temperature) }
        return newlyActivated
    }

    private func reschedule(forceProviders: Set<ProviderKind> = []) {
        stop()
        start(forceProviders: forceProviders)
    }

    // MARK: Self-power (issue 16) — called by the timer loop, and directly by tests

    /// Diff the per-process energy counter into `selfPower` (EMA-smoothed watts). Driven by
    /// the timer loop on its cadence; tests call it directly with a `ManualClock` + a fake
    /// `SelfEnergySampling`, exactly as they drive `pollOnce`. On the first sample (or an
    /// anomaly — gap / counter reset) it only re-baselines and leaves the displayed value
    /// untouched, so a transient never blanks a working footer.
    func sampleSelfPower(at instant: ContinuousClock.Instant) {
        guard let curr = selfEnergy.energyNanojoules() else { return }   // unreadable → keep last
        defer { prevSelfNJ = curr; prevSelfInstant = instant }          // re-baseline on every kept path
        guard let prevNJ = prevSelfNJ, let prevInstant = prevSelfInstant else { return }  // first sample
        let dt = seconds(from: prevInstant, to: instant)
        guard let raw = SelfPower.watts(prevNanojoules: prevNJ, currNanojoules: curr, dt: dt) else { return }
        // selfPower is its own EMA previous → cold start (nil) re-seeds to raw, then blends.
        selfPower = PowerSmoothing.emaStep(previous: selfPower, raw: raw, dt: dt)
    }

    func sampleSelfPowerIfDue(at instant: ContinuousClock.Instant) {
        guard lastSelfPowerSample.map({ seconds(from: $0, to: instant) >= 30 }) != false else { return }
        sampleSelfPower(at: instant)
        lastSelfPowerSample = instant
    }

    // MARK: One poll cycle (called directly by tests — the seam)

    func pollOnce() async {
        await poll(kinds: activeProviderKinds, at: clock.now())
    }

    func pollScheduled(force: Bool) async {
        await pollScheduled(forceProviders: force ? Set(currentProviderIntervals.keys) : [])
    }

    func pollScheduled(forceProviders: Set<ProviderKind>) async {
        let instant = clock.now()
        let due = dueProviders(intervals: currentProviderIntervals, lastRead: lastProviderRead,
                               now: instant, force: false)
        await poll(kinds: due.union(forceProviders), at: instant)
    }

    private func poll(kinds: Set<ProviderKind>, at instant: ContinuousClock.Instant) async {
        for provider in providers where kinds.contains(provider.kind) {
            let reading = await provider.read(at: instant)   // off-main hop
            lastProviderRead[provider.kind] = instant
            apply(reading, from: provider.kind, at: instant) // back on MainActor
        }
    }

    private func apply(_ reading: ProviderReading, from kind: ProviderKind, at instant: ContinuousClock.Instant) {
        switch reading {
        case .pending:
            states[kind] = .loading
        case .unavailable(let reason):
            states[kind] = .unavailable(reason)
        case .value(let sample):
            states[kind] = .value(sample)
            recordHistory(for: kind, sample: sample, at: instant)
        }
    }

    /// Previous AC-adapter connection state. A plug/unplug (`ExternalConnected` change)
    /// clears the battery sparkline at once, so the prior regime doesn't linger on the
    /// graph: the current register lags a plug-in by 30–60 s, so we key the reset off the
    /// connection flag (which flips instantly) rather than the current-derived direction
    /// (issue 07 §2). Held here, not in the provider, so `BatteryProvider` stays stateless.
    private var lastExternalConnected: Bool?

    private func recordHistory(for kind: ProviderKind, sample: MetricSample, at instant: ContinuousClock.Instant) {
        if case .battery(let s) = sample {
            if let last = lastExternalConnected, last != s.externalConnected {
                history[.battery] = HistoryBuffer()      // adapter plugged/unplugged → fresh raw graph
                batteryOverlay.reset()                   // …and restart smoothing: don't blend regimes
                batteryOneMinuteAverage = nil
                batteryOneMinuteInstant = nil
            }
            lastExternalConnected = s.externalConnected
            let averageDt = batteryOneMinuteInstant.map { seconds(from: $0, to: instant) } ?? 0
            batteryOneMinuteAverage = PowerSmoothing.emaStep(
                previous: batteryOneMinuteAverage, raw: s.netW, dt: averageDt, tau: 60)
            batteryOneMinuteInstant = instant
            var presented = s
            presented.average1mW = batteryOneMinuteAverage
            // Smooth only netW, then re-derive mA + charge direction from it (so the value,
            // the mA, and the 충전/방전 label never disagree). Policy stays here, by the card.
            batteryOverlay.ingest(at: instant,
                smooth: { previous, dt in
                    let netW = PowerSmoothing.emaStep(previous: previous?.netW, raw: presented.netW, dt: dt)
                    return Self.batterySmoothed(from: presented, netW: netW)
                },
                series: \.netW)
        }
        if case .power(let s) = sample {
            powerOverlay.ingest(at: instant,
                smooth: { previous, dt in PowerSmoothing.step(previous: previous, raw: s, dt: dt) },
                series: \.totalW)
        }
        for card in CardKind.allCases where card.provider == kind {
            if let scalar = Self.scalar(of: card, from: sample) {
                history[card, default: HistoryBuffer()].append(scalar, at: instant)
            }
        }
    }

    /// A battery sample whose displayed fields are all consistent with the smoothed
    /// `netW`: mA and the charge/discharge direction are re-derived from it (so the
    /// value, the mA, and the 충전/방전 label never disagree); `volts`/`externalConnected`
    /// pass through from the raw sample (volts is stable; connection is a discrete state).
    private static func batterySmoothed(from raw: BatterySample, netW: Double) -> BatterySample {
        let mA = raw.volts > 0 ? Int((abs(netW) * 1000 / raw.volts).rounded()) : raw.milliamps
        return BatterySample(netW: netW, milliamps: mA, volts: raw.volts,
                             charging: isCharging(netW: netW), externalConnected: raw.externalConnected,
                             average1mW: raw.average1mW)
    }

    // MARK: Derivation — the 7-card fan-out

    /// State for a single card, derived from its provider's state. Temperature
    /// cards split the snapshot per category, so one failing sensor only darkens
    /// its own card (partial-failure isolation).
    func cardState(_ card: CardKind) -> MetricState {
        guard let providerState = states[card.provider] else { return .loading }
        switch card {
        case .cpuTemp, .gpuTemp, .batTemp:
            return temperatureCardState(card, from: providerState)
        case .battery:
            guard case .value(.battery(var sample)) = providerState else { return providerState }
            sample.average1mW = batteryOneMinuteAverage
            return .value(.battery(sample))
        default:
            return providerState
        }
    }

    /// Card state with optional display smoothing — the uniform surface for the view
    /// (issue: match MX Power Gadget's damped readout). Smoothing applies only to the
    /// smoothable cards (processor power + battery); every other card returns its raw
    /// state. The swap is guarded on the raw state already being *that card's* value,
    /// so a loading/unavailable card is never masked by a stale smoothed sample.
    func cardState(_ card: CardKind, smoothed: Bool) -> MetricState {
        let raw = cardState(card)
        guard smoothed, card.isSmoothable else { return raw }
        switch card {
        case .power:
            guard case .value(.power) = raw, let s = powerOverlay.sample else { return raw }
            return .value(.power(s))
        case .battery:
            guard case .value(.battery) = raw, var s = batteryOverlay.sample else { return raw }
            s.average1mW = batteryOneMinuteAverage
            return .value(.battery(s))
        default:
            return raw
        }
    }

    /// Sparkline values for a card — the smoothed series for the smoothable cards when
    /// `smoothed`, otherwise the raw history. The only way callers read a series, so
    /// the `history` dict stays private (closes the prior `monitor.history[card]` leak).
    func historyValues(for card: CardKind, smoothed: Bool) -> [Double] {
        if smoothed, card.isSmoothable {
            switch card {
            case .power: return powerOverlay.history.values
            case .battery: return batteryOverlay.history.values
            default: break
            }
        }
        return history[card]?.values ?? []
    }

    private func temperatureCardState(_ card: CardKind, from providerState: MetricState) -> MetricState {
        switch providerState {
        case .loading: return .loading
        case .unavailable(let r): return .unavailable(r)
        case .value(let sample):
            guard case .temperature(let snap) = sample else { return .loading }
            let category: CategoryReading = switch card {
                case .cpuTemp: snap.cpu
                case .gpuTemp: snap.gpu
                default: snap.battery
            }
            switch category {
            case .reading: return .value(sample)
            case .unavailable(let e): return .unavailable(.temperature(e))
            case .notPresent(let s): return .unavailable(.notPresent(s))
            }
        }
    }

    /// Whether the card should appear at all. Battery and battery-temperature
    /// vanish on a desktop Mac — modelled uniformly as their provider/category
    /// being `.notPresent`, which also covers a real laptop with no battery.
    func isPresent(_ card: CardKind) -> Bool {
        if case .unavailable(let r) = cardState(card), case .notPresent = r { return false }
        return true
    }

    /// Header status dot: green only when every shown card has a value; orange
    /// while anything is still loading or unavailable (prototype line 739).
    var aggregateHealthy: Bool {
        CardKind.allCases.allSatisfy { card in
            guard isPresent(card) else { return true } // hidden cards don't count
            if case .value = cardState(card) { return true }
            return false
        }
    }

    // MARK: Scalars for sparklines

    /// The single number a card plots. The temperature cards pull their category's
    /// celsius out of the shared snapshot.
    static func scalar(of card: CardKind, from sample: MetricSample) -> Double? {
        switch (card, sample) {
        case (.power, .power(let s)): return s.totalW
        case (.battery, .battery(let s)): return s.netW
        case (.cpu, .cpu(let s)): return s.overall
        case (.mem, .memory(let s)): return s.usedGB
        case (.cpuTemp, .temperature(let s)): return s.cpu.celsius
        case (.gpuTemp, .temperature(let s)): return s.gpu.celsius
        case (.batTemp, .temperature(let s)): return s.battery.celsius
        default: return nil
        }
    }
}

extension CategoryReading {
    /// Celsius if this category produced a reading, else nil.
    var celsius: Double? {
        if case .reading(let r) = self { return r.celsius }
        return nil
    }
}
