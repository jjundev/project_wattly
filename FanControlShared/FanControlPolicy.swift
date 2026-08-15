import Foundation

struct FanLimits: Equatable, Sendable {
    var minimum: Double
    var maximum: Double
}

enum FanControlPolicy {
    /// The editable curve includes its 100°C endpoint. Preserve that endpoint's target, then
    /// force maximum cooling only once the CPU exceeds the graph's supported temperature range.
    static let maximumOverrideCelsius = 100.0
    static let zeroRPMEnterCelsius = 48.0
    static let zeroRPMExitCelsius = 55.0
    static let heartbeatTimeout = 15.0
    static let heartbeatCheckInterval = 5.0
    static let controlInterval = 1.0
    static let modeRetryDeadline = 10.0
    static let modeRetryDelay = 0.5

    static func targetRPM(curve: FanCurve,
                          hottestCPU: Double,
                          limits: FanLimits,
                          wasZeroRPM: Bool) -> Double? {
        guard hottestCPU.isFinite,
              limits.minimum.isFinite,
              limits.maximum.isFinite,
              limits.minimum > 0,
              limits.maximum >= limits.minimum else { return nil }
        if hottestCPU > maximumOverrideCelsius { return limits.maximum }

        guard curve.rpms.count == FanCurve.anchorsCelsius.count else { return nil }

        let curveTarget = curve.evaluate(inputCelsius: hottestCPU)
        guard curveTarget.isFinite else { return nil }
        if curveTarget == 0 {
            let boundary = wasZeroRPM ? zeroRPMExitCelsius : zeroRPMEnterCelsius
            if hottestCPU < boundary { return 0 }
        }
        return min(max(curveTarget, limits.minimum), limits.maximum)
    }

    static func heartbeatExpired(last: TimeInterval, now: TimeInterval) -> Bool {
        now - last >= heartbeatTimeout
    }

    /// A menu-bar open should repair a lost Wattly session only when the user still opted in
    /// and the helper confirms that every fan is back in macOS automatic mode. Other states are
    /// either already progressing, already controlling, or unsafe to override blindly.
    static func shouldReapplyAfterMenuBarOpen(enabled: Bool,
                                               mode: FanControlServiceMode) -> Bool {
        enabled && mode == .automatic
    }
}
