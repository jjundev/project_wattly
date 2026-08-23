import Foundation
import IOKit

public final class SMCBatteryControlHardware: BatteryControlHardwareProtocol, @unchecked Sendable {
    private let smc: SMCControlConnection
    public let registerSet: BatteryControlRegisterSet

    init(smc: SMCControlConnection) {
        self.smc = smc
        // Ask the hardware which generation it is instead of inferring it from the architecture.
        // A `keyInfo` probe is read-only and costs at most three calls, once per process — and a
        // key that does not answer here is a key that could only ever fail to be written.
        let registerSet = BatteryControlKeys.registerSet { smc.keyInfo($0) }
        self.registerSet = registerSet

        // `.firmwareManaged` normally means this init is read-only: probe and stop. There is one
        // deliberate exception. If this Mac's SMC firmware took over the charge limit *after* this
        // app had already written `CHTE == 1` (or `CH0B`) to hold it, that register is left latched
        // with nobody left to clear it — `BatteryControlEngine.normalizeOnFirstUpdate`'s whole reason
        // for existing is exactly that failure mode, and it never runs here because
        // `isHardwareSupported` is false for `.firmwareManaged`. So: if a drivable register is still
        // present underneath the firmware-managed keys, fire exactly one release write (`inhibited:
        // false`) right now, before standing down for good. The release direction is safe to send
        // unconditionally here because it only ever says "charging is allowed" — it cannot contend
        // with whatever the new firmware does with the charger, it can only un-latch something this
        // app itself may have set. `setChargingInhibited` below still refuses every future write for
        // `.firmwareManaged` (`writes(...)` returns `[]` for that case), so this happens once per
        // process and never again.
        if registerSet == .firmwareManaged {
            let drivable = BatteryControlKeys.drivableRegisterSet { smc.keyInfo($0) }
            if drivable != .unsupported {
                // The result is deliberately not kept. This daemon has no logging of any kind, so a
                // stored outcome would be a property nobody reads; and there is no retry to schedule
                // either — the engine is standing down on this Mac by design, so nothing downstream
                // could act on a failure. One attempt in the safe direction is the whole remedy.
                for write in BatteryControlKeys.writes(inhibited: false,
                                                       registerSet: drivable,
                                                       targetLimit: 100) {
                    _ = smc.write(write.key, bytes: write.bytes)
                }
            }
        }
    }

    public func setChargingInhibited(_ inhibited: Bool, targetLimit: Int) -> Bool {
        let writes = BatteryControlKeys.writes(inhibited: inhibited,
                                               registerSet: registerSet,
                                               targetLimit: targetLimit)
        // No register means no write can succeed. Report that rather than returning a vacuous
        // "all zero required writes succeeded" true.
        guard !writes.isEmpty else { return false }

        var requiredWritesSucceeded = true
        for write in writes {
            let reply = smc.write(write.key, bytes: write.bytes)
            let succeeded = reply?.kernel == KERN_SUCCESS && reply?.smcResult == 0
            // An absent optional register reports a non-zero SMC result; that is expected on the
            // models that only implement one of a pair, so it must not fail the transition.
            if !succeeded && write.isRequired { requiredWritesSucceeded = false }
        }
        return requiredWritesSucceeded
    }
}
