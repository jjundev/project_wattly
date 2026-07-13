import Foundation

// MARK: - Poll interval

enum PollInterval: String, CaseIterable, Identifiable, Sendable {
    case auto
    case s1 = "1"
    case s2 = "2"
    case s5 = "5"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "자동"
        case .s1: "1초"
        case .s2: "2초"
        case .s5: "5초"
        }
    }
}

let automaticPollingDescription =
    "자동: 패널 열림은 CPU·전력 1초/온도 2초/메모리·배터리 5초, 닫힘은 메뉴바에 표시한 지표만 2초마다 갱신합니다. 텍스트를 끄면 지표 폴링을 멈춥니다."

// MARK: - Panel layout mode

/// Which popover layout the user has chosen (prototype `panelMode`, lines 408/791).
/// All three cases are defined now so the persisted schema is stable; the settings
/// segment exposes A·B until the hero mode (`.c`) ships in plan 20, and the popover
/// folds an unexpected `.c` back to `.a` defensively. `@AppStorage`-storable as a
/// String-raw enum, exactly like `ThemeMode`/`PollInterval`.
enum PanelMode: String, CaseIterable, Identifiable, Sendable {
    case a = "A"   // 스택 행 — full-width cards (mode A, the default)
    case b = "B"   // 카드 그리드 — 2-column compact tiles
    case c = "C"   // 히어로 + 리스트 (plan 20)

    var id: String { rawValue }

    var label: String {
        switch self {
        case .a: "스택 행"
        case .b: "카드 그리드"
        case .c: "히어로+리스트"
        }
    }
}

// MARK: - Thresholds (warn/crit per family)

struct ThresholdPair: Equatable, Sendable {
    var warn: Double
    var crit: Double
}

/// `@AppStorage`-storable via a JSON `RawRepresentable` (L12) — `@AppStorage` has
/// no native support for a nested value like this.
struct Thresholds: Equatable, Sendable, RawRepresentable {
    var cpu: ThresholdPair
    var mem: ThresholdPair
    var temp: ThresholdPair
    /// Color the memory card by the kernel's memory pressure (the macOS "활성 상태 보기"
    /// model) instead of by the `mem` warn/crit occupancy band. Rides along the existing
    /// `Thresholds` value so every `thresholdLevel`/`stateWord` call site — and `SettingsReset`
    /// — picks it up with no signature change. Defaults true (absent in older persisted JSON
    /// → `init?(rawValue:)` falls back to true).
    var memColorByPressure: Bool

    init(cpu: ThresholdPair, mem: ThresholdPair, temp: ThresholdPair,
         memColorByPressure: Bool = true) {
        self.cpu = cpu; self.mem = mem; self.temp = temp
        self.memColorByPressure = memColorByPressure
    }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        func pair(_ k: String) -> ThresholdPair? {
            guard let p = o[k] as? [String: Double], let w = p["warn"], let c = p["crit"] else { return nil }
            return ThresholdPair(warn: w, crit: c)
        }
        guard let c = pair("cpu"), let m = pair("mem"), let t = pair("temp") else { return nil }
        let byPressure = o["memColorByPressure"] as? Bool ?? true
        self.init(cpu: c, mem: m, temp: t, memColorByPressure: byPressure)
    }

    var rawValue: String {
        let o: [String: Any] = [
            "cpu": ["warn": cpu.warn, "crit": cpu.crit],
            "mem": ["warn": mem.warn, "crit": mem.crit],
            "temp": ["warn": temp.warn, "crit": temp.crit],
            "memColorByPressure": memColorByPressure,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: o),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Explicit memberwise equality. Without this, `==` resolves to a `rawValue`-string
    /// comparison (the `RawRepresentable` path), and `rawValue`'s JSON dictionary has a
    /// non-deterministic key order — so two value-equal `Thresholds` compare unequal almost
    /// every time. Compare the fields directly instead.
    static func == (lhs: Thresholds, rhs: Thresholds) -> Bool {
        lhs.cpu == rhs.cpu && lhs.mem == rhs.mem && lhs.temp == rhs.temp
            && lhs.memColorByPressure == rhs.memColorByPressure
    }
}

// MARK: - Threshold level (warn/crit classification)

/// Which band a metric value falls in, given its `ThresholdPair`. A pure semantic role
/// (no `Color`) — the view resolves it to status tokens, mirroring `CardDisplay.Tint`.
enum ThresholdLevel: String, CaseIterable, Sendable, Equatable {
    case normal, warn, crit

    /// Color-independent severity word for the non-color accessibility channel (issue 10
    /// §5; full VoiceOver copy is issue 15). `nil` for `.normal` — nothing to announce.
    var stateWord: String? {
        switch self {
        case .normal: nil
        case .warn: "주의"
        case .crit: "위험"
        }
    }
}

extension ThresholdPair {
    /// Which control a slider edits — drives the clamp direction (issue 10 §6).
    enum Control { case warn, crit }

    /// Classify a value: `v >= crit` → `.crit`, `v >= warn` → `.warn`, else `.normal`
    /// (inclusive, verbatim from the prototype `pickColor`).
    func level(_ v: Double) -> ThresholdLevel {
        if v >= crit { return .crit }
        if v >= warn { return .warn }
        return .normal
    }

    /// Apply a slider edit with the prototype's clamp (`setThreshold`): the edited control
    /// is authoritative and drags the other so `warn <= crit` always holds. Values round to
    /// whole numbers (the sliders step by 1).
    func setting(_ control: Control, to value: Double) -> ThresholdPair {
        let v = value.rounded()
        var p = self
        switch control {
        case .warn:
            p.warn = v
            if p.warn > p.crit { p.crit = p.warn }
        case .crit:
            p.crit = v
            if p.crit < p.warn { p.warn = p.crit }
        }
        return p
    }
}

// MARK: - Card order

/// `@AppStorage`-storable card order, persisted as a comma-separated list of card
/// raw values (L12).
struct CardOrder: Equatable, Sendable, RawRepresentable {
    var cards: [CardKind]

    init(_ cards: [CardKind]) { self.cards = cards }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ",").map(String.init)
        let cards = parts.compactMap { CardKind(rawValue: $0) }
        guard cards.count == parts.count, !cards.isEmpty else { return nil }
        self.init(cards)
    }

    var rawValue: String { cards.map(\.rawValue).joined(separator: ",") }

    /// Move `from` to sit adjacent to `target`, verbatim from the prototype `reorderCards`
    /// (line 453): dragging downward (`from` was above `target`) drops it *after* `target`;
    /// dragging upward drops it *before*. Operates on the full order — hidden cards keep
    /// their relative position — and both `from` and `target` are visible cards, so both are
    /// present. Pure/value-returning (the issue 12 §26 unit-tested seam); a no-op when
    /// `from == target` or either card isn't in the order.
    func reordering(_ from: CardKind, onto target: CardKind) -> CardOrder {
        guard from != target else { return self }
        var arr = cards
        guard let fi = arr.firstIndex(of: from),
              let ti = arr.firstIndex(of: target) else { return self }
        let down = fi < ti
        arr.remove(at: fi)
        guard let newTi = arr.firstIndex(of: target) else { return self }
        arr.insert(from, at: down ? newTi + 1 : newTi)
        return CardOrder(arr)
    }

    /// The cards that should render, in this order: present (provider/category not `.notPresent`,
    /// so desktop battery/batTemp drop out) AND shown (user toggle). The popover and the settings
    /// hero picker (plan 20) both compute their visible set through here, so the two can't drift.
    /// Pure given the two predicates (the caller passes `monitor.isPresent` + its show flags).
    func visible(present: (CardKind) -> Bool, shown: (CardKind) -> Bool) -> [CardKind] {
        cards.filter { present($0) && shown($0) }
    }
}

// MARK: - Single source of defaults

/// One place that both `@AppStorage` initial values and "reset to defaults" read,
/// so they can never drift (L12). Values from prototype lines 405–417 + plan
/// README §common tokens.
enum Defaults {
    static let theme = ThemeMode.dark
    static let pollInterval = PollInterval.auto
    static let panelMode = PanelMode.a       // ship default: full-width stacked cards (mode A)
    static let heroMetric = CardKind.power   // mode C hero (plan 20); falls back to first visible when hidden
    static let loginItem = true            // F1: a MIRROR of SMAppService — NOT authoritative
    static let menubarTextEnabled = true   // default menubar metric = CPU only
    static let powerSmoothed = true        // 프로세서 전력 + 배터리 카드: EMA-smoothed display (raw spikes mislead)

    static let show: [CardKind: Bool] = [
        .power: true, .battery: true, .cpu: true, .mem: true,
        .cpuTemp: true, .gpuTemp: true, .batTemp: true,
    ]
    static let menuMetrics: [CardKind: Bool] = [
        .cpu: true, .power: false, .mem: false,
        .cpuTemp: false, .gpuTemp: false, .batTemp: false,
    ]

    static let cardOrder = CardOrder([.power, .battery, .cpu, .mem, .cpuTemp, .gpuTemp, .batTemp])
    static let thresholds = Thresholds(
        cpu: ThresholdPair(warn: 70, crit: 90),
        mem: ThresholdPair(warn: 70, crit: 85),
        temp: ThresholdPair(warn: 70, crit: 90))
}

/// `@AppStorage` key names. `loginItem` is a mirror of `SMAppService.mainApp`
/// (the real source of truth), reconciled with `SMAppService.status` on launch —
/// wired in issue 13 (F1).
enum StorageKey {
    static func show(_ c: CardKind) -> String { "show.\(c.rawValue)" }
    static func menu(_ c: CardKind) -> String { "menu.\(c.rawValue)" }
    static let theme = "theme"
    static let pollInterval = "pollInterval"
    static let panelMode = "panelMode"
    static let heroMetric = "heroMetric"   // mode C hero metric (plan 20)
    static let loginItem = "loginItem"
    static let menubarTextEnabled = "menubarTextEnabled"
    static let powerSmoothed = "powerSmoothed"
    static let cardOrder = "cardOrder"
    static let thresholds = "thresholds"
    static let expandedCards = "expandedCards"   // CSV of expanded card raw values (issue 04)
}
