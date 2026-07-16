import Foundation

/// The seven cards the popover can show, in the prototype's default order
/// (`cardOrder`, prototype line 413).
enum CardKind: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case power, battery, cpu, mem, cpuTemp, gpuTemp, batTemp, fan

    var id: String { rawValue }

    /// Which provider feeds this card. The three temperature cards share one
    /// provider — a single snapshot fans out to all three (L4 / PRD line 74).
    var provider: ProviderKind {
        switch self {
        case .power: .power
        case .battery: .battery
        case .cpu: .cpu
        case .mem: .memory
        case .cpuTemp, .gpuTemp, .batTemp: .temperature
        case .fan: .fan
        }
    }

    // MARK: Structural facts (state-independent) — the card's layout shape.
    // The single home for the card-family booleans the views previously hardcoded
    // (they were copy-pasted across MetricCardView / PopoverContentView). The card's
    // *content* (label, value, unit) lives in `CardPresentation`; these are pure shape.

    /// Cards with an expand region + chevron (processor-power per-app Top-3, battery
    /// voltage/current, CPU per-core, memory Top-3, CPU-temp clusters). Drives both the
    /// chevron and whether a tap toggles.
    var isExpandable: Bool {
        self == .power || self == .battery || self == .cpu || self == .mem || self == .cpuTemp || self == .fan
    }

    /// The battery card draws a polyline only; every other card fills the sparkline
    /// area beneath the line (prototype line 100).
    var hasSparkArea: Bool { self != .battery }

    /// The processor-power card is the single accented (brand-blue) card; every other
    /// card uses the neutral theme tokens.
    var isAccented: Bool { self == .power }

    /// The processor-power and battery cards apply display smoothing (the shared
    /// `powerSmoothed` toggle); every other card shows its raw series. The single home
    /// for "which cards smooth", consumed by `SystemMonitor`'s state/history routing.
    var isSmoothable: Bool { self == .power || self == .battery }
}

/// The five providers that cross the actor boundary (PRD line 73). Distinct from
/// `CardKind` because the temperature provider yields three cards.
enum ProviderKind: String, CaseIterable, Sendable, Hashable {
    case cpu, memory, power, battery, temperature, fan
}
