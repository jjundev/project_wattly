import Foundation

/// Pure VoiceOver-label assembly (issue 15). No SwiftUI, no I/O — the per-card spoken
/// label and the loading/unavailable copy live here as deterministic functions so they're
/// table-tested directly (issue 18), mirroring `MenuBarText`/`CardPresentation`.
///
/// Per decision B (grill 2026-06-22) the spoken units are the **symbols** the card shows
/// (`%`/`W`/`°C`/`GB`) — reusing `CardPresentation`'s value/unit text rather than spelling
/// them out — so the a11y copy and the visual copy share one source. The menubar label
/// reuses `MenuBarText.assemble` verbatim (§메모: share #14's logic).
///
/// Leak guard (§3): the unavailable branch emits only `reason.message`, which every
/// provider keeps as fixed human copy — a raw SMC key or kern return never reaches it.
enum Accessibility {
    /// The card's summary VoiceOver label: name + value(+unit) + folded sub-line, or the
    /// loading/unavailable copy. **Total** over `MetricState`.
    static func cardLabel(_ card: CardKind, _ state: MetricState) -> String {
        let name = CardPresentation.label(card)
        switch state {
        case .loading:
            return "\(name), 불러오는 중"
        case .unavailable(let reason):
            return "\(name), 사용 불가, \(reason.message)"
        case .value:
            var label = "\(name), \(headPhrase(card, state))"
            // Fold the sub-line in. For the power card the CPU/GPU/NPU breakdown lives ONLY
            // in the sub-line (the power expand shows the per-app Top-3, not the engine
            // split), so dropping it would lose the breakdown for VO.
            if let sub = CardPresentation.subText(state), !sub.isEmpty {
                label += ", \(sub)"
            }
            return label
        }
    }

    /// The non-color warn/crit word for the card's current value (issue 10 §5), or `nil`
    /// when threshold-free / no value. The view passes this as `.accessibilityValue`.
    static func stateWord(_ card: CardKind, _ state: MetricState, _ thresholds: Thresholds) -> String? {
        CardPresentation.thresholdLevel(card, state, thresholds)?.stateWord
    }

    /// The menubar VoiceOver label — "Wattly" plus the selected metrics in canonical order,
    /// computed regardless of whether the visible text is on (issue 15 §1). Decision A: an
    /// empty selection reads just "Wattly". Reuses the #14 assembler so the symbol copy
    /// matches the menubar text exactly.
    static func menuBarLabel(selected: Set<CardKind>, states: [CardKind: MetricState]) -> String {
        guard let metrics = MenuBarText.assemble(selected: selected, states: states) else { return "Wattly" }
        return "Wattly, \(metrics)"
    }

    /// The spoken "value unit" for a live card. Symbols per decision B; the battery uses a
    /// 충전/방전 word in place of the ± sign (issue 15 §7).
    private static func headPhrase(_ card: CardKind, _ state: MetricState) -> String {
        let v = CardPresentation.valueText(card, state)
        switch card {
        case .power: return "\(v) W"
        case .battery: return batteryPhrase(state) ?? "\(v) W"
        case .cpu: return "\(v)%"
        case .mem: return "\(v) GB"
        case .cpuTemp, .gpuTemp, .batTemp: return "\(v)°C"
        case .fan: return "\(v) RPM"
        }
    }

    /// "충전 5.0 W" / "방전 12.3 W" / "0.0 W" — the spoken battery value, a charging word
    /// instead of ± (and no word when |net| rounds to 0, matching the value's #17 rule).
    private static func batteryPhrase(_ state: MetricState) -> String? {
        guard case .value(.battery(let s)) = state else { return nil }
        let mag = CardPresentation.f1(abs(s.netW))
        switch CardPresentation.batterySign(netW: s.netW, charging: s.charging) {
        case "+": return "충전 \(mag) W"
        case "−": return "방전 \(mag) W"
        default:  return "\(mag) W"
        }
    }

    /// Fan-curve editor: the spoken label for one temperature anchor's handle ("40°C 팬 속도")
    /// and its value ("1200 RPM"). Pure so the copy is table-tested (issue 15), matching the
    /// symbol-based unit style of the rest of this file.
    static func fanAnchorLabel(celsius: Double) -> String { "\(Int(celsius))°C 팬 속도" }
    static func fanAnchorValue(rpm: Double) -> String { "\(Int(rpm.rounded())) RPM" }
}
