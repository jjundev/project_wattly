import Foundation

/// The seven cards the popover can show, in the prototype's default order
/// (`cardOrder`, prototype line 413).
enum CardKind: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case power, battery, cpu, mem, cpuTemp, gpuTemp, batTemp

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
        }
    }

    // MARK: Structural facts (state-independent) — the card's layout shape.
    // The single home for the card-family booleans the views previously hardcoded
    // (they were copy-pasted across MetricCardView / PopoverContentView). The card's
    // *content* (label, value, unit) lives in `CardPresentation`; these are pure shape.

    /// Cards with an expand region + chevron (CPU per-core, memory Top-3, CPU-temp
    /// clusters). Drives both the chevron and whether a tap toggles expansion.
    var isExpandable: Bool { self == .cpu || self == .mem || self == .cpuTemp }

    /// The battery card draws a polyline only; every other card fills the sparkline
    /// area beneath the line (prototype line 100).
    var hasSparkArea: Bool { self != .battery }

    /// The processor-power card is the single accented (brand-blue) card; every other
    /// card uses the neutral theme tokens.
    var isAccented: Bool { self == .power }
}

/// The five providers that cross the actor boundary (PRD line 73). Distinct from
/// `CardKind` because the temperature provider yields three cards.
enum ProviderKind: String, CaseIterable, Sendable, Hashable {
    case cpu, memory, power, battery, temperature
}
