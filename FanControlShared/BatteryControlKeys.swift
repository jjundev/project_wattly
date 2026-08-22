import Foundation

/// One SMC register write that a charge-limit transition needs.
public struct BatteryControlKeyWrite: Equatable, Sendable {
    public let key: String
    public let byte: UInt8
    /// `false` for a register only some models expose. A failed optional write must not fail the
    /// transition, or the engine would report `.unsupported` on hardware that actually works.
    public let isRequired: Bool

    public init(key: String, byte: UInt8, isRequired: Bool) {
        self.key = key
        self.byte = byte
        self.isRequired = isRequired
    }
}

/// Picks the SMC registers for a charge-limit transition. This lives in `FanControlShared` rather
/// than beside the hardware because the `WattlyFanDaemon` target has no test host — keeping the
/// register table here is what makes it verifiable at all.
public enum BatteryControlKeys {
    public static func writes(inhibited: Bool,
                              isAppleSilicon: Bool,
                              targetLimit: Int) -> [BatteryControlKeyWrite] {
        if isAppleSilicon {
            // Apple Silicon inhibits charging through the charger-control registers. Models differ
            // in which one they honour, so both are written; only CH0B decides success.
            let byte: UInt8 = inhibited ? 0x02 : 0x00
            return [
                BatteryControlKeyWrite(key: "CH0B", byte: byte, isRequired: true),
                BatteryControlKeyWrite(key: "CH0C", byte: byte, isRequired: false)
            ]
        }
        // Intel stores the ceiling itself: the target percentage while limiting, 100 when off.
        return [BatteryControlKeyWrite(key: "BCLM",
                                       byte: UInt8(clamping: inhibited ? targetLimit : 100),
                                       isRequired: true)]
    }
}
