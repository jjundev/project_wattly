import Foundation
import SwiftUI
import Observation

/// Encapsulates the visibility (show/hide) state of all 8 metric cards.
/// Provides a unified query API while remaining 100% backward compatible with `StorageKey.show(card)`.
struct CardVisibility: Sendable, Equatable {
    private var flags: [CardKind: Bool]

    init(flags: [CardKind: Bool] = Defaults.show) {
        var merged = Defaults.show
        for (k, v) in flags {
            merged[k] = v
        }
        self.flags = merged
    }

    init(userDefaults: UserDefaults) {
        var flags: [CardKind: Bool] = [:]
        for card in CardKind.allCases {
            if let obj = userDefaults.object(forKey: StorageKey.show(card)) as? Bool {
                flags[card] = obj
            } else {
                flags[card] = Defaults.show[card] ?? true
            }
        }
        self.flags = flags
    }

    func isShown(_ card: CardKind) -> Bool {
        flags[card] ?? Defaults.show[card] ?? true
    }

    mutating func setShown(_ card: CardKind, _ shown: Bool) {
        flags[card] = shown
    }

    var activeCards: Set<CardKind> {
        Set(CardKind.allCases.filter { isShown($0) })
    }

    func write(to defaults: UserDefaults = .standard) {
        for card in CardKind.allCases {
            defaults.set(isShown(card), forKey: StorageKey.show(card))
        }
    }
}

/// Encapsulates active menubar item selections and their required telemetry card dependencies.
/// Provides canonical order item assembly and 100% backward compatibility with `StorageKey.menu*`.
struct MenuBarSelection: Sendable, Equatable {
    var cardSelections: [CardKind: Bool]
    var coreClockSelections: [String: Bool]
    var isBatteryTempSelected: Bool
    var isMemPressureSelected: Bool

    init(
        cardSelections: [CardKind: Bool] = Defaults.menuMetrics,
        coreClockSelections: [String: Bool] = Defaults.menuCoreClockEnabled,
        isBatteryTempSelected: Bool = Defaults.menuBatteryTempEnabled,
        isMemPressureSelected: Bool = Defaults.menuMemPressureEnabled
    ) {
        var mergedCards = Defaults.menuMetrics
        for (k, v) in cardSelections {
            mergedCards[k] = v
        }
        self.cardSelections = mergedCards

        var mergedClocks = Defaults.menuCoreClockEnabled
        for (k, v) in coreClockSelections {
            mergedClocks[k] = v
        }
        self.coreClockSelections = mergedClocks

        self.isBatteryTempSelected = isBatteryTempSelected
        self.isMemPressureSelected = isMemPressureSelected
    }

    init(userDefaults: UserDefaults) {
        var cards: [CardKind: Bool] = [:]
        for card in CardKind.allCases {
            if let obj = userDefaults.object(forKey: StorageKey.menu(card)) as? Bool {
                cards[card] = obj
            } else {
                cards[card] = Defaults.menuMetrics[card] ?? false
            }
        }
        self.cardSelections = cards

        var clocks: [String: Bool] = [:]
        for prefix in ["S", "P", "E"] {
            if let obj = userDefaults.object(forKey: StorageKey.menuCoreClock(prefix)) as? Bool {
                clocks[prefix] = obj
            } else {
                clocks[prefix] = Defaults.menuCoreClockEnabled[prefix] ?? false
            }
        }
        self.coreClockSelections = clocks

        if let obj = userDefaults.object(forKey: StorageKey.menuBatteryTemp) as? Bool {
            self.isBatteryTempSelected = obj
        } else {
            self.isBatteryTempSelected = Defaults.menuBatteryTempEnabled
        }

        if let obj = userDefaults.object(forKey: StorageKey.menuMemPressure) as? Bool {
            self.isMemPressureSelected = obj
        } else {
            self.isMemPressureSelected = Defaults.menuMemPressureEnabled
        }
    }

    func isSelected(_ card: CardKind) -> Bool {
        cardSelections[card] ?? Defaults.menuMetrics[card] ?? false
    }

    mutating func setSelected(_ card: CardKind, _ selected: Bool) {
        cardSelections[card] = selected
    }

    func isCoreClockSelected(_ prefix: String) -> Bool {
        coreClockSelections[prefix] ?? Defaults.menuCoreClockEnabled[prefix] ?? false
    }

    mutating func setCoreClockSelected(_ prefix: String, _ selected: Bool) {
        coreClockSelections[prefix] = selected
    }

    mutating func setBatteryTempSelected(_ selected: Bool) {
        isBatteryTempSelected = selected
    }

    mutating func setMemPressureSelected(_ selected: Bool) {
        isMemPressureSelected = selected
    }

    func isItemSelected(_ item: MenuBarItem) -> Bool {
        switch item {
        case .card(let card): return isSelected(card)
        case .coreClock(let prefix): return isCoreClockSelected(prefix)
        case .memPressure: return isMemPressureSelected
        case .batteryTemp: return isBatteryTempSelected
        }
    }

    mutating func setItemSelected(_ item: MenuBarItem, _ selected: Bool) {
        switch item {
        case .card(let card): setSelected(card, selected)
        case .coreClock(let prefix): setCoreClockSelected(prefix, selected)
        case .memPressure: setMemPressureSelected(selected)
        case .batteryTemp: setBatteryTempSelected(selected)
        }
    }

    /// Canonical menubar order of selected items.
    var items: [MenuBarItem] {
        var list: [MenuBarItem] = []
        if isSelected(.cpu) { list.append(.card(.cpu)) }
        if isCoreClockSelected("S") { list.append(.coreClock(prefix: "S")) }
        if isCoreClockSelected("P") { list.append(.coreClock(prefix: "P")) }
        if isCoreClockSelected("E") { list.append(.coreClock(prefix: "E")) }
        if isSelected(.gpu) { list.append(.card(.gpu)) }
        if isSelected(.power) { list.append(.card(.power)) }
        if isSelected(.battery) { list.append(.card(.battery)) }
        if isBatteryTempSelected { list.append(.batteryTemp) }
        if isSelected(.mem) { list.append(.card(.mem)) }
        if isMemPressureSelected { list.append(.memPressure) }
        if isSelected(.cpuTemp) { list.append(.card(.cpuTemp)) }
        if isSelected(.gpuTemp) { list.append(.card(.gpuTemp)) }
        if isSelected(.fan) { list.append(.card(.fan)) }
        return list
    }

    /// Set of cards needed to feed the selected menubar items.
    var requiredCards: Set<CardKind> {
        Set(items.map(\.requiredCard))
    }

    func write(to defaults: UserDefaults = .standard) {
        for card in CardKind.allCases {
            defaults.set(isSelected(card), forKey: StorageKey.menu(card))
        }
        for prefix in ["S", "P", "E"] {
            defaults.set(isCoreClockSelected(prefix), forKey: StorageKey.menuCoreClock(prefix))
        }
        defaults.set(isBatteryTempSelected, forKey: StorageKey.menuBatteryTemp)
        defaults.set(isMemPressureSelected, forKey: StorageKey.menuMemPressure)
    }
}

/// Observable store that monitors UserDefaults for card visibility and menubar selection changes.
@Observable
@MainActor
final class VisibilitySettings: Sendable {
    static let shared = VisibilitySettings()

    var cardVisibility: CardVisibility
    var menuBarSelection: MenuBarSelection
    private let defaults: UserDefaults
    @ObservationIgnored private var observerTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.cardVisibility = CardVisibility(userDefaults: defaults)
        self.menuBarSelection = MenuBarSelection(userDefaults: defaults)

        self.observerTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification, object: defaults) {
                guard let self else { return }
                self.reload()
            }
        }
    }

    @MainActor
    private func reload() {
        let newVis = CardVisibility(userDefaults: defaults)
        let newMenu = MenuBarSelection(userDefaults: defaults)
        if cardVisibility != newVis {
            cardVisibility = newVis
        }
        if menuBarSelection != newMenu {
            menuBarSelection = newMenu
        }
    }

    func isShown(_ card: CardKind) -> Bool {
        cardVisibility.isShown(card)
    }

    var activeCards: Set<CardKind> {
        cardVisibility.activeCards
    }

    var menuItems: [MenuBarItem] {
        menuBarSelection.items
    }

    var requiredMenuCards: Set<CardKind> {
        menuBarSelection.requiredCards
    }

    deinit {
        observerTask?.cancel()
    }
}
