import Foundation
import IOKit

public final class SMCBatteryControlHardware: BatteryControlHardwareProtocol, @unchecked Sendable {
    private let smc: SMCControlConnection
    /// Captures the runtime probe independently of the policy register set. This is the proof for
    /// the sole readback-free release outcome: no known Wattly latch was reachable at probe time.
    private let runtimeDrivableRegisterSet: BatteryControlRegisterSet
    public let registerSet: BatteryControlRegisterSet

    init(smc: SMCControlConnection) {
        self.smc = smc
        // Ask the hardware which generation it is instead of inferring it from the architecture.
        // A `keyInfo` probe is read-only and costs at most three calls, once per process — and a
        // key that does not answer here is a key that could only ever fail to be written.
        let registerSet = BatteryControlKeys.registerSet { smc.keyInfo($0) }
        self.registerSet = registerSet
        runtimeDrivableRegisterSet = BatteryControlKeys.drivableRegisterSet { smc.keyInfo($0) }
    }

    public func readChargingGate(targetLimit: Int) -> BatteryHardwareGate {
        BatteryControlKeys.readGate(registerSet: registerSet) { [smc] key in
            smc.read(key)
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

    public func releaseChargingControlAndVerify() -> BatteryReleaseVerification {
        let releaseRegisterSet: BatteryControlRegisterSet
        switch registerSet {
        case .modern, .legacy, .intel:
            releaseRegisterSet = registerSet
        case .firmwareManaged, .unsupported:
            releaseRegisterSet = runtimeDrivableRegisterSet
        }
        guard releaseRegisterSet.canDriveCharging else {
            // `runtimeDrivableRegisterSet` was just obtained by probing every key in
            // `BatteryControlKeys.probeOrder`; do not claim this for a policy-only verdict.
            return .init(
                verdict: .notControllable,
                proof: .noDrivableRegisterAtRuntime)
        }

        let writes = BatteryControlKeys.writes(
            inhibited: false,
            registerSet: releaseRegisterSet,
            targetLimit: 100)
        for write in writes {
            let reply = smc.write(write.key, bytes: write.bytes)
            let succeeded = reply?.kernel == KERN_SUCCESS
                && reply?.smcResult == 0
            if write.isRequired && !succeeded { return .init(verdict: .failed) }
        }

        let gate = BatteryControlKeys.readGate(
            registerSet: releaseRegisterSet,
            read: { [smc] key in smc.read(key) })
        return .init(verdict: gate.state == .allowed ? .verifiedAllowed : .failed)
    }
}
