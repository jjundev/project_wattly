import Foundation

/// The user-facing battery policy the helper has actually verified.
///
/// This is deliberately separate from `BatteryControlServiceMode`: service mode describes whether
/// the helper is reachable and whether the charge gate is physically open or closed; activity says
/// which product policy owns that state. Future policy engines choose one authoritative activity.
public enum BatteryControlActivity: String, Codable, Equatable, Sendable, CaseIterable {
    case inactive
    case chargingToLimit
    case holdingAtLimit
    case onBatteryPower
    case sailing
    case heatProtection
    case topUp
    case discharging
    case calibration

    /// A newer helper sent an activity token this app does not know. Never emitted locally.
    case unrecognized

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = Self(rawValue: raw) ?? .unrecognized
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Compatibility path for an older helper that has `detailReason` but no activity field.
    /// Only reasons that prove a normal base activity are inferred; diagnostics stay `nil`.
    public static func inferred(from reason: BatteryControlStatusReason?) -> Self? {
        switch reason?.kind {
        case .some(.limitDisabled): return .inactive
        case .some(.chargingToTarget): return .chargingToLimit
        case .some(.inhibitedAtLimit): return .holdingAtLimit
        case .some(.onBatteryPower): return .onBatteryPower
        case .some(.sailing): return .sailing
        case .some(.heatProtectionActive), .some(.heatProtectionCooldown):
            return .heatProtection
        case .some(.initializing), .some(.powerSourceUnreadable),
             .some(.hardwareUnsupported), .some(.releaseFailed),
             .some(.applyFailed), .some(.batterySensorUnreadable),
             .some(.persistenceReadFailed),
             .some(.persistenceWriteFailed), .some(.policyOwnerMismatch),
             .some(.hardwareReadbackFailed), .some(.unrecognized), .none:
            return nil
        }
    }

    /// Prefer the helper's explicit verified activity. Unknown future tokens fall back to the
    /// reason understood by this app, preserving useful status after an incremental update.
    public static func resolved(explicit: Self?, reason: BatteryControlStatusReason?) -> Self? {
        if let explicit, explicit != .unrecognized { return explicit }
        return inferred(from: reason)
    }
}
