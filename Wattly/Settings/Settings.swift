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

enum PowerMode: String, CaseIterable, Identifiable, Sendable {
    case eco
    case performance

    var id: String { rawValue }

    var label: String {
        switch self {
        case .eco: "스마트(권장)"
        case .performance: "고성능"
        }
    }
}

enum BackgroundRefreshPreset: String, CaseIterable, Identifiable, Sendable {
    case eco
    case performance
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .eco: "스마트(권장)"
        case .performance: "고성능"
        case .custom: "사용자 지정"
        }
    }

    static func resolve(interval: PollInterval, mode: PowerMode) -> BackgroundRefreshPreset {
        if interval != .auto { return .custom }
        return mode == .eco ? .eco : .performance
    }
}


func pollingDescription(for setting: PollInterval, mode: PowerMode) -> String {
    switch setting {
    case .s1: "패널 상태와 관계없이 활성 지표를 1초마다 갱신합니다."
    case .s2: "패널 상태와 관계없이 활성 지표를 2초마다 갱신합니다."
    case .s5: "패널 상태와 관계없이 활성 지표를 5초마다 갱신합니다."
    case .auto:
        switch mode {
        case .eco:
            "패널을 열면 CPU·전력은 1초(오픈 즉시 표시), 온도는 2초, 메모리·배터리는 5초마다 갱신합니다. 패널을 닫으면 메뉴바 텍스트 또는 Kinetic Notch 모션에 필요한 지표만 2~5초마다 갱신합니다."
        case .performance:
            "패널을 열면 CPU·전력·온도는 1초, 메모리·팬은 3초마다 갱신합니다. 패널을 닫으면 지표 특성과 전원 상태(배터리/충전)에 맞춰 최적화하여 갱신합니다."
        }
    }
}

// MARK: - Panel layout mode

/// Which popover layout the user has chosen (prototype `panelMode`, lines 408/791).
/// All three cases are defined now so the persisted schema is stable; the settings
/// segment exposes A·B until the hero mode (`.c`) ships in plan 20, and the popover
/// folds an unexpected `.c` back to `.a` defensively. `@AppStorage`-storable as a
/// String-raw enum, exactly like `ThemeMode`/`PollInterval`.
enum PanelMode: String, CaseIterable, Identifiable, Sendable {
    case a = "A"   // 스택 행 — full-width cards (mode A, the default)
    case c = "C"   // 히어로 + 리스트 (plan 20)
    case b = "B"   // 카드 그리드 — 2-column compact tiles

    var id: String { rawValue }

    var label: String {
        switch self {
        case .a: "스택 행"
        case .c: "히어로 + 리스트"
        case .b: "카드 그리드"
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
    var temp: ThresholdPair
    var gpu: ThresholdPair?

    init(cpu: ThresholdPair, temp: ThresholdPair, gpu: ThresholdPair? = nil) {
        self.cpu = cpu
        self.temp = temp
        self.gpu = gpu
    }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cpuObject = object["cpu"] as? [String: Double],
              let tempObject = object["temp"] as? [String: Double],
              let cpuWarn = cpuObject["warn"], let cpuCrit = cpuObject["crit"],
              let tempWarn = tempObject["warn"], let tempCrit = tempObject["crit"]
        else { return nil }

        self.cpu = ThresholdPair(warn: cpuWarn, crit: cpuCrit)
        self.temp = ThresholdPair(warn: tempWarn, crit: tempCrit)

        if let gpuObject = object["gpu"] as? [String: Double],
           let gpuWarn = gpuObject["warn"], let gpuCrit = gpuObject["crit"] {
            self.gpu = ThresholdPair(warn: gpuWarn, crit: gpuCrit)
        } else {
            self.gpu = nil
        }
    }

    var rawValue: String {
        var dict: [String: Any] = [
            "cpu": ["warn": cpu.warn, "crit": cpu.crit],
            "temp": ["warn": temp.warn, "crit": temp.crit]
        ]
        if let g = gpu {
            dict["gpu"] = ["warn": g.warn, "crit": g.crit]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let string = String(data: data, encoding: .utf8)
        else { return "" }
        return string
    }

    /// Memberwise equality — NOT JSON string equality (#L12).
    static func == (lhs: Thresholds, rhs: Thresholds) -> Bool {
        lhs.cpu == rhs.cpu && lhs.temp == rhs.temp && lhs.gpu == rhs.gpu
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
        let parsed = parts.compactMap { CardKind(rawValue: $0) }
        guard !parsed.isEmpty else { return nil }

        var arr: [CardKind] = []
        var seen = Set<CardKind>()
        for card in parsed where seen.insert(card).inserted {
            arr.append(card)
        }
        let missing = CardKind.allCases.filter { !seen.contains($0) }

        // When migrating newly added cards:
        // .gpu belongs immediately after .cpu, others (e.g. .fan) go at the end.
        for card in missing {
            if card == .gpu, let cpuIdx = arr.firstIndex(of: .cpu) {
                arr.insert(.gpu, at: cpuIdx + 1)
            } else {
                arr.append(card)
            }
        }

        // Legacy fix: If .gpu was appended at the very end by an older migration
        // while .cpu precedes .mem, reposition .gpu directly after .cpu.
        if arr.last == .gpu,
           let cpuIdx = arr.firstIndex(of: .cpu),
           let memIdx = arr.firstIndex(of: .mem),
           cpuIdx < memIdx {
            arr.removeLast()
            arr.insert(.gpu, at: cpuIdx + 1)
        }

        self.init(arr)
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
    /// so desktop battery drops out) AND shown (user toggle). The popover and the settings
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
    static let theme = ThemeMode.system
    static let pollInterval = PollInterval.auto
    static let powerMode = PowerMode.eco
    static let panelMode = PanelMode.c       // ship default: hero + list (mode C)
    static let heroMetric = CardKind.power   // mode C hero (plan 20); falls back to first visible when hidden
    static let loginItem = true            // F1: a MIRROR of SMAppService — NOT authoritative
    static let menubarTextEnabled = true   // default menubar metric = power only
    static let kineticNotchMotionEnabled = true
    static let kineticNotchSource = KineticNotchSource.power
    static let kineticNotchSpeed = KineticNotchSpeed.smart
    static let menubarIconStyle = MenuBarIconStyle.hillRunner
    static let powerSmoothed = true        // 프로세서 전력 + 배터리 카드: EMA-smoothed display (raw spikes mislead)
    /// Battery health can feel sensitive as it declines from 100%, so keep it opt-in.
    static let showBatteryEfficiency = false
    static let memoryProcessLimit = 5
    static let powerProcessLimit = 5

    static let show: [CardKind: Bool] = [
        .power: true, .battery: true, .cpu: true, .gpu: true, .mem: true,
        .cpuTemp: true, .gpuTemp: true, .fan: true,
    ]
    static let menuMetrics: [CardKind: Bool] = [
        .cpu: false, .gpu: false, .power: true, .battery: false, .mem: false,
        .cpuTemp: false, .gpuTemp: false, .fan: false,
    ]
    /// Battery temperature menubar toggle. Default off.
    static let menuBatteryTempEnabled = false
    /// Memory pressure % is a menubar-only figure with no `CardKind` of its own — a distinct
    /// figure from the `.mem` GB chip (independently toggleable — user decision). Default off,
    /// matching every non-CPU menubar chip.
    static let menuMemPressureEnabled = false
    /// Per-cluster CPU clock menubar toggles, keyed by runtime-name prefix letter (S/P/E —
    /// see `MenuBarText.coreClockPart`). All default off; only the letter(s) matching a given
    /// Mac's actual clusters ever show a live reading once enabled.
    static let menuCoreClockEnabled: [String: Bool] = ["S": false, "P": false, "E": false]

    static let cardOrder = CardOrder([.power, .battery, .cpu, .gpu, .mem, .cpuTemp, .gpuTemp, .fan])
    static let cardVisibility = CardVisibility()
    static let menuBarSelection = MenuBarSelection()
    static let thresholds = Thresholds(
        cpu: ThresholdPair(warn: 70, crit: 90),
        temp: ThresholdPair(warn: 70, crit: 90),
        gpu: nil
    )
    /// Fan curve: target RPMs at the fixed 30…100 °C anchors (5° steps). A gentle ramp — quiet
    /// at idle, spinning up toward the fan's top end under sustained heat.
    static let fanCurve = FanCurve(rpms: [800, 900, 1000, 1200, 1500, 1900, 2400, 3000, 3600, 4200, 4800, 5500, 6000, 6300, 6500])
    /// Opt-in only: without an explicit user choice the helper is never asked to take over.
    static let fanControlEnabled = false
}

/// `@AppStorage` key names. `loginItem` is a mirror of `SMAppService.mainApp`
/// (the real source of truth), reconciled with `SMAppService.status` on launch —
/// wired in issue 13 (F1).
enum StorageKey {
    static func show(_ c: CardKind) -> String { "show.\(c.rawValue)" }
    static func menu(_ c: CardKind) -> String { "menu.\(c.rawValue)" }
    static func menuCoreClock(_ prefix: String) -> String { "menu.coreClock.\(prefix)" }
    static let theme = "theme"
    static let pollInterval = "pollInterval"
    static let powerMode = "powerMode"
    static let panelMode = "panelMode"
    static let heroMetric = "heroMetric"   // mode C hero metric (plan 20)
    static let loginItem = "loginItem"
    static let menubarTextEnabled = "menubarTextEnabled"
    static let kineticNotchMotionEnabled = "kineticNotchMotionEnabled"
    static let kineticNotchSource = "kineticNotchSource"
    static let kineticNotchSpeed = "kineticNotchSpeed"
    static let menubarIconStyle = "menubarIconStyle"
    static let powerSmoothed = "powerSmoothed"
    static let showBatteryEfficiency = "showBatteryEfficiency"
    static let memoryProcessLimit = "memoryProcessLimit"
    static let powerProcessLimit = "powerProcessLimit"
    static let cardOrder = "cardOrder"
    static let thresholds = "thresholds"
    static let fanCurve = "fanCurve"
    static let fanControlEnabled = "fanControlEnabled"
    static let menuBatteryTemp = "menu.batteryTemp"
    static let menuMemPressure = "menu.memPressure"
    static let expandedCards = "expandedCards"   // CSV of expanded card raw values (issue 04)
}
