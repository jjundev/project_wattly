import Foundation

/// Why the charge limit is in the state it is in — as a code rather than a sentence.
///
/// The status line is produced by `WattlyFanDaemon`, which runs as root outside any user session.
/// It has no `.lproj` resources and no idea what language the user reads, so prose built there can
/// only ever be Korean. Shipping the *reason* instead lets the app render it in the user's own
/// language, and keeps the two interpolated states (which could never match a catalog key) working
/// like every other string.
///
/// This type lives in `FanControlShared`, which compiles into both the app and the daemon, so it
/// must not touch any localization API — in the daemon every lookup silently returns its own key.
public struct BatteryControlStatusReason: Codable, Equatable, Sendable {

    public enum Kind: String, Codable, Equatable, Sendable, CaseIterable {
        /// The daemon has started but has not evaluated a power reading yet.
        case initializing
        /// IOKit would not hand over a power source snapshot, and there is no cached one.
        case powerSourceUnreadable
        /// The engine will not drive this Mac: it exposes no charge-control register at all
        /// (`BatteryControlRegisterSet.unsupported`), or its firmware owns the limit itself and this
        /// build stays out of the way (`.firmwareManaged`). One sentence covers both because the
        /// user-visible consequence is identical — the limit is off and no setting changes that.
        case hardwareUnsupported
        /// Charging is inhibited and the write that would release it keeps failing — the Mac is
        /// stuck not charging. The most user-actionable state there is.
        case releaseFailed
        /// The user asked for the limit and the register write will not land.
        case applyFailed
        /// Working as intended, sitting at the limit on adapter bypass. Carries `limitPercentage`.
        case inhibitedAtLimit
        /// The user has the feature switched off.
        case limitDisabled
        /// Plugged in and charging up toward the limit. Carries `limitPercentage`.
        case chargingToTarget
        /// Unplugged.
        case onBatteryPower
        /// In natural discharge band between charge limit and lower hysteresis threshold. Carries `limitPercentage` and `resumePercentage`.
        case sailing
        case heatProtectionActive
        case heatProtectionCooldown
        case topUpCharging
        case topUpComplete
        case topUpHeldAtMax
        case dischargingToTarget
        case dischargingManual
        case batterySensorUnreadable
        case persistenceReadFailed
        case persistenceWriteFailed
        case policyOwnerMismatch
        case hardwareReadbackFailed
        /// A token this build does not know — a newer daemon talking to an older app. Never
        /// produced locally; only ever decoded. The app falls back to the `detail` sentence.
        case unrecognized

        /// Decoding is lenient on purpose. The default synthesized initializer throws on an
        /// unknown raw value, which would fail the decode of the *entire* `BatteryControlServiceStatus`
        /// — taking the battery percentage, the mode, and the hardware-support flag down with one
        /// unfamiliar status word.
        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unrecognized
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public var kind: Kind
    /// The limit in play, for the kinds that name one. `nil` everywhere else.
    public var limitPercentage: Int?
    /// The lower hysteresis threshold at which charging will resume. `nil` everywhere except `.sailing`.
    public var resumePercentage: Int?
    public var currentTemperatureCelsius: Double?
    public var thresholdTemperatureCelsius: Int?
    public var resumeTemperatureCelsius: Int?
    public var cooldownRemainingSeconds: Int?

    public init(
        kind: Kind,
        limitPercentage: Int? = nil,
        resumePercentage: Int? = nil,
        currentTemperatureCelsius: Double? = nil,
        thresholdTemperatureCelsius: Int? = nil,
        resumeTemperatureCelsius: Int? = nil,
        cooldownRemainingSeconds: Int? = nil
    ) {
        self.kind = kind
        self.limitPercentage = limitPercentage
        self.resumePercentage = resumePercentage
        self.currentTemperatureCelsius = currentTemperatureCelsius
        self.thresholdTemperatureCelsius = thresholdTemperatureCelsius
        self.resumeTemperatureCelsius = resumeTemperatureCelsius
        self.cooldownRemainingSeconds = cooldownRemainingSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case kind, limitPercentage, resumePercentage
        case currentTemperatureCelsius, thresholdTemperatureCelsius, resumeTemperatureCelsius, cooldownRemainingSeconds
    }

    /// Decoding is lenient here for the same reason `Kind`'s own decode is lenient one level down:
    /// this struct is decoded out of `BatteryControlServiceStatus.detailReason`
    /// (`decodeIfPresent`), and under the synthesized initializer a single malformed field — a
    /// `kind` that isn't even a string, or a `limitPercentage` sent as the wrong JSON type — throws
    /// and takes the *entire* status decode down with it, not just this optional field. Each field
    /// falls back to its safe default instead of propagating the error.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .unrecognized
        limitPercentage = try? container.decodeIfPresent(Int.self, forKey: .limitPercentage)
        resumePercentage = try? container.decodeIfPresent(Int.self, forKey: .resumePercentage)
        currentTemperatureCelsius = try? container.decodeIfPresent(Double.self, forKey: .currentTemperatureCelsius)
        thresholdTemperatureCelsius = try? container.decodeIfPresent(Int.self, forKey: .thresholdTemperatureCelsius)
        resumeTemperatureCelsius = try? container.decodeIfPresent(Int.self, forKey: .resumeTemperatureCelsius)
        cooldownRemainingSeconds = try? container.decodeIfPresent(Int.self, forKey: .cooldownRemainingSeconds)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(limitPercentage, forKey: .limitPercentage)
        try container.encodeIfPresent(resumePercentage, forKey: .resumePercentage)
        try container.encodeIfPresent(currentTemperatureCelsius, forKey: .currentTemperatureCelsius)
        try container.encodeIfPresent(thresholdTemperatureCelsius, forKey: .thresholdTemperatureCelsius)
        try container.encodeIfPresent(resumeTemperatureCelsius, forKey: .resumeTemperatureCelsius)
        try container.encodeIfPresent(cooldownRemainingSeconds, forKey: .cooldownRemainingSeconds)
    }

    /// The Korean sentence this reason used to be, for an app too old to understand `kind`.
    ///
    /// A current daemon keeps filling `BatteryControlServiceStatus.detail` with this so that a
    /// downgraded or not-yet-updated app still shows something true. It is deliberately NOT the
    /// same table as the app's `LegacyBatteryDetail`: this one describes what *this* build emits
    /// and may be reworded freely, while that one describes binaries already installed on disk and
    /// must never change. Merging them means a copy edit silently breaks recognition of every
    /// helper already out there.
    public var legacyKoreanDetail: String {
        // 100 is the no-op ceiling the engine uses when it has no configured target, so a reason
        // that arrives without a limit degrades to "no limit" rather than to a crash.
        let target = limitPercentage ?? 100
        let resume = resumePercentage ?? max(45, target - 2)
        switch kind {
        case .initializing: return "초기화 중"
        case .powerSourceUnreadable: return "전원 소스를 읽을 수 없습니다"
        case .hardwareUnsupported: return "이 Mac은 충전 제어를 지원하지 않습니다"
        case .releaseFailed: return "충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)"
        case .applyFailed: return "이 Mac에서 충전 제어를 적용하지 못했습니다"
        case .inhibitedAtLimit: return "충전 제한 \(target)% 도달 (전원 어댑터 바이패스 구동)"
        case .limitDisabled: return "충전 제한 비활성화됨"
        case .chargingToTarget: return "목표치(\(target)%)까지 충전 중"
        case .onBatteryPower: return "배터리 전원으로 구동 중"
        case .sailing: return "Sailing 중 (\(resume)% 도달 시 충전)"
        case .heatProtectionActive:
            let tempStr = currentTemperatureCelsius.map { String(format: "%.1f", $0) } ?? "?"
            let resume = resumeTemperatureCelsius ?? 33
            return "발열 보호 중 (배터리 \(tempStr)°C / \(resume)°C 이하 시 재개)"
        case .heatProtectionCooldown:
            let remaining = cooldownRemainingSeconds ?? 0
            return "발열 보호 쿨다운 중 (\(remaining)초 후 충전 재개)"
        case .topUpCharging: return "한 번만 완충 중 (100%까지 충전)"
        case .topUpComplete: return "한 번만 완충 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)"
        case .topUpHeldAtMax: return "한 번만 완충 유지 중 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)"
        case .dischargingToTarget: return "목표치(\(target)%)까지 방전 중"
        case .dischargingManual: return "수동 방전 중 (\(target)%까지 방전)"
        case .batterySensorUnreadable:
            return "배터리 온도 센서를 읽을 수 없습니다"
        case .persistenceReadFailed: return "저장된 충전 정책을 읽지 못해 충전 허용 상태로 복구합니다"
        case .persistenceWriteFailed: return "충전 정책을 안전하게 저장하지 못했습니다"
        case .policyOwnerMismatch: return "다른 사용자가 이 Mac의 충전 정책을 관리하고 있습니다"
        case .hardwareReadbackFailed: return "충전 제어 하드웨어 상태를 확인하지 못했습니다"
        case .unrecognized: return ""
        }
    }
}
