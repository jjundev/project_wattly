import Foundation

public struct BatteryControlConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var limitPercentage: Int
    public var lowerHysteresisDelta: Int
    public var heatProtectionEnabled: Bool
    public var heatProtectionThresholdCelsius: Int
    public var heatProtectionResumeDeltaCelsius: Int
    public var heatProtectionMinCooldownSeconds: TimeInterval
    public var topUpActive: Bool

    public init(
        enabled: Bool = false,
        limitPercentage: Int = 80,
        lowerHysteresisDelta: Int = 2,
        heatProtectionEnabled: Bool = false,
        heatProtectionThresholdCelsius: Int = 35,
        heatProtectionResumeDeltaCelsius: Int = 2,
        heatProtectionMinCooldownSeconds: TimeInterval = 300.0,
        topUpActive: Bool = false
    ) {
        self.enabled = enabled
        self.limitPercentage = limitPercentage
        self.lowerHysteresisDelta = lowerHysteresisDelta
        self.heatProtectionEnabled = heatProtectionEnabled
        self.heatProtectionThresholdCelsius = heatProtectionThresholdCelsius
        self.heatProtectionResumeDeltaCelsius = heatProtectionResumeDeltaCelsius
        self.heatProtectionMinCooldownSeconds = heatProtectionMinCooldownSeconds
        self.topUpActive = topUpActive
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, limitPercentage, lowerHysteresisDelta
        case heatProtectionEnabled, heatProtectionThresholdCelsius, heatProtectionResumeDeltaCelsius, heatProtectionMinCooldownSeconds
        case topUpActive
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? false
        limitPercentage = (try? container.decode(Int.self, forKey: .limitPercentage)) ?? 80
        lowerHysteresisDelta = (try? container.decode(Int.self, forKey: .lowerHysteresisDelta)) ?? 2
        heatProtectionEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .heatProtectionEnabled)) ?? false
        heatProtectionThresholdCelsius = (try? container.decodeIfPresent(Int.self, forKey: .heatProtectionThresholdCelsius)) ?? 35
        heatProtectionResumeDeltaCelsius = (try? container.decodeIfPresent(Int.self, forKey: .heatProtectionResumeDeltaCelsius)) ?? 2
        heatProtectionMinCooldownSeconds = (try? container.decodeIfPresent(TimeInterval.self, forKey: .heatProtectionMinCooldownSeconds)) ?? 300.0
        topUpActive = (try? container.decodeIfPresent(Bool.self, forKey: .topUpActive)) ?? false
    }

    /// Range-clamped copy. Configurations reach the root daemon through the synthesized
    /// `init(from:)`, which never runs the memberwise initializer — so clamping has to be an
    /// explicit step the daemon takes, not an initializer side effect.
    public var normalized: BatteryControlConfiguration {
        var copy = self
        copy.limitPercentage = Self.clampLimit(limitPercentage)
        copy.lowerHysteresisDelta = Self.clampDelta(lowerHysteresisDelta)
        copy.heatProtectionThresholdCelsius = Self.clampThreshold(heatProtectionThresholdCelsius)
        copy.heatProtectionResumeDeltaCelsius = Self.clampResumeDelta(heatProtectionResumeDeltaCelsius)
        copy.heatProtectionMinCooldownSeconds = Self.clampCooldown(heatProtectionMinCooldownSeconds)
        copy.topUpActive = topUpActive
        return copy
    }

    public var isActive: Bool {
        enabled || heatProtectionEnabled || topUpActive
    }

    public var clampedLimitPercentage: Int { Self.clampLimit(limitPercentage) }
    public var clampedHeatProtectionThresholdCelsius: Int { Self.clampThreshold(heatProtectionThresholdCelsius) }
    public var clampedHeatProtectionResumeDeltaCelsius: Int { Self.clampResumeDelta(heatProtectionResumeDeltaCelsius) }
    public var clampedHeatProtectionMinCooldownSeconds: TimeInterval { Self.clampCooldown(heatProtectionMinCooldownSeconds) }

    public var resumePercentage: Int {
        max(45, clampedLimitPercentage - Self.clampDelta(lowerHysteresisDelta))
    }

    public var resumeTemperatureCelsius: Int {
        max(20, clampedHeatProtectionThresholdCelsius - clampedHeatProtectionResumeDeltaCelsius)
    }

    private static func clampLimit(_ value: Int) -> Int { max(50, min(100, value)) }
    private static func clampDelta(_ value: Int) -> Int { max(1, min(10, value)) }
    private static func clampThreshold(_ value: Int) -> Int { max(30, min(45, value)) }
    private static func clampResumeDelta(_ value: Int) -> Int { max(1, min(5, value)) }
    private static func clampCooldown(_ value: TimeInterval) -> TimeInterval { max(60, min(1800, value)) }
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

public enum BatteryControlCapability: String, Codable, Equatable, Sendable {
    case persistedPolicyV1 = "persisted-policy-v1"
    case hardwareGateReadbackV1 = "hardware-gate-readback-v1"
    case systemPowerEventsV1 = "system-power-events-v1"
    case unrecognized

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unrecognized
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct BatteryHardwareGate: Codable, Equatable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
        case allowed
        case inhibited
        case unreadable
        case unrecognized

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: raw) ?? .unrecognized
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public var state: State
    public var appliedLimitPercentage: Int?

    public static let allowed = Self(state: .allowed, appliedLimitPercentage: nil)
    public static let unreadable = Self(state: .unreadable, appliedLimitPercentage: nil)

    public static func inhibited(appliedLimitPercentage: Int?) -> Self {
        Self(state: .inhibited, appliedLimitPercentage: appliedLimitPercentage)
    }
}

public enum BatteryMaintenanceTrigger: String, Codable, Equatable, Sendable {
    case startup
    case wake
    case clientConfiguration
    case adapterTransition
    case termination
    case unrecognized

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unrecognized
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum BatteryMaintenanceResult: String, Codable, Equatable, Sendable {
    case verified
    case applied
    case released
    case failed
    case skipped
    case unrecognized

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unrecognized
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum BatteryReleaseVerdict: String, Codable, Equatable, Sendable {
    case verifiedAllowed
    case notControllable
    case failed
    case unrecognized

    public var isSafeToRemove: Bool {
        // A bare `.notControllable` came from older helpers and has no evidence that the runtime
        // actually probed every Wattly-controllable latch. It must never authorize removal by
        // itself; current helpers attach `BatteryReleaseVerification.proof` below.
        self == .verifiedAllowed
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unrecognized
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The evidence carried with a release verdict. A write/readback is the normal success path; the
/// only readback-free success is a completed runtime probe that found no register Wattly can drive.
public enum BatteryReleaseProof: String, Codable, Equatable, Sendable {
    case noDrivableRegisterAtRuntime = "no-drivable-register-at-runtime"
    case unrecognized

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unrecognized
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A release result that cannot accidentally turn an unsupported verdict into a generic success.
/// `notControllable` is safe only with the narrow, explicit runtime-probe proof.
public struct BatteryReleaseVerification: Codable, Equatable, Sendable {
    public var verdict: BatteryReleaseVerdict
    public var proof: BatteryReleaseProof?

    public init(verdict: BatteryReleaseVerdict, proof: BatteryReleaseProof? = nil) {
        self.verdict = verdict
        self.proof = proof
    }

    public var isSafeToRemove: Bool {
        verdict == .verifiedAllowed
            || (verdict == .notControllable && proof == .noDrivableRegisterAtRuntime)
    }
}

public struct BatteryMaintenanceRecord: Codable, Equatable, Sendable {
    public var trigger: BatteryMaintenanceTrigger
    public var result: BatteryMaintenanceResult
    public var occurredAt: TimeInterval
    public var reason: BatteryControlStatusReason?

    public init(
        trigger: BatteryMaintenanceTrigger,
        result: BatteryMaintenanceResult,
        occurredAt: TimeInterval,
        reason: BatteryControlStatusReason?
    ) {
        self.trigger = trigger
        self.result = result
        self.occurredAt = occurredAt
        self.reason = reason
    }
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
    public var desiredConfiguration: BatteryControlConfiguration?
    public var actualGate: BatteryHardwareGate?
    public var releaseVerdict: BatteryReleaseVerdict?
    /// The evidence for a release verdict from a current helper. `nil` is intentionally unsafe for
    /// `notControllable`, preserving fail-safe behavior when paired with an older helper.
    public var releaseVerification: BatteryReleaseVerification?
    public var lastMaintenance: BatteryMaintenanceRecord?
    public var capabilities: [BatteryControlCapability]?
    public var batteryTemperatureCelsius: Double?

    public init(
        mode: BatteryControlServiceMode,
        currentPercentage: Int,
        isPowerAdapterConnected: Bool,
        detail: String,
        updatedAt: TimeInterval,
        appliedLimitPercentage: Int? = nil,
        isHardwareSupported: Bool? = nil,
        detailReason: BatteryControlStatusReason? = nil,
        activity: BatteryControlActivity? = nil,
        desiredConfiguration: BatteryControlConfiguration? = nil,
        actualGate: BatteryHardwareGate? = nil,
        releaseVerdict: BatteryReleaseVerdict? = nil,
        releaseVerification: BatteryReleaseVerification? = nil,
        lastMaintenance: BatteryMaintenanceRecord? = nil,
        capabilities: [BatteryControlCapability]? = nil,
        batteryTemperatureCelsius: Double? = nil
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
        self.desiredConfiguration = desiredConfiguration
        self.actualGate = actualGate
        self.releaseVerdict = releaseVerdict
        self.releaseVerification = releaseVerification
        self.lastMaintenance = lastMaintenance
        self.capabilities = capabilities
        self.batteryTemperatureCelsius = batteryTemperatureCelsius
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
