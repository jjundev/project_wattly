import Foundation

struct FanLimits: Equatable, Sendable {
    var minimum: Double
    var maximum: Double
}

enum FanControlPolicy {
    static let criticalCelsius = 95.0
    static let heartbeatTimeout = 15.0
    static let heartbeatCheckInterval = 5.0
    static let controlInterval = 1.0
    static let modeRetryDeadline = 10.0
    static let modeRetryDelay = 0.5

    static func targetRPM(curve: FanCurve, hottestCPU: Double, limits: FanLimits) -> Double {
        guard hottestCPU.isFinite, limits.minimum.isFinite, limits.maximum.isFinite,
              limits.minimum > 0, limits.maximum >= limits.minimum else { return 0 }
        if hottestCPU >= criticalCelsius { return limits.maximum }
        return min(max(curve.evaluate(inputCelsius: hottestCPU), limits.minimum), limits.maximum)
    }

    static func heartbeatExpired(last: TimeInterval, now: TimeInterval) -> Bool {
        now - last >= heartbeatTimeout
    }
}
