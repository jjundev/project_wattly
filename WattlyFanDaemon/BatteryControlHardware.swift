import Foundation
import IOKit

public final class SMCBatteryControlHardware: BatteryControlHardwareProtocol, @unchecked Sendable {
    private let smc: SMCControlConnection

    public var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    init(smc: SMCControlConnection) {
        self.smc = smc
    }

    public func setChargingInhibited(_ inhibited: Bool, targetLimit: Int) -> Bool {
        var requiredWritesSucceeded = true
        for write in BatteryControlKeys.writes(inhibited: inhibited,
                                               isAppleSilicon: isAppleSilicon,
                                               targetLimit: targetLimit) {
            let reply = smc.write(write.key, bytes: [write.byte])
            let succeeded = reply?.kernel == KERN_SUCCESS && reply?.smcResult == 0
            // An absent optional register reports a non-zero SMC result; that is expected on the
            // models that only implement one of the two, so it must not fail the transition.
            if !succeeded && write.isRequired { requiredWritesSucceeded = false }
        }
        return requiredWritesSucceeded
    }
}
