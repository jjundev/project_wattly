import SwiftUI

/// One mode-A card, pixel-matched to the prototype (lines 84–168). Switches layout
/// by card family and by state (loading "—" / value / unavailable). A thin renderer:
/// all text/number/unit/sign rules live in `CardPresentation` (pure), and the
/// card-family shape lives on `CardKind`; this view only lays out SwiftUI primitives
/// and resolves the `tint` role to theme tokens.
struct MetricCardView: View {
    @Environment(\.tokens) private var t
    let card: CardKind
    let state: MetricState
    var historyValues: [Double] = []
    var isExpanded: Bool = false
    var onToggleExpand: (() -> Void)? = nil
    var thresholds: Thresholds = Defaults.thresholds

    var body: some View {
        switch state {
        case .unavailable(let reason):
            unavailableCard(reason)
                // Whole unavailable card → one VO element: "<이름>, 사용 불가, <사유>" (§3).
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Accessibility.cardLabel(card, state))
        case .loading, .value:
            standardCard
        }
    }

    // MARK: Standard card (loading or value)

    private var standardCard: some View {
        let d = CardPresentation.display(card, state)
        return VStack(alignment: .leading, spacing: 8) {
            summaryGroup(d)
            if isExpanded, isExpandable { expandRegion }
        }
        .padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(t.cardBg))
        .contentShape(Rectangle())
        .onTapGesture { onToggleExpand?() }
    }

    /// The card's spoken summary: header + sparkline + sub-line collapsed into ONE VoiceOver
    /// element (issue 15 §2) carrying the composed label + warn/crit value. The sparkline is
    /// decorative (hidden); the sub-line is folded into the label by `Accessibility.cardLabel`,
    /// not read separately (§4/§5). `expandRegion` stays a SIBLING outside this element so its
    /// per-core/process/cluster rows remain individually navigable (§6). Expandable cards
    /// expose an `.accessibilityAction` so VoiceOver can toggle the expand the mouse toggles
    /// via the card's `.onTapGesture` (a gesture VO can't otherwise actuate).
    @ViewBuilder
    private func summaryGroup(_ d: CardDisplay) -> some View {
        let summary = VStack(alignment: .leading, spacing: 8) {
            headerRow(d)
            if hasValue {
                SparklineView(values: historyValues, stroke: sparkStroke, fill: hasSparkArea ? sparkFill : nil)
                    .accessibilityHidden(true)
                if let sub = d.subText, !sub.isEmpty {
                    Text(sub)
                        .font(WattlyFont.at(11, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(t.sub)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Accessibility.cardLabel(card, state))
        .accessibilityValue(Accessibility.stateWord(card, state, thresholds) ?? "")

        if isExpandable {
            summary
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onToggleExpand?() }
        } else {
            summary
        }
    }

    private func headerRow(_ d: CardDisplay) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 5) {
                Text(d.label)
                    .font(WattlyFont.at(11.5, weight: .semibold))
                    .foregroundStyle(t.sub)
                    .fixedSize()
                if hasChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(t.sub)
                }
            }
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(d.valueText)
                    .font(WattlyFont.at(19, weight: .bold)).tracking(-0.19)
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                Text(d.unitText)
                    .font(WattlyFont.at(12, weight: .semibold))
                    .foregroundStyle(t.sub)
            }
        }
        // The card's VoiceOver element + warn/crit value live on `summaryGroup` (issue 15);
        // the header row itself is decorative inside that `.ignore` container.
    }

    // Content lives in the shared `CardExpandRegion` (plan: hero card expand) — mode C's
    // hero card reuses it too, with `Tokens.dark` force-injected instead of the live theme.
    private var expandRegion: some View {
        CardExpandRegion(card: card, state: state, thresholds: thresholds)
    }

    // MARK: Unavailable cards

    @ViewBuilder
    private func unavailableCard(_ reason: MetricUnavailableReason) -> some View {
        switch card {
        case .power: powerUnavailable(reason)
        case .battery: batteryUnavailable(reason)
        default: genericUnavailable(reason)
        }
    }

    // Orange warning card (prototype lines 91–94).
    private func powerUnavailable(_ reason: MetricUnavailableReason) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: "#d47800"))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(CardPresentation.label(card)).font(WattlyFont.at(11.5, weight: .semibold)).foregroundStyle(t.text)
                Text(reason.message)
                    .font(WattlyFont.at(11, weight: .regular)).lineSpacing(1.5)
                    .foregroundStyle(t.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.rgba(255, 146, 0, 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.rgba(255, 146, 0, 0.22), lineWidth: 1))
    }

    // Dashed slash-circle card (prototype lines 105–108).
    private func batteryUnavailable(_ reason: MetricUnavailableReason) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "nosign")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(t.faint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(CardPresentation.label(card)).font(WattlyFont.at(11.5, weight: .semibold)).foregroundStyle(t.sub)
                Text(reason.message).font(WattlyFont.at(11, weight: .regular)).foregroundStyle(t.faint)
            }
        }
        .padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundStyle(t.panelBorder))
    }

    // Temperatures etc. — minimal muted card (full behavior is issue 08).
    private func genericUnavailable(_ reason: MetricUnavailableReason) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(CardPresentation.label(card)).font(WattlyFont.at(11.5, weight: .semibold)).foregroundStyle(t.sub)
                Spacer(minLength: 8)
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(t.faint)
            }
            Text(reason.message)
                .font(WattlyFont.at(11, weight: .regular))
                .foregroundStyle(t.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(t.cardBg))
    }

    // MARK: Card-family attributes

    // Structural shape comes from `CardKind`; this view only resolves the accent
    // `tint` role to theme tokens (neutral tokens are theme-dependent; the accent is
    // the static brand color).
    private var isExpandable: Bool { card.isExpandable }
    private var hasChevron: Bool { isExpandable }
    private var hasSparkArea: Bool { card.hasSparkArea }   // battery: polyline only (line 100)
    private var hasValue: Bool { if case .value = state { return true }; return false }

    // The headline value keeps its neutral/accent color — the threshold color lands only
    // on the sparkline + memory process bars (issue 10, matching the prototype).
    private var valueColor: Color { card.isAccented ? Tokens.accent : t.text }
    private var sparkStroke: Color {
        if let level = thresholdLevel { return level.stroke }
        return card.isAccented ? Tokens.accent : t.spark
    }
    private var sparkFill: Color {
        if let level = thresholdLevel { return level.fill }
        return card.isAccented ? Color.rgba(0, 102, 255, 0.10) : t.sparkFill
    }

    /// Warn/crit color level for this card's current value (issue 10), or nil when the card
    /// is threshold-free (power/battery) or has no value. Drives the sparkline stroke/fill
    /// — and, since the memory process bars fill with `sparkStroke`, those too — never the
    /// headline `valueColor`.
    private var thresholdLevel: ThresholdLevel? {
        CardPresentation.thresholdLevel(card, state, thresholds)
    }
}
