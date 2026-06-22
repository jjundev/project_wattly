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

    private let providers: [any MetricProvider]
    /// The provider (if any) that supports on-demand process enumeration — the
    /// memory provider (issue 05 §M18). Extracted once at init.
    private let memEnumerator: (any ProcessEnumerating)?
    private let clock: MonotonicClock
    private let interval: Duration
    private var pollTask: Task<Void, Never>?

    init(providers: [any MetricProvider],
         clock: MonotonicClock = LiveClock(),
         interval: Duration = .seconds(2)) {
        self.providers = providers
        self.memEnumerator = providers.compactMap { $0 as? ProcessEnumerating }.first
        self.clock = clock
        self.interval = interval
        self.states = Dictionary(uniqueKeysWithValues: ProviderKind.allCases.map { ($0, .loading) })
        self.history = Dictionary(uniqueKeysWithValues: CardKind.allCases.map { ($0, HistoryBuffer()) })
    }

    // MARK: Lifecycle

    /// Fixed-interval polling (L8). Adaptive intervals, timer tolerance, QoS and
    /// stop-on-close are issue 09 — this is the working baseline.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                try? await Task.sleep(for: self.interval)
            }
        }
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
            if on { await self?.pollOnce() }
        }
    }

    // MARK: One poll cycle (called directly by tests — the seam)

    func pollOnce() async {
        let instant = clock.now()
        for provider in providers {
            let reading = await provider.read(at: instant)   // off-main hop
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
            }
            lastExternalConnected = s.externalConnected
            // Smooth only netW, then re-derive mA + charge direction from it (so the value,
            // the mA, and the 충전/방전 label never disagree). Policy stays here, by the card.
            batteryOverlay.ingest(at: instant,
                smooth: { previous, dt in
                    let netW = PowerSmoothing.emaStep(previous: previous?.netW, raw: s.netW, dt: dt)
                    return Self.batterySmoothed(from: s, netW: netW)
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
                             charging: isCharging(netW: netW), externalConnected: raw.externalConnected)
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
            guard case .value(.battery) = raw, let s = batteryOverlay.sample else { return raw }
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
