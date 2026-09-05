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
    var batteryControl: BatteryControlClient? = nil
    var scheduleCoordinator: BatteryScheduleCoordinator? = nil
    var calibration: BatteryCalibrationCoordinator? = nil

    @AppStorage(StorageKey.heroMetric) private var heroMetric = Defaults.heroMetric
    // Shared with mode A's `PopoverContentView.expandedRaw` — same key, same CSV Set (see the
    // doc comment above).
    @AppStorage(StorageKey.expandedCards) private var expandedRaw = ""
    @Environment(\.tokens) private var t
    @Environment(\.locale) private var locale

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
                         onToggleExpand: hero.isExpandable ? { toggleExpand(hero) } : nil,
                         batteryControl: batteryControl,
                         scheduleCoordinator: scheduleCoordinator,
                         calibration: calibration)
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
                Text(LocalizedStringKey(CardPresentation.label(card)))
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
        .accessibilityLabel(Accessibility.cardLabel(card, state, locale: locale))
        .accessibilityValue(Accessibility.stateWord(card, state, thresholds) ?? "")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(LocalizedStringKey("히어로로 강조")))
        .accessibilityAction { heroMetric = card }
    }
}

/// The dark hero card (prototype line 208): fixed `#171719` in both themes, radius 14, padding 16.
/// Its text + the neutral/accent spark colors are hardcoded light-on-dark (see `PopoverHeroView`).
/// `isExpandable` cards get the same chevron + tap-to-expand as mode A's stack rows (plan: hero
/// card expand) — the whole card is the tap target, matching `MetricCardView.standardCard`.
private struct HeroCard: View {
    @Environment(\.locale) private var locale
    let card: CardKind
    let state: MetricState
    var historyValues: [Double] = []
    var thresholds: Thresholds = Defaults.thresholds
    var isExpanded: Bool = false
    var onToggleExpand: (() -> Void)? = nil
    var batteryControl: BatteryControlClient? = nil
    var scheduleCoordinator: BatteryScheduleCoordinator? = nil
    var calibration: BatteryCalibrationCoordinator? = nil

    // Hardcoded light-on-dark surface/text (prototype line 208).
    private static let heroBg = Color(hex: "#171719")
    private static let labelColor = Color.rgba(247, 247, 248, 0.6)
    private static let unitColor = Color.rgba(247, 247, 248, 0.6)
    private static let subColor = Color.rgba(247, 247, 248, 0.55)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summary
                .contentShape(Rectangle())
                .onTapGesture { if hasChevron { onToggleExpand?() } }
            if isExpanded, hasChevron {
                CardExpandRegion(
                    card: card,
                    state: state,
                    thresholds: thresholds,
                    batteryControl: batteryControl,
                    scheduleCoordinator: scheduleCoordinator,
                    calibration: calibration
                )
                .environment(\.tokens, Tokens.dark)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Self.heroBg))
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
                Text(LocalizedStringKey(CardPresentation.label(card)))
                    .font(WattlyFont.at(11.5, weight: .semibold))
                    .foregroundStyle(Self.labelColor)
                    .lineLimit(1)
                if hasChevron {
                    Image(systemName: CardPresentation.expandChevronSymbol(isExpanded: isExpanded))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Self.labelColor)
                        .offset(y: CardPresentation.expandChevronYOffset)
                }
            }
            switch state {
            case .unavailable(let reason):
                // Hero unavailable (prototype line 211): same dark card + the full reason.
                Text(LocalizedStringKey(reason.message))
                    .font(WattlyFont.at(12, weight: .regular))
                    .foregroundStyle(Self.subColor)
                    .fixedSize(horizontal: false, vertical: true)
            case .loading, .value:
                valueBody
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Accessibility.cardLabel(card, state, locale: locale))
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
        let d = CardPresentation.display(card, state, dischargeOwner: dischargeOwner, locale: locale)
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
        subTextView(d.subText)
            .font(WattlyFont.at(11, weight: .regular))
            .monospacedDigit()
            .foregroundStyle(Self.subColor)
    }

    @ViewBuilder
    private func subTextView(_ fallbackSubText: String?) -> some View {
        if isDischarging, case .value(.battery(let s)) = state {
            let target = batteryControl?.status.desiredConfiguration?.manualDischargeTarget ?? s.targetPercentage
            let currentPct = s.percentage ?? (batteryControl?.status.currentPercentage ?? 0)
            let watts = s.netW > 0 ? -s.netW : s.netW
            let desc = BatterySectionPresentation.dischargeDescription(owner: dischargeOwner, target: target, currentSoC: currentPct, watts: watts, locale: locale)
            Text(desc)
                .lineLimit(isExpanded ? 2 : 1)
                .fixedSize(horizontal: false, vertical: isExpanded)
        } else if let sub = fallbackSubText, !sub.isEmpty {
            Text(sub)
                .lineLimit(isExpanded ? 2 : 1)
                .fixedSize(horizontal: false, vertical: isExpanded)
        }
    }

    private var dischargeOwner: BatterySectionPresentation.DischargeOwner {
        BatterySectionPresentation.dischargeOwner(
            manualDischargeActive: batteryControl?.status.desiredConfiguration?.manualDischargeActive,
            reasonKind: batteryControl?.status.detailReason?.kind,
            activity: batteryControl?.status.activity)
    }

    private var isDischarging: Bool {
        if card == .battery {
            if BatterySectionPresentation.isForcedDischargeRunning(
                reasonKind: batteryControl?.status.detailReason?.kind,
                activity: batteryControl?.status.activity)
                || batteryControl?.status.desiredConfiguration?.manualDischargeActive == true {
                return true
            }
            if case .value(.battery(let s)) = state {
                return s.powerFlow?.scenario == .activeDischarge
            }
        }
        return false
    }

    // Spark colors on the DARK hero card (prototype heroColorMap 705–715): threshold cards use the
    // theme-independent status colors; the accented (power) card uses an on-dark accent (#3385ff,
    // NOT the panel accent #0066ff); everything else (battery / neutral) uses a light-on-dark tone.
    private var sparkStroke: Color {
        if isDischarging { return Tokens.statusOrange }
        if let level = CardPresentation.thresholdLevel(card, state, thresholds) { return level.stroke }
        return card.isAccented ? Color(hex: "#3385ff") : .rgba(247, 247, 248, 0.85)
    }

    private var sparkFill: Color {
        if isDischarging { return Tokens.statusOrange.opacity(0.18) }
        if let level = CardPresentation.thresholdLevel(card, state, thresholds) { return level.fill }
        return card.isAccented ? .rgba(51, 133, 255, 0.18) : .rgba(247, 247, 248, 0.12)
    }

    private var hasValue: Bool { if case .value = state { return true }; return false }

    // No chevron/expand for an unavailable card — mirrors `MetricCardView`, which renders a
    // completely separate `unavailableCard` layout with no header/chevron machinery at all.
    private var isUnavailable: Bool { if case .unavailable = state { return true }; return false }
    private var hasChevron: Bool { card.isExpandable && !isUnavailable }
}
