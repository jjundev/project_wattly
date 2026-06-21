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

    init(cpu: ThresholdPair, mem: ThresholdPair, temp: ThresholdPair) {
        self.cpu = cpu; self.mem = mem; self.temp = temp
    }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Double]]
        else { return nil }
        func pair(_ k: String) -> ThresholdPair? {
            guard let p = o[k], let w = p["warn"], let c = p["crit"] else { return nil }
            return ThresholdPair(warn: w, crit: c)
        }
        guard let c = pair("cpu"), let m = pair("mem"), let t = pair("temp") else { return nil }
        self.init(cpu: c, mem: m, temp: t)
    }

    var rawValue: String {
        let o: [String: [String: Double]] = [
            "cpu": ["warn": cpu.warn, "crit": cpu.crit],
            "mem": ["warn": mem.warn, "crit": mem.crit],
            "temp": ["warn": temp.warn, "crit": temp.crit],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: o),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
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
}

// MARK: - Single source of defaults

/// One place that both `@AppStorage` initial values and "reset to defaults" read,
/// so they can never drift (L12). Values from prototype lines 405–417 + plan
/// README §common tokens.
enum Defaults {
    static let theme = ThemeMode.dark
    static let pollInterval = PollInterval.auto
    static let loginItem = true            // F1: a MIRROR of SMAppService — NOT authoritative
    static let menubarTextEnabled = true   // default menubar metric = CPU only

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
    static let loginItem = "loginItem"
    static let menubarTextEnabled = "menubarTextEnabled"
    static let cardOrder = "cardOrder"
    static let thresholds = "thresholds"
    static let expandedCards = "expandedCards"   // CSV of expanded card raw values (issue 04)
}
