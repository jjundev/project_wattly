import SwiftUI
import AppKit   // NSWorkspace for per-process app icons (issue 05)

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

    var body: some View {
        switch state {
        case .unavailable(let reason):
            unavailableCard(reason)
        case .loading, .value:
            standardCard
        }
    }

    // MARK: Standard card (loading or value)

    private var standardCard: some View {
        let d = CardPresentation.display(card, state)
        return VStack(alignment: .leading, spacing: 8) {
            headerRow(d)
            if hasValue {
                SparklineView(values: historyValues, stroke: sparkStroke, fill: hasSparkArea ? sparkFill : nil)
                if let sub = d.subText, !sub.isEmpty {
                    Text(sub)
                        .font(WattlyFont.at(11, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(t.sub)
                }
            }
            if isExpanded, isExpandable { expandRegion }
        }
        .padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(t.cardBg))
        .contentShape(Rectangle())
        .onTapGesture { onToggleExpand?() }
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
        .accessibilityElement(children: .combine)
    }

    // CPU per-core bars (04). Memory top-3 processes (05) still deferred.
    @ViewBuilder
    private var expandRegion: some View {
        if card == .cpu, case .value(.cpu(let s)) = state {
            cpuExpand(s)
        } else if card == .mem, case .value(.memory(let s)) = state {
            memExpand(s)
        } else if card == .cpuTemp, case .value(.temperature(let s)) = state, case .reading(let r) = s.cpu {
            tempExpand(r.groups)
        }
    }

    // Per-core bars grouped by runtime perf level (prototype lines 355–372).
    private func cpuExpand(_ s: CPUSample) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(s.perfLevels.enumerated()), id: \.offset) { idx, level in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(level.name)
                            .font(WattlyFont.at(11, weight: .bold))
                            .foregroundStyle(t.sub)
                        Spacer(minLength: 8)
                        Text("\(Int(level.usage.rounded()))%")
                            .font(WattlyFont.at(12, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(idx == 0 ? Tokens.accent : t.sub)
                    }
                    ForEach(Array(level.cores.enumerated()), id: \.offset) { ci, usage in
                        coreRow(label: "\(CardPresentation.corePrefix(level.name))\(ci)", usage: usage, accent: idx == 0)
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private func coreRow(label: String, usage: Double, accent: Bool) -> some View {
        HStack(spacing: 9) {
            Text(label)
                .font(WattlyFont.at(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(t.faint)
                .frame(width: 22, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(t.sparkFill)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(accent ? Tokens.accent : t.faint)
                        .frame(width: geo.size.width * min(100, max(0, usage)) / 100)
                }
            }
            .frame(height: 6)
            Text("\(Int(usage.rounded()))%")
                .font(WattlyFont.at(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(t.sub)
                .frame(width: 26, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(Int(usage.rounded())) 퍼센트")
    }

    // MARK: Memory expand — top processes (issue 05)

    /// Top memory processes. Bar color tracks the memory sparkline stroke (neutral
    /// at 05; threshold color once issue 10 lands — §M12). Bars are proportional to
    /// the largest process; empty → a faint line (§M16).
    @ViewBuilder
    private func memExpand(_ s: MemorySample) -> some View {
        let maxBytes = s.processes.first?.footprintBytes ?? 0
        VStack(alignment: .leading, spacing: 8) {
            if s.processes.isEmpty {
                Text("프로세스를 읽을 수 없음")
                    .font(WattlyFont.at(10.5, weight: .semibold))
                    .foregroundStyle(t.faint)
            } else {
                ForEach(s.processes) { p in
                    processRow(name: p.name, footprintBytes: p.footprintBytes, maxBytes: maxBytes, iconPath: p.iconPath)
                }
            }
        }
        .padding(.top, 4)
    }

    // Process row, pixel-matched to the prototype (lines 138–141): name 74 ellipsis
    // · bar h6 r3 · GB 46 right. Borrows coreRow's structure, not its sizing (§M13).
    private func processRow(name: String, footprintBytes: UInt64, maxBytes: UInt64, iconPath: String?) -> some View {
        HStack(spacing: 9) {
            appIcon(iconPath)
                .frame(width: 15, height: 15)
            Text(name)
                .font(WattlyFont.at(11, weight: .semibold))
                .foregroundStyle(t.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 74, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(t.sparkFill)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(sparkStroke)
                        .frame(width: geo.size.width * barFraction(footprint: footprintBytes, maxBytes: maxBytes))
                }
            }
            .frame(height: 6)
            Text(CardPresentation.gbText(footprintBytes))
                .font(WattlyFont.at(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(t.sub)
                .frame(width: 46, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(CardPresentation.gbText(footprintBytes))")
    }

    /// Small app icon from the resolved bundle/executable path (NSWorkspace caches
    /// these). nil path → a faint placeholder so the rows stay aligned.
    @ViewBuilder
    private func appIcon(_ path: String?) -> some View {
        if let path {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 3).fill(t.sparkFill)
        }
    }

    // MARK: Temperature expand — per-cluster summary (issue 08 follow-up)

    /// One row per cluster (P-코어 / E-코어 / GPU): a bar on a fixed 0–110 °C scale plus
    /// the cluster average and hottest sensor. The SMC exposes die-region sensors, not
    /// 1:1 cores, so a per-cluster average is the honest unit (not "per core").
    private func tempExpand(_ groups: [TemperatureGroup]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if groups.isEmpty {
                Text("센서를 읽을 수 없음")
                    .font(WattlyFont.at(10.5, weight: .semibold))
                    .foregroundStyle(t.faint)
            } else {
                ForEach(groups, id: \.name) { tempGroupRow($0) }
            }
        }
        .padding(.top, 8)
    }

    private func tempGroupRow(_ g: TemperatureGroup) -> some View {
        HStack(spacing: 9) {
            Text(g.name)
                .font(WattlyFont.at(10.5, weight: .semibold))
                .foregroundStyle(t.faint)
                .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(t.sparkFill)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(t.spark)
                        .frame(width: geo.size.width * CardPresentation.tempBarFraction(g.average))
                }
            }
            .frame(height: 6)
            Text(CardPresentation.clusterSummary(average: g.average, hottest: g.hottest))
                .font(WattlyFont.at(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(t.sub)
                .frame(width: 104, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(g.name), 평균 \(CardPresentation.f1(g.average))도, 최고 \(CardPresentation.f1(g.hottest))도")
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

    private var valueColor: Color { card.isAccented ? Tokens.accent : t.text }
    private var sparkStroke: Color { card.isAccented ? Tokens.accent : t.spark }
    private var sparkFill: Color { card.isAccented ? Color.rgba(0, 102, 255, 0.10) : t.sparkFill }
}
