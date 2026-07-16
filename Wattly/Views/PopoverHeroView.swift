import SwiftUI

/// Mode C — the dark hero card + a label↔value list (prototype lines 207–222). One promoted
/// metric is shown large (40px) on a fixed-dark card; every other visible card is a compact row,
/// and tapping a row promotes it to hero. The visible set + order arrive from `PopoverContentView`
/// (`cardOrder ∩ isPresent ∩ isShown`); the hero choice is the shared `@AppStorage(heroMetric)`,
/// so the settings picker and a row tap stay in sync for free.
///
/// The hero card also supports the SAME tap-to-expand as mode A's stack rows (plan: hero card
/// expand) — `isExpandable` cards get a chevron and reveal `CardExpandRegion` beneath the
/// sub-line on tap. The expand SET is the shared `@AppStorage(expandedCards)` mode A already
/// uses (one CSV Set keyed by `CardKind`, not per-mode) — a card left expanded in mode A shows
/// expanded here too if it becomes the hero, and vice versa; this is a deliberate, accepted
/// consequence of reusing "which cards are expanded" as one concept rather than inventing a
/// second mode-C-only flag.
///
/// Because the hero card is dark in BOTH themes, its text and the neutral/accent spark colors are
/// hardcoded light-on-dark — they CANNOT reuse the theme tokens (`t.spark`/`Tokens.accent`) the
/// way modes A/B do, or they'd vanish in light mode. The expand region is the one exception: it
/// reuses `CardExpandRegion` (shared with mode A) but with `Tokens.dark` force-injected via
/// `.environment(\.tokens, ...)`, since `Tokens.dark`'s colors are computed independent of the
/// app's current theme and already match the hero's fixed dark background (see `Tokens.swift`).
/// Threshold-driven cards still reuse the theme-independent status colors. The list below the
/// hero sits on the panel background and uses the theme tokens normally. Power-type cards get
/// the EMA-smoothed series (same toggle as mode A).
struct PopoverHeroView: View {
    let cards: [CardKind]
    let monitor: SystemMonitor
    var thresholds: Thresholds = Defaults.thresholds
    var powerSmoothed: Bool

    @AppStorage(StorageKey.heroMetric) private var heroMetric = Defaults.heroMetric
    // Shared with mode A's `PopoverContentView.expandedRaw` — same key, same CSV Set (see the
    // doc comment above).
    @AppStorage(StorageKey.expandedCards) private var expandedRaw = ""
    @Environment(\.tokens) private var t

    private var hero: CardKind? {
        CardPresentation.resolveHero(persisted: heroMetric, visible: cards)
    }
    private var expanded: Set<CardKind> { CardPresentation.expandedCards(from: expandedRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // hero == nil only when nothing is visible (all cards hidden) → render nothing, no crash.
            if let hero {
                HeroCard(card: hero,
                         state: monitor.cardState(hero, smoothed: powerSmoothed),
                         historyValues: monitor.historyValues(for: hero, smoothed: powerSmoothed),
                         thresholds: thresholds,
                         isExpanded: expanded.contains(hero),
                         onToggleExpand: hero.isExpandable ? { toggleExpand(hero) } : nil)
                list(excluding: hero)
            }
        }
        .padding(.vertical, 1)
    }

    private func toggleExpand(_ card: CardKind) {
        expandedRaw = CardPresentation.togglingExpanded(card, in: expandedRaw)
    }

    // The list = the visible cards minus the hero, in `cardOrder` order (prototype 213–220).
    private func list(excluding hero: CardKind) -> some View {
        let rows = cards.filter { $0 != hero }
        return VStack(spacing: 0) {
            ForEach(rows) { card in
                listRow(card,
                        monitor.cardState(card, smoothed: powerSmoothed),
                        divider: card != rows.last)
            }
        }
    }

    private func listRow(_ card: CardKind, _ state: MetricState, divider: Bool) -> some View {
        let unavailable: Bool = { if case .unavailable = state { return true }; return false }()
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(CardPresentation.label(card))
                    .font(WattlyFont.at(13, weight: .semibold))
                    .foregroundStyle(t.cText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(CardPresentation.compactRowText(card, state))
                    .font(WattlyFont.at(14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(unavailable ? t.faint : t.cText)
                    .lineLimit(1)
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 6)
            if divider {
                Rectangle().fill(t.line).frame(height: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { heroMetric = card }
        // One VoiceOver element per row: the card summary + a promote action (issue 15 regs reused).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Accessibility.cardLabel(card, state))
        .accessibilityValue(Accessibility.stateWord(card, state, thresholds) ?? "")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("히어로로 강조")
        .accessibilityAction { heroMetric = card }
    }
}

/// The dark hero card (prototype line 208): fixed `#171719` in both themes, radius 14, padding 16.
/// Its text + the neutral/accent spark colors are hardcoded light-on-dark (see `PopoverHeroView`).
/// `isExpandable` cards get the same chevron + tap-to-expand as mode A's stack rows (plan: hero
/// card expand) — the whole card is the tap target, matching `MetricCardView.standardCard`.
private struct HeroCard: View {
    let card: CardKind
    let state: MetricState
    var historyValues: [Double] = []
    var thresholds: Thresholds = Defaults.thresholds
    var isExpanded: Bool = false
    var onToggleExpand: (() -> Void)? = nil

    // Hardcoded light-on-dark surface/text (prototype line 208).
    private static let heroBg = Color(hex: "#171719")
    private static let labelColor = Color.rgba(247, 247, 248, 0.6)
    private static let unitColor = Color.rgba(247, 247, 248, 0.6)
    private static let subColor = Color.rgba(247, 247, 248, 0.55)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summary
            if isExpanded, hasChevron {
                CardExpandRegion(card: card, state: state, thresholds: thresholds)
                    .environment(\.tokens, Tokens.dark)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Self.heroBg))
        .contentShape(Rectangle())
        .onTapGesture { onToggleExpand?() }
    }

    /// The hero's spoken summary — its own VoiceOver element, a SIBLING of the expand region
    /// (mirrors `MetricCardView.summaryGroup`/`expandRegion`, issue 15 §2/§6), so the expand
    /// rows stay individually navigable instead of being swallowed into one combined element.
    /// Mouse taps toggle via `HeroCard.body`'s `.onTapGesture`; VoiceOver toggles via the
    /// `.accessibilityAction` here (a gesture VO can't otherwise actuate).
    @ViewBuilder
    private var summary: some View {
        let content = VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Text(CardPresentation.label(card))
                    .font(WattlyFont.at(11.5, weight: .semibold))
                    .foregroundStyle(Self.labelColor)
                    .lineLimit(1)
                if hasChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Self.labelColor)
                }
            }
            switch state {
            case .unavailable(let reason):
                // Hero unavailable (prototype line 211): same dark card + the full reason.
                Text(reason.message)
                    .font(WattlyFont.at(12, weight: .regular))
                    .foregroundStyle(Self.subColor)
                    .fixedSize(horizontal: false, vertical: true)
            case .loading, .value:
                valueBody
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Accessibility.cardLabel(card, state))
        .accessibilityValue(Accessibility.stateWord(card, state, thresholds) ?? "")

        if hasChevron {
            content
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onToggleExpand?() }
        } else {
            content
        }
    }

    // value 40/700 white + unit 16/600 → spark (h32, area+line) → sub 11 (prototype 208).
    @ViewBuilder private var valueBody: some View {
        let d = CardPresentation.display(card, state)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(d.valueText)
                .font(WattlyFont.at(40, weight: .bold)).tracking(-1.2)
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(d.unitText)
                .font(WattlyFont.at(16, weight: .semibold))
                .foregroundStyle(Self.unitColor)
                .lineLimit(1)
        }
        if hasValue {
            // The hero always draws area + line, even for the battery card (which is line-only in
            // mode A) — prototype-faithful (line 208 renders a polygon for every metric).
            SparklineView(values: historyValues, stroke: sparkStroke, fill: sparkFill, height: 32)
                .accessibilityHidden(true)
        }
        if let sub = d.subText {
            Text(sub)
                .font(WattlyFont.at(11, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(Self.subColor)
                .lineLimit(1)
        }
    }

    // Spark colors on the DARK hero card (prototype heroColorMap 705–715): threshold cards use the
    // theme-independent status colors; the accented (power) card uses an on-dark accent (#3385ff,
    // NOT the panel accent #0066ff); everything else (battery / neutral) uses a light-on-dark tone.
    private var sparkStroke: Color {
        if let level = CardPresentation.thresholdLevel(card, state, thresholds) { return level.stroke }
        return card.isAccented ? Color(hex: "#3385ff") : .rgba(247, 247, 248, 0.85)
    }

    private var sparkFill: Color {
        if let level = CardPresentation.thresholdLevel(card, state, thresholds) { return level.fill }
        return card.isAccented ? .rgba(51, 133, 255, 0.18) : .rgba(247, 247, 248, 0.12)
    }

    private var hasValue: Bool { if case .value = state { return true }; return false }

    // No chevron/expand for an unavailable card — mirrors `MetricCardView`, which renders a
    // completely separate `unavailableCard` layout with no header/chevron machinery at all.
    private var isUnavailable: Bool { if case .unavailable = state { return true }; return false }
    private var hasChevron: Bool { card.isExpandable && !isUnavailable }
}
