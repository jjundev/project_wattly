import Foundation

/// A CPU-temperature → target-RPM fan curve. The temperature anchors are fixed; only the
/// four target RPMs are user-editable. `evaluate` is piecewise-linear between anchors.
struct FanCurve: Equatable, Sendable, RawRepresentable {
    /// The fixed temperature anchors (°C), ascending — the same for every curve. 40…100 in 5°
    /// steps (13 anchors): a fine-grained curve the graph editor exposes as draggable points.
    static let anchorsCelsius: [Double] = Array(stride(from: 40.0, through: 100.0, by: 5.0))

    /// Target RPM at each anchor, parallel to `anchorsCelsius`.
    var rpms: [Double]

    init(rpms: [Double]) { self.rpms = rpms }

    /// Target RPM for an input temperature: flat outside the curve, linearly interpolated
    /// inside it. Returns `0` for a malformed in-memory curve.
    func evaluate(inputCelsius c: Double) -> Double {
        let anchors = Self.anchorsCelsius
        guard rpms.count == anchors.count, let first = anchors.first, let last = anchors.last
        else { return 0 }
        if c <= first { return rpms[0] }
        if c >= last { return rpms[rpms.count - 1] }
        for i in 0..<(anchors.count - 1) where c >= anchors[i] && c < anchors[i + 1] {
            let t = (c - anchors[i]) / (anchors[i + 1] - anchors[i])
            return rpms[i] + t * (rpms[i + 1] - rpms[i])
        }
        return rpms[rpms.count - 1]
    }

    static func == (lhs: FanCurve, rhs: FanCurve) -> Bool { lhs.rpms == rhs.rpms }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        let values = raw.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard values.count == Self.anchorsCelsius.count,
              values.allSatisfy({ (0.0...20000.0).contains($0) }) else { return nil }
        self.init(rpms: values)
    }

    var rawValue: String {
        guard let data = try? JSONSerialization.data(withJSONObject: rpms),
              let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }
}

extension FanCurve: Codable {
    init(from decoder: Decoder) throws {
        let values = try decoder.singleValueContainer().decode([Double].self)
        let data = try JSONSerialization.data(withJSONObject: values)
        guard let raw = String(data: data, encoding: .utf8),
              let curve = FanCurve(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                   debugDescription: "invalid fan curve")
        }
        self = curve
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rpms)
    }
}
