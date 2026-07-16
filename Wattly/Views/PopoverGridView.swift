import SwiftUI

/// Mode B — the 2-column card grid (prototype lines 177–202). A compact restyle of the
/// SAME visible cards mode A shows: header label + 24px value + a mini polyline
/// sparkline, with no sub-line, no chevron, no expand and no drag. It reuses
/// `CardPresentation` (numbers/labels/units), `SparklineView`, and `Accessibility`, so the
/// text and colors track mode A automatically — only the layout differs.
///
/// The visible set + order are resolved by `PopoverContentView` (`cardOrder ∩ isPresent ∩
/// isShown`) and passed in, so desktop hiding (battery/batTemp) and live show-toggle
/// updates come for free without duplicating the `@AppStorage` show flags here.
struct PopoverGridView: View {
    let cards: [CardKind]
    let monitor: SystemMonitor
    var thresholds: Thresholds = Defaults.thresholds
    /// Power-type cards show the EMA-smoothed series (same toggle as mode A).
    var powerSmoothed: Bool

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(cards) { card in
                GridTile(card: card,
                         state: monitor.cardState(card, smoothed: powerSmoothed),
                         historyValues: monitor.historyValues(for: card, smoothed: powerSmoothed),
                         thresholds: thresholds)
            }
        }
        .padding(.vertical, 1)
    }
}

/// One grid tile — value/loading or unavailable. A thin renderer over `CardPresentation`
/// (pure), pixel-matched to the prototype mode-B tile: border-only (no fill), 24px value,
/// mini sparkline, no sub-line.
private struct GridTile: View {
    @Environment(\.tokens) private var t
    let card: CardKind
    let state: MetricState
    var historyValues: [Double] = []
    var thresholds: Thresholds = Defaults.thresholds

    var body: some View {
        switch state {
        case .unavailable:
            unavailableTile
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Accessibility.cardLabel(card, state))
        case .loading, .value:
            valueTile
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Accessibility.cardLabel(card, state))
                .accessibilityValue(Accessibility.stateWord(card, state, thresholds) ?? "")
        }
    }

    // Value / loading tile (prototype lines 179–201): label 10.5/600 → value 24/700 + unit
    // → mini polyline spark (h22, no area). Border 1px `gridBorder`, no background.
    private var valueTile: some View {
        let d = CardPresentation.display(card, state)
        return VStack(alignment: .leading, spacing: 6) {
            Text(d.label)
                .font(WattlyFont.at(10.5, weight: .semibold))
                .foregroundStyle(t.sub)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(d.valueText)
                    .font(WattlyFont.at(24, weight: .bold)).tracking(-0.48)
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                Text(d.unitText)
                    .font(WattlyFont.at(12, weight: .semibold))
                    .foregroundStyle(t.sub)
                    .lineLimit(1)
            }
            if hasValue {
                // Polyline only (prototype mode-B spark has no area), 22px band.
                SparklineView(values: historyValues, stroke: sparkStroke, fill: nil, height: 22)
                    .accessibilityHidden(true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Tokens.cardRadius).strokeBorder(t.gridBorder, lineWidth: 1))
    }

    // Unavailable tile (prototype lines 182–183): dashed border + label + short reason.
    private var unavailableTile: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(CardPresentation.label(card))
                .font(WattlyFont.at(10.5, weight: .semibold))
                .foregroundStyle(t.sub)
                .lineLimit(1)
            if case .unavailable(let reason) = state {
                Text(reason.shortMessage)
                    .font(WattlyFont.at(10.5, weight: .regular))
                    .foregroundStyle(t.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Tokens.cardRadius)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundStyle(t.panelBorder))
    }

    // The headline keeps its neutral/accent color; the threshold color lands only on the
    // sparkline stroke — same rule as mode A (`MetricCardView`).
    private var valueColor: Color { card.isAccented ? Tokens.accent : t.text }

    private var sparkStroke: Color {
        if let level = CardPresentation.thresholdLevel(card, state, thresholds) { return level.stroke }
        return card.isAccented ? Tokens.accent : t.spark
    }

    private var hasValue: Bool { if case .value = state { return true }; return false }
}
