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
}

/// The five providers that cross the actor boundary (PRD line 73). Distinct from
/// `CardKind` because the temperature provider yields three cards.
enum ProviderKind: String, CaseIterable, Sendable, Hashable {
    case cpu, memory, power, battery, temperature
}
