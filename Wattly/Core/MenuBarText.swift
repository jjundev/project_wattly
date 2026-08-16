import Foundation

/// Pure menubar-text assembly (issue 14). No SwiftUI, no I/O — the per-metric compact
/// format and the join rule live here as deterministic functions so they're table-tested
/// directly (issue 18); `MenuBarLabel` only supplies the selection + per-card states.
///
/// The menubar format is deliberately its OWN copy table, NOT `CardPresentation`'s: the
/// menubar drops the power label ("8.4 W", not "프로세서 전력 8.4 W"), shows memory as
/// " GB" (not "/ N GB"), and uses SHORT warm temperature labels ("CPU 54°C") with LONG
/// cold labels ("CPU 온도 —"). Reusing `CardPresentation.label` would print
/// "프로세서 전력 —" for cold power and "CPU 온도 54°C" for warm temps — both wrong.
/// Verbatim from the prototype (lines 663–668).
enum MenuBarText {
    /// Canonical menubar order for CardKind metrics. Used when converting a Set<CardKind>
    /// into ordered items, while `MenuBarItem` handles full canonical ordering including sub-metrics.
    static let order: [CardKind] = [.cpu, .gpu, .power, .battery, .mem, .cpuTemp, .gpuTemp, .fan]

    /// The joined menubar string for the specified items in their given order, or `nil`
    /// when `items` is empty. Missing states fall back to `.loading` (cold placeholders).
    static func assemble(items: [MenuBarItem], states: [CardKind: MetricState]) -> String? {
        guard !items.isEmpty else { return nil }
        let parts = items.map { formatItem($0, states: states) }
        return parts.joined(separator: "  ·  ")
    }

    /// Formats a single `MenuBarItem` using the appropriate card state from `states`.
    static func formatItem(_ item: MenuBarItem, states: [CardKind: MetricState]) -> String {
        let state = states[item.requiredCard] ?? .loading
        switch item {
        case .card(let kind):
            return part(kind, state)
        case .coreClock(let prefix):
            return coreClockPart(prefix, state)
        case .memPressure:
            return memPressurePart(state)
        case .batteryTemp:
            return batteryTempPart(state)
        }
    }

    /// The joined menubar string for the selected metrics in canonical order, or `nil`
    /// when none is selected (→ icon only, the prototype's `hasMenuMetric`). Parts join
    /// with the prototype's two-space middle-dot. A selected card missing from `states`
    /// is treated as `.loading` (→ its cold placeholder), so the result is always total.
    static func assemble(selected: Set<CardKind>, states: [CardKind: MetricState]) -> String? {
        let items = order.filter(selected.contains).map { MenuBarItem.card($0) }
        return assemble(items: items, states: states)
    }


    /// One metric's compact part. A live value formats per metric; loading/unavailable
    /// yields the long-label placeholder "<label> —". **Total** over `MetricState`, so callers
    /// are always safe.
    static func part(_ card: CardKind, _ state: MetricState) -> String {
        guard case .value(let sample) = state else { return "\(longLabel(card)) —" }
        switch (card, sample) {
        case (.cpu, .cpu(let s)):             return "CPU \(Int(s.overall.rounded()))%"
        case (.gpu, .gpu(let s)):             return "GPU \(Int(s.overall.rounded()))%"
        case (.power, .power(let s)):         return "\(CardPresentation.f1(s.totalW)) W"
        case (.battery, .battery(let s)):
            return "\(CardPresentation.batterySign(netW: s.netW, charging: s.charging))\(CardPresentation.f1(abs(s.netW))) W"
        case (.mem, .memory(let s)):          return "\(CardPresentation.f1(s.usedGB)) GB"
        case (.cpuTemp, .temperature(let s)): return tempPart("CPU", longLabel(card), s.cpu)
        case (.gpuTemp, .temperature(let s)): return tempPart("GPU", longLabel(card), s.gpu)
        case (.fan, .fan(let s)):
            return averageRPM(s.fans).map { "팬 \(Int($0.rounded())) RPM" } ?? "\(longLabel(card)) —"
        default:                              return "\(longLabel(card)) —"   // state/sample mismatch
        }
    }

    /// Cold/unavailable prefix — the LONG form (prototype 663–668). Distinct from the
    /// warm temperature labels (short "CPU"/"GPU"), which is exactly why this
    /// cannot reuse `CardPresentation.label` (whose power label is "프로세서 전력").
    private static func longLabel(_ card: CardKind) -> String {
        switch card {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .power: "전력"
        case .mem: "메모리"
        case .cpuTemp: "CPU 온도"
        case .gpuTemp: "GPU 온도"
        case .fan: "팬"
        case .battery: "배터리"
        }
    }

    /// A temperature category's compact part: short warm label + integer °C, or the long
    /// cold label when the category isn't a live reading (the menubar value rounds to a
    /// whole degree — coarser than the card's one-decimal headline, per prototype 666–668).
    private static func tempPart(_ shortLabel: String, _ longLabel: String, _ category: CategoryReading) -> String {
        if case .reading(let r) = category { return "\(shortLabel) \(Int(r.celsius.rounded()))°C" }
        return "\(longLabel) —"
    }

    /// The battery temperature chip's compact part (menubar items update).
    static func batteryTempPart(_ state: MetricState) -> String {
        guard case .value(.battery(let s)) = state, let c = s.temperatureCelsius else { return "배터리 온도 —" }
        return "배터리 \(Int(c.rounded()))°C"
    }

    /// The memory-pressure-percent chip's compact part (menubar items update) — independent
    /// of the `.mem` GB chip, since pressure and GB are separately selectable. "압력 —" when
    /// the card isn't a live memory reading, or the kernel didn't supply a percent this poll
    /// (never a fake "압력 0%" — mirrors the card sub-line's own rule).
    static func memPressurePart(_ state: MetricState) -> String {
        guard case .value(.memory(let s)) = state, let p = s.pressurePercent else { return "압력 —" }
        return "압력 \(p)%"
    }

    /// A CPU cluster's active clock, selected by its runtime-name prefix letter (S/P/E —
    /// Apple Silicon chip generations name their fast cluster "Performance" (P/E chips,
    /// M1–M4) or "Super" (S/E chips, e.g. M5); exposing all three as independent menubar
    /// toggles lets one persisted choice work across hardware, since only the cluster(s)
    /// actually present on a given Mac ever produce a live reading (menubar items update).
    /// "<prefix> 코어 클럭 —" when no cluster with this prefix exists this poll, or its
    /// clock source has no reading yet (baseline poll / unsupported DVFS residency source).
    static func coreClockPart(_ prefix: String, _ state: MetricState) -> String {
        let cold = "\(prefix) 코어 클럭 —"
        guard case .value(.cpu(let s)) = state,
              let level = s.perfLevels.first(where: { CardPresentation.corePrefix($0.name) == prefix }),
              let ghz = level.activeGHz
        else { return cold }
        return "\(prefix) \(CardPresentation.ghzText(ghz))"
    }
}
