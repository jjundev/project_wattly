import Foundation

/// Community-tested presets for CPU temperature → target fan RPM curves.
/// Mapped across the 15 temperature anchors (30°C to 100°C in 5°C steps).
enum FanCurvePreset: String, CaseIterable, Sendable, Identifiable {
    case balanced = "균형"
    case silent = "저소음"
    case performance = "성능"
    case fullSpeed = "최대"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced: return "균형 (기본값)"
        case .silent: return "저소음"
        case .performance: return "성능"
        case .fullSpeed: return "최대"
        }
    }

    var curve: FanCurve {
        switch self {
        case .balanced:
            return FanCurve(rpms: [800, 900, 1000, 1200, 1500, 1900, 2400, 3000, 3600, 4200, 4800, 5500, 6200, 6800, 7400])
        case .silent:
            // 30°C..50°C at 0 RPM (5 anchors), then ramp up to allow 48..50°C zero-RPM hold range
            return FanCurve(rpms: [0, 0, 0, 0, 0, 1000, 1500, 2000, 2600, 3400, 4400, 5600, 6600, 7200, 7400])
        case .performance:
            return FanCurve(rpms: [1500, 1800, 2200, 2800, 3500, 4200, 4800, 5400, 6000, 6500, 7000, 7400, 7400, 7400, 7400])
        case .fullSpeed:
            return FanCurve(rpms: Array(repeating: 7400.0, count: FanCurve.anchorsCelsius.count))
        }
    }

    static func matchingPreset(for curve: FanCurve) -> FanCurvePreset? {
        allCases.first { $0.curve == curve }
    }
}
