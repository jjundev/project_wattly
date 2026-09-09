import Foundation

public enum BatteryHoldSleepPolicy {
    public static let duration: TimeInterval = 4 * 60 * 60
    public static var durationHours: Int { Int(duration / 3600) }

    public enum Decision: Equatable, Sendable {
        case none
        case engage
        case restamp(TimeInterval)
        case disengage
        case expire
    }

    public static func decide(
        allowed: Bool,
        isPluggedIn: Bool,
        limitEnabled: Bool,
        currentSoC: Int,
        targetLimit: Int,
        isCharging: Bool,
        isInHeatProtection: Bool,
        inhibitedAt: TimeInterval?,
        expiredForCurrentSession: Bool,
        now: TimeInterval,
        duration: TimeInterval = BatteryHoldSleepPolicy.duration
    ) -> Decision {
        let shouldHold = allowed
            && isPluggedIn
            && limitEnabled
            && currentSoC < targetLimit
            && isCharging
            && !isInHeatProtection

        guard let inhibitedAt else {
            guard shouldHold, !expiredForCurrentSession else { return .none }
            return .engage
        }

        guard shouldHold else { return .disengage }
        guard now >= inhibitedAt else { return .restamp(now) }
        return now - inhibitedAt >= duration ? .expire : .none
    }
}
