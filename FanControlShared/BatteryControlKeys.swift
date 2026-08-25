import Foundation

/// Which generation of charge-control registers a Mac exposes.
///
/// **Within Apple silicon the axis is firmware, not the model.** This was originally written as a
/// model-generation split — "M1–M3 use `CH0B`, newer Macs use `CHTE`" — and that is wrong about the
/// cause. Apple moves the register in *firmware* updates, so a machine that never changed loses the
/// key its owner has been using for years: the Tahoe-era SMC firmware (`138xx`/`18xxx`) took
/// `CH0B` away, and it reached some Macs on **macOS 15.7**, before Tahoe shipped at all. Intel
/// versus Apple silicon is a separate and genuine *hardware* split — that is what `intel` below is.
///
/// The causal evidence is the downgrade behaviour rather than any version table: rolling the OS
/// back does not bring `CH0B` back, and only a DFU restore to older firmware does
/// (`charlie0129/batt#34`, `lslqtz/bclm_loop#5`, where the same Mac is reported working on Sonoma
/// firmware `10151.140.19`, broken after 15.7 firmware `13822.12` with `keyNotFound(code: "CH0B")`,
/// and restored by a DFU reinstall). `charlie0129/batt` writes the same bytes this table writes for
/// `CH0B`/`CH0C` and `CHTE`, indexes its user-facing compatibility matrix by firmware version
/// ("Do NOT rely on macOS version"), and — like this table — selects at runtime from key *presence*
/// rather than reading any version at all.
///
/// The practical consequence is that nothing here may be inferred — not from `#if arch(arm64)`, not
/// from a model table, and not from the macOS version either (an old macOS install can carry new
/// firmware, and a new one can carry old). The generation is probed, every time, from the hardware.
/// Inferring it is exactly the defect that made the limit fail silently on an M5.
public enum BatteryControlRegisterSet: String, Codable, Equatable, Sendable {
    /// macOS 26 (Tahoe) era firmware: a single `CHTE` `ui32` gate. Measured on an M5, firmware
    /// `18000.161.10`.
    case modern
    /// Pre-Tahoe firmware: the `CH0B` / `CH0C` charger-control pair.
    case legacy
    /// Intel: `BCLM` stores the ceiling percentage itself.
    case intel
    /// macOS 27 era firmware (`20xxx`), which manages the limit itself through `bfF0`/`bfD0`/`bfE0`
    /// and behaves differently enough that the engine's model does not fit: the firmware may run the
    /// Mac off the battery above the limit, so the percentage falls rather than holding, and it
    /// keeps enforcing while the daemon sleeps.
    ///
    /// Detected only so the app can *stay out of the way* until macOS 27 ships and this can be
    /// implemented against a released OS. Treated as unsupported everywhere — the point of naming it
    /// is that such a Mac may still expose `CHTE`, and driving that key underneath a firmware that
    /// owns the limit is worse than doing nothing.
    ///
    /// "Stays out of the way" is not unconditional, though: if the Mac also exposes a drivable
    /// register (`drivableRegisterSet(probing:)` below), the hardware adapter preserves that hidden
    /// register for its explicit verified-release path. That path exists for the Mac that took a
    /// firmware update while `CHTE == 1` — the release direction only ever says "charging is
    /// allowed", so it cannot contend with whatever the firmware now does with the charger; it only
    /// clears a latch this app itself may have set under the old firmware. Ordinary engine control
    /// still stands down: `canDriveCharging` is `false` and `writes(...)` returns `[]`.
    case firmwareManaged
    /// None of the above are present. The charge limit cannot work on this Mac at all.
    case unsupported

    /// Whether the engine may write registers on this Mac. Two of the five cases mean "hands off",
    /// for different reasons, and every caller cares about the answer rather than the reason.
    public var canDriveCharging: Bool {
        switch self {
        case .modern, .legacy, .intel: return true
        case .firmwareManaged, .unsupported: return false
        }
    }

    /// Whether this register set supports hardware discharge control (CHIE).
    /// Modern and legacy Apple silicon firmware support CHIE; Intel and firmwareManaged do not.
    public var isDischargeSupported: Bool {
        switch self {
        case .modern, .legacy: return true
        case .intel, .firmwareManaged, .unsupported: return false
        }
    }
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

/// The result of probing one potential charge-control latch key. `keyInfo` used to collapse all
/// non-values into `nil`, which made a transport failure indistinguishable from a proven missing
/// key. That distinction is safety-critical for the one release outcome that performs no write.
public enum BatteryControlKeyProbeResult: Equatable, Sendable {
    /// The SMC explicitly reported that this named key does not exist.
    case confirmedAbsent
    /// The SMC returned a readable key-info record. The caller must still validate its shape.
    case readable(type: String, size: Int)
    /// Transport/SMC failure or an invalid reply shape; absence is not proved.
    case uncertain

    /// Classifies an AppleSMC cmd-9 key-info reply without collapsing an error into absence.
    /// The M5 used for this helper reports 132 when a named key is absent; other nonzero
    /// results remain uncertain so verified release cannot ignore a reachable latch.
    public static func fromSMCKeyInfo(
        kernelSucceeded: Bool,
        smcResult: UInt8,
        type: String,
        size: Int
    ) -> Self {
        guard kernelSucceeded else { return .uncertain }
        if smcResult == 132 { return .confirmedAbsent }
        guard smcResult == 0, (1...32).contains(size) else { return .uncertain }
        return .readable(type: type, size: size)
    }
}

/// The runtime answer used only by the dedicated safety-release path.
public enum BatteryControlRuntimeDrivableRegisterProbe: Equatable, Sendable {
    /// A register with a safe release payload was identified.
    case drivable(BatteryControlRegisterSet)
    /// Every known latch key explicitly reported absence, so no release write is possible.
    case noDrivableRegisterAtRuntime
    /// A key could not be proved absent or had a reachable but unfamiliar shape.
    case unsafeToRelease
}

/// Picks the SMC registers for a charge-limit transition. This lives in `FanControlShared` rather
/// than beside the hardware because the `WattlyFanDaemon` target has no test host — keeping the
/// register table here is what makes it verifiable at all.
public enum BatteryControlKeys {
    /// The macOS 27 era keys that decide the question. The full set is `bfF0` (activation), `bfD0`
    /// (upper) and `bfE0` (lower); `bfD0` is deliberately **not** consulted, because it is present
    /// on Tahoe firmware all by itself as a 2-byte *read-only* key — re-verified on this M5,
    /// `18000.161.10`, where it cannot be the writable `ui32` upper limit a macOS 27 daemon
    /// programs. Letting it vote would disable the feature on machines that work today.
    ///
    /// The remaining two are required together rather than either alone: one lone key of an
    /// unfamiliar name is exactly how `bfD0` fooled the first version of this check.
    ///
    /// `charlie0129/batt` demands all three before it will *drive* the firmware limit, and its
    /// compatibility matrix shows that working on real macOS 27 betas. This check is deliberately
    /// looser because it is asked a different question: batt needs every register it is about to
    /// write, while all this needs is enough evidence to *stand down*. A Mac we wrongly stand down
    /// on merely loses a feature; a macOS 27 Mac we fail to recognise gets `CHTE` driven out from
    /// under the firmware that owns the charger.
    public static let firmwareManagedKeys = ["bfF0", "bfE0"]

    /// Probed in this order at daemon startup; the first key whose `keyInfo` answers **with the
    /// expected payload size** decides the generation. `firmwareManagedKeys` is checked ahead of
    /// all of them — see `registerSet(probing:)`. That precedence is the one ordering anybody has
    /// justified in writing: `charlie0129/batt` puts the firmware-managed keys ahead of everything
    /// else because an old macOS install can receive newer firmware.
    ///
    /// The order *among these three*, though, is a preference — and one that **diverges from every
    /// upstream tool**. batt and the widely copied community scripts prefer the `CH0B`/`CH0C` pair
    /// whenever it is present and fall back to `CHTE` only when `CH0B` is absent; this table asks
    /// for `CHTE` first. No machine exposing both has ever been reported, so the two orders have
    /// never disagreed in practice, and only one machine has been measured here at all (an M5 on
    /// Tahoe firmware: `CHTE`, no `CH0B`). If a Mac with both ever turns up, upstream's order is
    /// the better-supported one and this should follow it. `expectedSize` is what a wrong guess
    /// would most likely trip over in the meantime.
    public static let probeOrder: [(registerSet: BatteryControlRegisterSet, key: String, expectedSize: Int)] = [
        (.modern, "CHTE", 4),
        (.legacy, "CH0B", 1),
        (.intel, "BCLM", 1)
    ]

    /// Chooses the generation from whatever the hardware answers. Takes the probe as a closure so
    /// the daemon's `SMCControlConnection` stays out of `FanControlShared` and the selection — the
    /// riskiest new decision in this change — is unit-testable.
    ///
    /// This is the "should the engine drive this Mac" answer, and it stays firmware-managed-aware:
    /// once `firmwareManagedKeys` are both present, this returns `.firmwareManaged` regardless of
    /// what `drivableRegisterSet` would have said, because *driving* the charger is off the table on
    /// such a Mac. Callers that need the other question — "which register, if any, could this Mac be
    /// driven through, ignoring whether the firmware currently owns it" — want
    /// `drivableRegisterSet(probing:)` instead; that is what makes the verified safety-release path
    /// possible on a `.firmwareManaged` Mac that also exposes `CHTE` or `CH0B`.
    public static func registerSet(probing keyInfo: (String) -> (type: String, size: Int)?) -> BatteryControlRegisterSet {
        // Firmware-managed first, with no *additional* size check here, and over a deliberately small
        // key set. That is safe because absence is already detectable without one: the caller's
        // `keyInfo` (`WattlyFanDaemon/SMCControlConnection.swift`) rejects any reply whose `dataSize`
        // falls outside `1...32`, so a key that does not exist on this Mac arrives here as `nil`
        // regardless. Both choices lean the same way: being liberal here can only ever switch the
        // feature *off*, while being strict — rejecting the set over a payload width or a third key
        // nobody has read off a macOS 27 machine — falls through to `CHTE` and drives a register out
        // from under the firmware that owns it. The cautious direction is the permissive one.
        if firmwareManagedKeys.allSatisfy({ keyInfo($0) != nil }) { return .firmwareManaged }

        return drivableRegisterSet(probing: keyInfo)
    }

    /// Answers "which register could this Mac be driven through", ignoring `firmwareManagedKeys`
    /// entirely — deliberately, because that stays the right answer even on a Mac the app has
    /// decided not to drive. `registerSet(probing:)` is the policy question ("should the engine
    /// drive this Mac"); this is the mechanical one underneath it, kept separate so a
    /// `.firmwareManaged` verdict does not erase the fact that a drivable register also exists.
    /// `SMCBatteryControlHardware.init` calls this a second time, only when `registerSet` came back
    /// `.firmwareManaged`, to preserve the register an explicit safety release may need to un-latch.
    ///
    /// A key that answers with an unexpected size is treated as absent rather than trusted: writing
    /// a 4-byte payload at a 1-byte register is how a "supported" Mac would fail every write with no
    /// way to tell that apart from broken hardware.
    ///
    /// Size is checked and `type` deliberately is not, unlike the fan probes next door. Only one of
    /// these registers has ever been observed — `CHTE` reports `ui32` on an M5 — so a type check on
    /// the other two would be asserting a string nobody has read off real hardware, and rejecting a
    /// working register is worse than accepting an odd type at the right width. Size is what makes
    /// the raw byte-array write well-formed, which is the property that actually matters here.
    public static func drivableRegisterSet(probing keyInfo: (String) -> (type: String, size: Int)?) -> BatteryControlRegisterSet {
        for candidate in probeOrder {
            guard let info = keyInfo(candidate.key), info.size == candidate.expectedSize else { continue }
            return candidate.registerSet
        }
        return .unsupported
    }

    /// The fail-closed counterpart to `drivableRegisterSet(probing:)`. It may return the
    /// no-register proof only when *every* possible charge latch explicitly reported absence.
    /// A transport failure and a key at an unexpected size/type are both unsafe, because either
    /// could be a still-latched register we have failed to understand.
    public static func runtimeDrivableRegisterProbe(
        probing keyInfo: (String) -> BatteryControlKeyProbeResult
    ) -> BatteryControlRuntimeDrivableRegisterProbe {
        var allConfirmedAbsent = true
        var drivableRegisterSet: BatteryControlRegisterSet?
        var hasUnsafeCandidate = false

        for candidate in probeOrder {
            switch keyInfo(candidate.key) {
            case .confirmedAbsent:
                continue
            case .readable(let type, let size):
                allConfirmedAbsent = false
                if isSafeReleaseShape(type: type, size: size, for: candidate) {
                    drivableRegisterSet = drivableRegisterSet ?? candidate.registerSet
                } else {
                    hasUnsafeCandidate = true
                }
            case .uncertain:
                allConfirmedAbsent = false
                hasUnsafeCandidate = true
            }
        }

        if hasUnsafeCandidate { return .unsafeToRelease }
        if let drivableRegisterSet { return .drivable(drivableRegisterSet) }
        return allConfirmedAbsent ? .noDrivableRegisterAtRuntime : .unsafeToRelease
    }

    /// Normal feature selection preserves the permissive historical rule (width selects the
    /// generation). The release proof is narrower: an unexpected type is not evidence that a
    /// key is absent and must not permit a readback-free release.
    private static func isSafeReleaseShape(
        type: String,
        size: Int,
        for candidate: (registerSet: BatteryControlRegisterSet, key: String, expectedSize: Int)
    ) -> Bool {
        guard size == candidate.expectedSize else { return false }
        switch candidate.registerSet {
        case .modern:
            return type == "ui32"
        case .legacy, .intel:
            return ["ui8", "ui8 ", "hex_"].contains(type)
        case .firmwareManaged, .unsupported:
            return false
        }
    }

    /// Parses a raw SMC reply into the shared gate state without inferring success from zero-filled
    /// storage. The binary generations report only allowed/inhibited, while Intel reports the
    /// applied ceiling itself so the engine can compare it with the desired limit.
    public static func readGate(
        registerSet: BatteryControlRegisterSet,
        read: (String) -> (type: String, bytes: [UInt8])?
    ) -> BatteryHardwareGate {
        switch registerSet {
        case .modern:
            guard let raw = read("CHTE"), raw.bytes.count == 4 else {
                return .unreadable
            }
            if raw.bytes == [0, 0, 0, 0] { return .allowed }
            if raw.bytes == [1, 0, 0, 0] {
                return .inhibited(appliedLimitPercentage: nil)
            }
            return .unreadable
        case .legacy:
            guard let byte = read("CH0B")?.bytes.first else {
                return .unreadable
            }
            switch byte {
            case 0: return .allowed
            case 2: return .inhibited(appliedLimitPercentage: nil)
            default: return .unreadable
            }
        case .intel:
            guard let byte = read("BCLM")?.bytes.first else {
                return .unreadable
            }
            if byte == 100 { return .allowed }
            guard (50...99).contains(Int(byte)) else { return .unreadable }
            return .inhibited(appliedLimitPercentage: Int(byte))
        case .firmwareManaged, .unsupported:
            return .unreadable
        }
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
            // Pre-Tahoe firmware inhibits through the charger-control registers. Both are written
            // because every upstream tool writes both — `charlie0129/batt` in fact requires both to
            // be present before it will use this path at all. Which one the hardware actually
            // honours has not been established here, so only `CH0B` decides success.
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
        case .firmwareManaged, .unsupported:
            // Nothing to write — the Mac has no register, or has one this build refuses to touch.
            // Returning an empty list rather than a doomed write keeps "hands off this Mac" a fact
            // of the table instead of a special case at every call site.
            return []
        }
    }

    /// Probes whether the hardware exposes the CHIE discharge register with the expected 1-byte payload.
    public static func isDischargeSupported(probing keyInfo: (String) -> (type: String, size: Int)?) -> Bool {
        guard let info = keyInfo("CHIE"), info.size == 1 else { return false }
        return true
    }

    /// Generates the SMC writes needed to control manual/automatic discharge via CHIE.
    /// CHIE is a 1-byte register (`hex_`): 0x08 activates discharging from AC power, 0x00 restores idle/normal.
    public static func dischargeWrites(
        active: Bool,
        registerSet: BatteryControlRegisterSet
    ) -> [BatteryControlKeyWrite] {
        guard registerSet.isDischargeSupported else { return [] }
        let byte: UInt8 = active ? 0x08 : 0x00
        return [
            BatteryControlKeyWrite(key: "CHIE", bytes: [byte], isRequired: true)
        ]
    }
}
