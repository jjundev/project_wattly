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
    /// Probed in this order at daemon startup; the first key whose `keyInfo` answers **with the
    /// expected payload size** decides the generation.
    ///
    /// Newest first. That preference is not a measured requirement: the only machine anyone has
    /// probed (an M5) exposes `CHTE` and not `CH0B`, so the order has never been exercised on a Mac
    /// that offers both, and it is unknown whether such a Mac exists. Revisit with data if one turns
    /// up — `expectedSize` below is what a wrong guess would most likely trip over.
    public static let probeOrder: [(registerSet: BatteryControlRegisterSet, key: String, expectedSize: Int)] = [
        (.modern, "CHTE", 4),
        (.legacy, "CH0B", 1),
        (.intel, "BCLM", 1)
    ]

    /// Chooses the generation from whatever the hardware answers. Takes the probe as a closure so
    /// the daemon's `SMCControlConnection` stays out of `FanControlShared` and the selection — the
    /// riskiest new decision in this change — is unit-testable.
    ///
    /// A key that answers with an unexpected size is treated as absent rather than trusted: writing
    /// a 4-byte payload at a 1-byte register is how a "supported" Mac would fail every write with no
    /// way to tell that apart from broken hardware.
    public static func registerSet(probing keyInfo: (String) -> (type: String, size: Int)?) -> BatteryControlRegisterSet {
        for candidate in probeOrder {
            guard let info = keyInfo(candidate.key), info.size == candidate.expectedSize else { continue }
            return candidate.registerSet
        }
        return .unsupported
    }

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
