import Foundation
import IOKit

public final class SMCBatteryControlHardware: BatteryControlHardwareProtocol, @unchecked Sendable {
    private let smc: SMCControlConnection
    /// Captures the runtime probe independently of the policy register set. This is the proof for
    /// the sole readback-free release outcome: no known Wattly latch was reachable at probe time.
    private let runtimeDrivableRegisterProbe: BatteryControlRuntimeDrivableRegisterProbe
    public let registerSet: BatteryControlRegisterSet
    /// `registerSet`과 별개로 CHIE 키 자체를 프로브한 결과. 세대 표가 "지원"이라고 말하는
    /// 기계에도 이 키가 없을 수 있고, 그때 방전 요청은 조용히 아무 일도 하지 않는다.
    public let isDischargeSupported: Bool

    init(smc: SMCControlConnection) {
        self.smc = smc
        // Ask the hardware which generation it is instead of inferring it from the architecture.
        // Normal driving retains its runtime generation selection. The release-only probe records
        // whether every latch key was *explicitly* absent rather than treating unreadable as absent.
        let registerSet = BatteryControlKeys.registerSet { smc.keyInfo($0) }
        self.registerSet = registerSet
        isDischargeSupported = BatteryControlKeys.isDischargeSupported { smc.keyInfo($0) }
        runtimeDrivableRegisterProbe = BatteryControlKeys.runtimeDrivableRegisterProbe {
            smc.batteryKeyProbe($0)
        }
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

    public func setDischargingActive(_ active: Bool) -> Bool {
        let writes = BatteryControlKeys.dischargeWrites(active: active, registerSet: registerSet)
        guard !writes.isEmpty else { return false }

        var requiredWritesSucceeded = true
        for write in writes {
            let reply = smc.write(write.key, bytes: write.bytes)
            let succeeded = reply?.kernel == KERN_SUCCESS && reply?.smcResult == 0
            if !succeeded && write.isRequired { requiredWritesSucceeded = false }
        }
        return requiredWritesSucceeded
    }

    public func releaseChargingControlAndVerify() -> BatteryReleaseVerification {
        let releaseRegisterSet: BatteryControlRegisterSet
        switch runtimeDrivableRegisterProbe {
        case .drivable(let set):
            releaseRegisterSet = set
        case .noDrivableRegisterAtRuntime:
            // A normal runtime selection and a later all-absent safety probe disagree. Treat that
            // as an unreadable release, never as evidence that a potentially latched key vanished.
            guard !registerSet.canDriveCharging else { return .init(verdict: .failed) }
            return .init(
                verdict: .notControllable,
                proof: .noDrivableRegisterAtRuntime)
        case .unsafeToRelease:
            return .init(verdict: .failed)
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
