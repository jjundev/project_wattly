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
        self.registerSet = BatteryControlKeys.probeOrder
            .first { smc.keyInfo($0.key) != nil }?
            .registerSet ?? .unsupported
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
