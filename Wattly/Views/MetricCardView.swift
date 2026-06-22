import SwiftUI
import AppKit   // NSWorkspace for per-process app icons (issue 05)

/// One mode-A card, pixel-matched to the prototype (lines 84–168). Switches layout
/// by card family and by state (loading "—" / value / unavailable). Sparkline band
/// is reserved (issue 03); expand content for CPU/memory is issues 04/05.
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
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            if hasValue {
                SparklineView(values: historyValues, stroke: sparkStroke, fill: hasSparkArea ? sparkFill : nil)
                if let sub = subText, !sub.isEmpty {
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

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 5) {
                Text(label)
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
                Text(valueText)
                    .font(WattlyFont.at(19, weight: .bold)).tracking(-0.19)
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                Text(unitText)
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
                        coreRow(label: "\(corePrefix(level.name))\(ci)", usage: usage, accent: idx == 0)
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

    /// Runtime perf-level name → single-letter label prefix ("Performance" → "P").
    private func corePrefix(_ name: String) -> String {
        name.first.map { String($0).uppercased() } ?? "C"
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
            Text(gbText(footprintBytes))
                .font(WattlyFont.at(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(t.sub)
                .frame(width: 46, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(gbText(footprintBytes))")
    }

    private func gbText(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / (1024.0 * 1024.0 * 1024.0))
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
                        .frame(width: geo.size.width * Self.tempBarFraction(g.average))
                }
            }
            .frame(height: 6)
            Text("\(f1(g.average))° · 최고 \(f1(g.hottest))°")
                .font(WattlyFont.at(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(t.sub)
                .frame(width: 104, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(g.name), 평균 \(f1(g.average))도, 최고 \(f1(g.hottest))도")
    }

    /// Bar fill fraction on a fixed 0–110 °C display scale (issue 08 §8; neutral color —
    /// threshold coloring is issue 10).
    private static func tempBarFraction(_ celsius: Double) -> Double {
        min(1, max(0, celsius / 110.0))
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
                Text(label).font(WattlyFont.at(11.5, weight: .semibold)).foregroundStyle(t.text)
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
                Text(label).font(WattlyFont.at(11.5, weight: .semibold)).foregroundStyle(t.sub)
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
                Text(label).font(WattlyFont.at(11.5, weight: .semibold)).foregroundStyle(t.sub)
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

    private var isExpandable: Bool { card == .cpu || card == .mem || card == .cpuTemp }
    private var hasChevron: Bool { isExpandable }
    private var hasSparkArea: Bool { card != .battery }   // battery: polyline only (line 100)
    private var hasValue: Bool { if case .value = state { return true }; return false }

    private var valueColor: Color { card == .power ? Tokens.accent : t.text }
    private var sparkStroke: Color { card == .power ? Tokens.accent : t.spark }
    private var sparkFill: Color { card == .power ? Color.rgba(0, 102, 255, 0.10) : t.sparkFill }

    private var label: String {
        switch card {
        case .power: "프로세서 전력"
        case .battery: "배터리"
        case .cpu: "CPU"
        case .mem: "메모리"
        case .cpuTemp: "CPU 온도"
        case .gpuTemp: "GPU 온도"
        case .batTemp: "배터리 온도"
        }
    }

    private var unitText: String {
        switch card {
        case .power, .battery: return "W"
        case .cpu: return "%"
        case .mem:
            if case .value(.memory(let s)) = state { return "/ \(Int(s.totalGB)) GB" }
            return "GB"
        case .cpuTemp, .gpuTemp, .batTemp: return "°C"
        }
    }

    private var valueText: String {
        guard case .value(let sample) = state else { return "—" }
        switch (card, sample) {
        case (.power, .power(let s)): return f1(s.totalW)
        case (.battery, .battery(let s)):
            // #17: drop the sign when the magnitude rounds to 0.0 (AC 연결·완충 등 net≈0)
            // so the card shows "0.0", never a meaningless "−0.0".
            let mag = abs(s.netW)
            return (mag < 0.05 ? "" : (s.charging ? "+" : "−")) + f1(mag)
        case (.cpu, .cpu(let s)): return String(Int(s.overall.rounded()))
        case (.mem, .memory(let s)): return f1(s.usedGB)
        case (.cpuTemp, .temperature(let s)): return tempText(s.cpu)
        case (.gpuTemp, .temperature(let s)): return tempText(s.gpu)
        case (.batTemp, .temperature(let s)): return tempText(s.battery)
        default: return "—"
        }
    }

    private var subText: String? {
        guard case .value(let sample) = state else { return nil }
        switch sample {
        case .power(let s):
            return "CPU \(f1(s.cpuW)) W · GPU \(f1(s.gpuW)) W · NPU \(f1(s.npuW)) W"
        case .battery(let s):
            // #17: same zero-magnitude → no-sign rule as the value (keeps mA in step).
            let sign = abs(s.netW) < 0.05 ? "" : (s.charging ? "+" : "−")
            return "\(sign)\(s.milliamps) mA · \(f1(s.volts)) V · \(s.charging ? "충전 중" : "방전 중")"
        case .cpu(let s):
            // Order-based (not name-coupled): runtime perf-level names ("Performance"/
            // "Efficiency" → "P"/"E") differ from the prototype's "S". Guard
            // single-cluster hardware (<2 levels) against an out-of-range read.
            guard s.perfLevels.count >= 2 else {
                guard let only = s.perfLevels.first else { return nil }
                return "\(corePrefix(only.name)) \(Int(only.usage.rounded()))%"
            }
            let a = s.perfLevels[0], b = s.perfLevels[1]
            return "\(corePrefix(a.name)) \(Int(a.usage.rounded()))% · \(corePrefix(b.name)) \(Int(b.usage.rounded()))%"
        case .memory(let s):
            return "고정 \(f1(s.wiredGB)) GB · 압축 \(f1(s.compressedGB)) GB"
        case .temperature:
            return nil
        }
    }

    private func f1(_ x: Double) -> String { String(format: "%.1f", x) }

    private func tempText(_ c: CategoryReading) -> String {
        if case .reading(let r) = c { return f1(r.celsius) }
        return "—"
    }
}
