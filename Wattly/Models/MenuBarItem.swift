import Foundation

enum MenuBarItem: Sendable, Hashable, Identifiable {
    case card(CardKind)
    case coreClock(prefix: String)
    case memPressure
    case batteryTemp

    var id: String {
        switch self {
        case .card(let kind): return "card.\(kind.rawValue)"
        case .coreClock(let p): return "clock.\(p)"
        case .memPressure: return "memPressure"
        case .batteryTemp: return "batteryTemp"
        }
    }
    
    var requiredCard: CardKind {
        switch self {
        case .card(let kind): return kind
        case .coreClock: return .cpu
        case .memPressure: return .mem
        case .batteryTemp: return .battery
        }
    }
}
