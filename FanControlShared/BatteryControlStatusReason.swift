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
    /// The limit in play, for the two kinds that name one. `nil` everywhere else.
    public var limitPercentage: Int?

    public init(kind: Kind, limitPercentage: Int? = nil) {
        self.kind = kind
        self.limitPercentage = limitPercentage
    }

    private enum CodingKeys: String, CodingKey {
        case kind, limitPercentage
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
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(limitPercentage, forKey: .limitPercentage)
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
        case .unrecognized: return ""
        }
    }
}
