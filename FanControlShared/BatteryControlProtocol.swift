import Foundation

public struct BatteryControlConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var limitPercentage: Int
    public var lowerHysteresisDelta: Int

    public init(enabled: Bool = false, limitPercentage: Int = 80, lowerHysteresisDelta: Int = 2) {
        self.enabled = enabled
        self.limitPercentage = limitPercentage
        self.lowerHysteresisDelta = lowerHysteresisDelta
    }

    /// Range-clamped copy. Configurations reach the root daemon through the synthesized
    /// `init(from:)`, which never runs the memberwise initializer — so clamping has to be an
    /// explicit step the daemon takes, not an initializer side effect.
    public var normalized: BatteryControlConfiguration {
        var copy = self
        copy.limitPercentage = Self.clampLimit(limitPercentage)
        copy.lowerHysteresisDelta = Self.clampDelta(lowerHysteresisDelta)
        return copy
    }

    public var clampedLimitPercentage: Int {
        Self.clampLimit(limitPercentage)
    }

    public var resumePercentage: Int {
        max(45, clampedLimitPercentage - Self.clampDelta(lowerHysteresisDelta))
    }

    private static func clampLimit(_ value: Int) -> Int { max(50, min(100, value)) }
    private static func clampDelta(_ value: Int) -> Int { max(1, min(10, value)) }
}

public struct BatteryControlConfigurationRequest: Codable, Equatable, Sendable {
    public var configuration: BatteryControlConfiguration
    public var generation: UInt64

    public init(configuration: BatteryControlConfiguration, generation: UInt64) {
        self.configuration = configuration
        self.generation = generation
    }
}

public enum BatteryControlServiceMode: String, Codable, Equatable, Sendable {
    case unavailable
    case charging
    case inhibited
    case unsupported
}

public struct BatteryControlServiceStatus: Codable, Equatable, Sendable {
    public var mode: BatteryControlServiceMode
    public var currentPercentage: Int
    public var isPowerAdapterConnected: Bool
    public var detail: String
    public var updatedAt: TimeInterval
    /// The limit the helper is enforcing right now, or `nil` when it is enforcing nothing — because
    /// the limit is off, because a write did not land, or because this Mac has no charge register.
    /// The app compares this against its own opt-in to notice a helper that restarted and came back
    /// with an empty configuration. Optional so a payload from an older installed helper still
    /// decodes.
    public var appliedLimitPercentage: Int?
    /// Whether this Mac exposes a charge-control register at all. `nil` from a helper too old to
    /// report it — "unknown", not "unsupported". `false` means the limit can never work here, which
    /// is a different thing from a write that failed: the settings screen disables its toggle
    /// instead of showing a state that looks like it is still retrying.
    public var isHardwareSupported: Bool?
    /// The structured form of `detail`. `nil` from a helper too old to send one — which is the
    /// common case right after an app update, since nothing replaces an installed helper that still
    /// answers. The app falls back to parsing `detail` in that case.
    ///
    /// `detail` is kept rather than replaced so the reverse pairing also works: a current helper
    /// talking to an older app still fills the sentence that app knows how to read.
    public var detailReason: BatteryControlStatusReason?
    /// The product policy the helper has actually verified. Optional for an older installed helper;
    /// `nil` means unknown, not inactive. `detailReason` remains the diagnostic/text channel.
    public var activity: BatteryControlActivity?

    public init(
        mode: BatteryControlServiceMode,
        currentPercentage: Int,
        isPowerAdapterConnected: Bool,
        detail: String,
        updatedAt: TimeInterval,
        appliedLimitPercentage: Int? = nil,
        isHardwareSupported: Bool? = nil,
        detailReason: BatteryControlStatusReason? = nil,
        activity: BatteryControlActivity? = nil
    ) {
        self.mode = mode
        self.currentPercentage = currentPercentage
        self.isPowerAdapterConnected = isPowerAdapterConnected
        self.detail = detail
        self.updatedAt = updatedAt
        self.appliedLimitPercentage = appliedLimitPercentage
        self.isHardwareSupported = isHardwareSupported
        self.detailReason = detailReason
        self.activity = activity
    }
}

public enum BatteryControlCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }
}
