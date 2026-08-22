import Foundation

/// Which generation of charge-control registers a Mac exposes.
///
/// Apple changed the register set on Apple Silicon around 2023: the `CH0B`/`CH0C` pair that M1–M3
/// machines honour simply does not exist on newer models, where a single `CHTE` flag took over.
/// Inferring the answer from `#if arch(arm64)` is what made the limit fail silently on an M5 — the
/// daemon wrote a key that was not there and had no way to tell that apart from a rejected write.
public enum BatteryControlRegisterSet: String, Codable, Equatable, Sendable {
    /// Apple Silicon, roughly 2023 and newer (macOS Sequoia / Tahoe): a single `CHTE` `ui32`.
    case modern
    /// Apple Silicon M1–M3: the `CH0B` / `CH0C` charger-control pair.
    case legacy
    /// Intel: `BCLM` stores the ceiling percentage itself.
    case intel
    /// None of the above are present. The charge limit cannot work on this Mac at all.
    case unsupported
}

/// One SMC register write that a charge-limit transition needs.
public struct BatteryControlKeyWrite: Equatable, Sendable {
    public let key: String
    /// The payload, sized for the key: `CHTE` is a 4-byte `ui32`, the others are one byte.
    public let bytes: [UInt8]
    /// `false` for a register only some models expose. A failed optional write must not fail the
    /// transition, or the engine would report a failure on hardware that actually works.
    public let isRequired: Bool

    public init(key: String, bytes: [UInt8], isRequired: Bool) {
        self.key = key
        self.bytes = bytes
        self.isRequired = isRequired
    }
}

/// Picks the SMC registers for a charge-limit transition. This lives in `FanControlShared` rather
/// than beside the hardware because the `WattlyFanDaemon` target has no test host — keeping the
/// register table here is what makes it verifiable at all.
public enum BatteryControlKeys {
    /// Probed in this order at daemon startup; the first key that answers a `keyInfo` call decides
    /// the generation. Newest first, so a Mac exposing more than one set gets the current one.
    public static let probeOrder: [(registerSet: BatteryControlRegisterSet, key: String)] = [
        (.modern, "CHTE"),
        (.legacy, "CH0B"),
        (.intel, "BCLM")
    ]

    public static func writes(inhibited: Bool,
                              registerSet: BatteryControlRegisterSet,
                              targetLimit: Int) -> [BatteryControlKeyWrite] {
        switch registerSet {
        case .modern:
            // `CHTE` is a 4-byte gate flag: 1 stops charging, 0 allows it. Measured on an M5 — the
            // battery current falls from ~2500 mA to 0 mA within ~3 s while the charger keeps
            // powering the system, which is the adapter pass-through this feature is for.
            return [BatteryControlKeyWrite(key: "CHTE",
                                           bytes: [inhibited ? 0x01 : 0x00, 0x00, 0x00, 0x00],
                                           isRequired: true)]
        case .legacy:
            // M1–M3 inhibit through the charger-control registers. Models differ in which one they
            // honour, so both are written; only `CH0B` decides success.
            let byte: UInt8 = inhibited ? 0x02 : 0x00
            return [
                BatteryControlKeyWrite(key: "CH0B", bytes: [byte], isRequired: true),
                BatteryControlKeyWrite(key: "CH0C", bytes: [byte], isRequired: false)
            ]
        case .intel:
            // Intel stores the ceiling itself: the target percentage while limiting, 100 when off.
            return [BatteryControlKeyWrite(key: "BCLM",
                                           bytes: [UInt8(clamping: inhibited ? targetLimit : 100)],
                                           isRequired: true)]
        case .unsupported:
            // Nothing to write. Returning an empty list rather than a doomed write keeps "this Mac
            // cannot do it" a fact of the table instead of a special case at every call site.
            return []
        }
    }
}
