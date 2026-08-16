import Foundation

/// The eight cards the popover can show, in the default order.
enum CardKind: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case power, battery, cpu, gpu, mem, cpuTemp, gpuTemp, fan

    var id: String { rawValue }

    /// Which provider feeds this card.
    var provider: ProviderKind {
        switch self {
        case .power: .power
        case .battery: .battery
        case .cpu: .cpu
        case .gpu: .gpu
        case .mem: .memory
        case .cpuTemp, .gpuTemp: .temperature
        case .fan: .fan
        }
    }

    // MARK: Structural facts (state-independent) — the card's layout shape.

    /// All 8 cards have an expand region + chevron.
    var isExpandable: Bool { true }

    /// The battery card draws a polyline only; every other card fills the sparkline
    /// area beneath the line.
    var hasSparkArea: Bool { self != .battery }

    /// The processor-power card is the single accented (brand-blue) card.
    var isAccented: Bool { self == .power }

    /// The processor-power and battery cards apply display smoothing.
    var isSmoothable: Bool { self == .power || self == .battery }
}

/// The seven providers that cross the actor boundary.
enum ProviderKind: String, CaseIterable, Sendable, Hashable {
    case cpu, gpu, memory, power, battery, temperature, fan
}
