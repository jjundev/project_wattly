import Foundation

/// Community-tested presets for CPU temperature → target fan RPM curves.
/// Mapped across the 15 temperature anchors (30°C to 100°C in 5°C steps).
enum FanCurvePreset: String, CaseIterable, Sendable, Identifiable {
    case silent = "저소음"
    case balanced = "균형"
    case performance = "성능"
    case fullSpeed = "최대"

    static let defaultMaxRPM: Double = 6500

    var id: String { rawValue }

    var title: String {
        switch self {
        case .silent: return "저소음"
        case .balanced: return "균형 (기본값)"
        case .performance: return "성능"
        case .fullSpeed: return "최대"
        }
    }

    var curve: FanCurve {
        curve(forMaxRPM: Self.defaultMaxRPM)
    }

    func curve(forMaxRPM maxRPM: Double) -> FanCurve {
        let maxTarget = max(maxRPM, 1000)
        let round100: (Double) -> Double = { ($0 / 100.0).rounded() * 100.0 }

        switch self {
        case .silent:
            // 30°C..55°C (6 anchors) = 0 RPM, then ramp up to maxTarget
            let tailRatios: [Double] = [0.18, 0.27, 0.38, 0.52, 0.67, 0.85, 0.94, 0.98, 1.00]
            let rpms = Array(repeating: 0.0, count: 6) + tailRatios.map { round100($0 * maxTarget) }
            return FanCurve(rpms: rpms)
        case .balanced:
            let ratios: [Double] = [0.12, 0.14, 0.16, 0.19, 0.23, 0.29, 0.37, 0.46, 0.55, 0.65, 0.74, 0.84, 0.92, 0.97, 1.00]
            return FanCurve(rpms: ratios.map { round100($0 * maxTarget) })
        case .performance:
            let ratios: [Double] = [0.23, 0.28, 0.34, 0.43, 0.54, 0.65, 0.74, 0.83, 0.92, 0.97, 1.00, 1.00, 1.00, 1.00, 1.00]
            return FanCurve(rpms: ratios.map { round100($0 * maxTarget) })
        case .fullSpeed:
            return FanCurve(rpms: Array(repeating: round100(maxTarget), count: FanCurve.anchorsCelsius.count))
        }
    }

    static func matchingPreset(for curve: FanCurve, maxRPM: Double = defaultMaxRPM) -> FanCurvePreset? {
        allCases.first { $0.curve(forMaxRPM: maxRPM) == curve }
    }
}
