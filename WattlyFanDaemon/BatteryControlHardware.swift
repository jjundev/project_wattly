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
        if isAppleSilicon {
            // Apple Silicon: CH0B = 0x02 (disable charging/inhibit), 0x00 (enable charging)
            let val: UInt8 = inhibited ? 0x02 : 0x00
            guard let reply = smc.write("CH0B", bytes: [val]),
                  reply.kernel == KERN_SUCCESS, reply.smcResult == 0 else {
                return false
            }
            return true
        } else {
            // Intel Mac: BCLM = target percentage (e.g. 85) when inhibited, 100 when normal
            let limitByte = UInt8(clamping: inhibited ? targetLimit : 100)
            guard let reply = smc.write("BCLM", bytes: [limitByte]),
                  reply.kernel == KERN_SUCCESS, reply.smcResult == 0 else {
                return false
            }
            return true
        }
    }
}
