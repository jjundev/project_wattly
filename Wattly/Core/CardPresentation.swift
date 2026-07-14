import Foundation

/// What one card shows, derived purely from its kind + current state. Colors are
/// expressed as a semantic `tint` role (the view resolves it to a theme token), so
/// this stays pure and theme-independent — it is the interface a test crosses
/// instead of having to render a SwiftUI `View`.
struct CardDisplay: Equatable {
    /// Header label (Korean copy).
    var label: String
    /// Headline number. `"—"` when there is no value; carries the battery +/− sign rule.
    var valueText: String
    /// `"W"` / `"%"` / `"°C"` / `"/ 16 GB"` / `"GB"`.
    var unitText: String
    /// Sub-line; nil when absent (loading/unavailable, and the temperature cards).
    var subText: String?
    /// `.accent` for the processor-power card, else `.neutral`. The view maps this to
    /// `Tokens.accent` vs the neutral theme tokens.
    var tint: Tint
    enum Tint: Equatable { case accent, neutral }
}

/// Pure card-presentation helpers (the deepened module behind `MetricCardView`).
/// Mirrors the `PowerSmoothing` namespace idiom: an `enum` of `static` funcs over the
/// model value types — no SwiftUI, no I/O — so every display rule (the sign
/// convention, units, formatters, the temperature scale) has one tested home.
///
/// Korean copy lives here, the same way `MetricUnavailableReason.message` and
/// `ThemeMode.label` carry their own copy (localization is a separate concern).
enum CardPresentation {
    /// The full standard-card content for a card + its current state. **Total** over
    /// `MetricState`: `.loading`/`.unavailable` yield `valueText == "—"` (so callers
    /// like `MenuBarLabel` are always safe). The unavailable *layout* is the view's
    /// concern; it still shares `label(_:)` for its copy.
    static func display(_ card: CardKind, _ state: MetricState) -> CardDisplay {
        CardDisplay(label: label(card),
                    valueText: valueText(card, state),
                    unitText: unitText(card, state),
                    subText: subText(state),
                    tint: card.isAccented ? .accent : .neutral)
    }

    /// Which card is the hero in mode C (plan 20, prototype lines 693–695): the persisted choice
    /// when it's still visible, else the first visible card, else `nil` (nothing visible). State-
    /// agnostic by design — `visible` is the popover's `visibleCards`, which keeps present-but-
    /// unavailable cards, so the hero can legitimately resolve to a card that renders its
    /// unavailable face. "First visible" follows the passed (cardOrder) order.
    static func resolveHero(persisted: CardKind, visible: [CardKind]) -> CardKind? {
        visible.contains(persisted) ? persisted : visible.first
    }

    /// One compact list-row value for the mode-C list (plan 20). **Total** over `MetricState`,
    /// reusing `valueText`/`unitText` so the battery sign (#17) and every unit stay correct and in
    /// step with the cards — including the battery-temperature `°C` the prototype `rowOf` (lines
    /// 677–682) dropped to `W`. Loading → `"—"`; unavailable → the short reason (the view tints it
    /// faint). CPU joins its `%` tight (`"42%"`); every other unit is spaced (`"8.4 W"`).
    static func compactRowText(_ card: CardKind, _ state: MetricState) -> String {
        switch state {
        case .unavailable(let reason): return reason.shortMessage
        case .loading: return "—"
        case .value:
            let v = valueText(card, state)
            let u = unitText(card, state)
            return card == .cpu ? v + u : "\(v) \(u)"
        }
    }

    /// Warn/crit color level for a card's current value, or `nil` when the card is
    /// threshold-free (processor power = accent, battery = neutral) or has no value
    /// (loading/unavailable). The view resolves the level to status tokens and applies it
    /// to the **sparkline + memory process bars only** — the headline `valueColor` keeps
    /// its neutral/accent color, matching the prototype (which colors only the spark).
    ///
    /// Memory colors by the kernel's **memory pressure** when `thresholds.memColorByPressure`
    /// is on (the macOS "활성 상태 보기" model), else by **used%** (`usedGB/totalGB*100`, the
    /// prototype `memPct`); either way the headline GB and the GB sparkline series are
    /// unaffected — only the band/color changes. Temperature compares
    /// the category **average** (`celsius`) — the same number the card displays (the
    /// prototype fed the max; the average is the steadier, self-consistent input). The three
    /// temperature cards share the one `thresholds.temp` pair (prototype lines 616–620).
    static func thresholdLevel(_ card: CardKind, _ state: MetricState, _ thresholds: Thresholds) -> ThresholdLevel? {
        guard case .value(let sample) = state else { return nil }
        switch (card, sample) {
        case (.cpu, .cpu(let s)):
            return thresholds.cpu.level(s.overall)
        case (.mem, .memory(let s)):
            // Pressure mode (macOS "활성 상태 보기" 모델): color by the kernel's pressure
            // verdict, not occupancy. Falls back to the used% band when the toggle is off OR
            // the sysctl was unavailable this poll (`pressure == nil`).
            if thresholds.memColorByPressure, let p = s.pressure {
                return p.thresholdLevel
            }
            let pct = s.totalGB > 0 ? s.usedGB / s.totalGB * 100 : 0
            return thresholds.mem.level(pct)
        case (.cpuTemp, .temperature(let s)): return tempLevel(s.cpu, thresholds.temp)
        case (.gpuTemp, .temperature(let s)): return tempLevel(s.gpu, thresholds.temp)
        case (.batTemp, .temperature(let s)): return tempLevel(s.battery, thresholds.temp)
        default: return nil   // power/battery (fixed) + any state/sample mismatch
        }
    }

    /// A temperature category's level, or `nil` when it isn't a live reading.
    private static func tempLevel(_ c: CategoryReading, _ pair: ThresholdPair) -> ThresholdLevel? {
        if case .reading(let r) = c { return pair.level(r.celsius) }
        return nil
    }

    /// Header label. Shared with the in-view unavailable cards, which keep their own
    /// layout but the same copy.
    static func label(_ card: CardKind) -> String {
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

    /// Unit suffix. Mostly static per card; the memory card's `/ N GB` is the one
    /// state-dependent unit (it reads the total off the sample).
    static func unitText(_ card: CardKind, _ state: MetricState) -> String {
        switch card {
        case .power, .battery: return "W"
        case .cpu: return "%"
        case .mem:
            if case .value(.memory(let s)) = state { return "/ \(Int(s.totalGB)) GB" }
            return "GB"
        case .cpuTemp, .gpuTemp, .batTemp: return "°C"
        }
    }

    /// Headline value text. `"—"` whenever there is no value.
    static func valueText(_ card: CardKind, _ state: MetricState) -> String {
        guard case .value(let sample) = state else { return "—" }
        switch (card, sample) {
        case (.power, .power(let s)): return f1(s.totalW)
        case (.battery, .battery(let s)):
            // #17: drop the sign when the magnitude rounds to 0.0 (AC 연결·완충 등 net≈0)
            // so the card shows "0.0", never a meaningless "−0.0".
            return batterySign(netW: s.netW, charging: s.charging) + f1(abs(s.netW))
        case (.cpu, .cpu(let s)): return String(Int(s.overall.rounded()))
        case (.mem, .memory(let s)): return f1(s.usedGB)
        case (.cpuTemp, .temperature(let s)): return tempText(s.cpu)
        case (.gpuTemp, .temperature(let s)): return tempText(s.gpu)
        case (.batTemp, .temperature(let s)): return tempText(s.battery)
        default: return "—"
        }
    }

    /// Sub-line beneath the sparkline. nil for loading/unavailable and for the
    /// temperature cards (which carry their detail in the expand region).
    static func subText(_ state: MetricState) -> String? {
        guard case .value(let sample) = state else { return nil }
        switch sample {
        case .power(let s):
            return "CPU \(f1(s.cpuW)) W · GPU \(f1(s.gpuW)) W · NPU \(f1(s.npuW)) W"
        case .battery(let s):
            // #17: same zero-magnitude → no-sign rule as the value (keeps mA in step).
            let sign = batterySign(netW: s.netW, charging: s.charging)
            let base = "\(sign)\(s.milliamps) mA · \(f1(s.volts)) V · \(s.charging ? "충전 중" : "방전 중")"
            guard let average = s.average1mW else { return base }
            return "\(base) · 1분 평균 \(f1(abs(average))) W"
        case .cpu(let s):
            // Order-based (not name-coupled): runtime perf-level names ("Performance"/
            // "Efficiency" → "P"/"E") differ from the prototype's "S". Guard
            // single-cluster hardware (<2 levels) against an out-of-range read.
            guard s.perfLevels.count >= 2 else {
                guard let only = s.perfLevels.first else { return nil }
                return clusterSubText(only)
            }
            let a = s.perfLevels[0], b = s.perfLevels[1]
            return "\(clusterSubText(a)) · \(clusterSubText(b))"
        case .memory(let s):
            return "고정 \(f1(s.wiredGB)) GB · 압축 \(f1(s.compressedGB)) GB · 스왑 \(f1(s.swapUsedGB)) GB"
        case .temperature:
            return nil
        }
    }

    // MARK: Shared display rules

    /// The battery sign rule (#17), one home: drop the ± when |netW| rounds to 0.0 so
    /// the value and the mA sub-line never disagree. `""` / `"+"` (charging) / `"−"`.
    static func batterySign(netW: Double, charging: Bool) -> String {
        abs(netW) < 0.05 ? "" : (charging ? "+" : "−")
    }

    /// Runtime perf-level name → single-letter label prefix ("Performance" → "P").
    static func corePrefix(_ name: String) -> String {
        name.first.map { String($0).uppercased() } ?? "C"
    }

    /// One cluster's collapsed sub-line token: "<prefix> [<GHz> ]<usage>%" (plan 21 follow-up
    /// — the clock is visible in the collapsed summary, not only the expand region, so users
    /// don't have to tap the card open to see it). The GHz clause is present only once the
    /// clock source has a reading; nil (unavailable / baseline poll) collapses back to the
    /// pre-clock "<prefix> <usage>%" format, so this is source-compatible with every existing
    /// call.
    private static func clusterSubText(_ level: PerfLevelUsage) -> String {
        let ghz = level.activeGHz.map { "\(ghzText($0)) " } ?? ""
        return "\(corePrefix(level.name)) \(ghz)\(Int(level.usage.rounded()))%"
    }

    /// One-decimal fixed format, used across every card's value/sub-line.
    static func f1(_ x: Double) -> String { String(format: "%.1f", x) }

    /// GHz → "X.XX GHz" for the CPU card's per-cluster clock (plan 21). Two decimals:
    /// cluster active clock sits in a tight ~1–5 GHz range where 0.01 GHz (10 MHz) is the
    /// meaningful resolution.
    static func ghzText(_ ghz: Double) -> String {
        String(format: "%.2f GHz", ghz)
    }

    /// Bytes → "X.X GB" for the memory card's process rows.
    static func gbText(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / (1024.0 * 1024.0 * 1024.0))
    }

    /// Watts → "X.XX W" for the power card's per-app rows (issue 16 follow-up). 2 decimals:
    /// per-app watts are small (sub-watt to a few W), so the headline's 1-decimal `f1`
    /// would lose resolution.
    static func wattText(_ watts: Double) -> String { String(format: "%.2f W", watts) }

    /// Bar fill fraction on the fixed 0–110 °C display scale (issue 08 §8). Clamped.
    static func tempBarFraction(_ celsius: Double) -> Double {
        min(1, max(0, celsius / 110.0))
    }

    /// One cluster's "평균 · 최고" summary line for the temperature expand.
    static func clusterSummary(average: Double, hottest: Double) -> String {
        "\(f1(average))° · 최고 \(f1(hottest))°"
    }

    private static func tempText(_ c: CategoryReading) -> String {
        if case .reading(let r) = c { return f1(r.celsius) }
        return "—"
    }
}
