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
    /// Canonical menubar order = the prototype's source order. Battery net-power is not
    /// menubar-eligible (there is no battery chip — see `Defaults.menuMetrics`).
    static let order: [CardKind] = [.cpu, .power, .mem, .cpuTemp, .gpuTemp, .batTemp]

    /// The joined menubar string for the selected metrics in canonical order, or `nil`
    /// when none is selected (→ icon only, the prototype's `hasMenuMetric`). Parts join
    /// with the prototype's two-space middle-dot. A selected card missing from `states`
    /// is treated as `.loading` (→ its cold placeholder), so the result is always total.
    static func assemble(selected: Set<CardKind>, states: [CardKind: MetricState]) -> String? {
        let parts = order.filter(selected.contains).map { part($0, states[$0] ?? .loading) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    /// One metric's compact part. A live value formats per metric; loading/unavailable
    /// (incl. desktop battery temp, which fans out to `.unavailable(.notPresent)`) yields
    /// the long-label placeholder "<label> —". **Total** over `MetricState`, so callers
    /// are always safe.
    static func part(_ card: CardKind, _ state: MetricState) -> String {
        guard case .value(let sample) = state else { return "\(longLabel(card)) —" }
        switch (card, sample) {
        case (.cpu, .cpu(let s)):             return "CPU \(Int(s.overall.rounded()))%"
        case (.power, .power(let s)):         return "\(CardPresentation.f1(s.totalW)) W"
        case (.mem, .memory(let s)):          return "\(CardPresentation.f1(s.usedGB)) GB"
        case (.cpuTemp, .temperature(let s)): return tempPart("CPU", longLabel(card), s.cpu)
        case (.gpuTemp, .temperature(let s)): return tempPart("GPU", longLabel(card), s.gpu)
        case (.batTemp, .temperature(let s)): return tempPart("배터리", longLabel(card), s.battery)
        default:                              return "\(longLabel(card)) —"   // state/sample mismatch
        }
    }

    /// Cold/unavailable prefix — the LONG form (prototype 663–668). Distinct from the
    /// warm temperature labels (short "CPU"/"GPU"/"배터리"), which is exactly why this
    /// cannot reuse `CardPresentation.label` (whose power label is "프로세서 전력").
    private static func longLabel(_ card: CardKind) -> String {
        switch card {
        case .cpu: "CPU"
        case .power: "전력"
        case .mem: "메모리"
        case .cpuTemp: "CPU 온도"
        case .gpuTemp: "GPU 온도"
        case .batTemp: "배터리 온도"
        case .battery: "배터리"   // not menubar-eligible; present only so the switch is total
        }
    }

    /// A temperature category's compact part: short warm label + integer °C, or the long
    /// cold label when the category isn't a live reading (the menubar value rounds to a
    /// whole degree — coarser than the card's one-decimal headline, per prototype 666–668).
    private static func tempPart(_ shortLabel: String, _ longLabel: String, _ category: CategoryReading) -> String {
        if case .reading(let r) = category { return "\(shortLabel) \(Int(r.celsius.rounded()))°C" }
        return "\(longLabel) —"
    }
}
