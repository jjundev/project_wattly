import Foundation
import IOKit

/// 데몬 전용 쓰기 확장. 마샬링·읽기·keyInfo 캐시는 앱과 공유하는 `SMCConnection`(Wattly/Core/SMC.swift)에 있고,
/// 이 파일은 데몬 타깃에만 컴파일되므로 앱 바이너리에는 `write`가 존재하지 않는다.
typealias SMCControlConnection = SMCConnection

extension SMCConnection {
    private static let cmdWrite: UInt8 = 6

    func keyInfo(_ key: String) -> (type: String, size: Int)? {
        guard case let .readable(type, size) = batteryKeyProbe(key) else { return nil }
        return (type, size)
    }

    func batteryKeyProbe(_ key: String) -> BatteryControlKeyProbeResult {
        let reply = probeKeyInfo(key)
        return .fromSMCKeyInfo(
            kernelSucceeded: reply.kernel == KERN_SUCCESS,
            smcResult: reply.output.result,
            type: Self.string(reply.output.keyInfo.dataType),
            size: Int(reply.output.keyInfo.dataSize))
    }

    /// Returns both the IOKit return code and the SMC result byte for a validated 1...32-byte write.
    func write(_ key: String, bytes: [UInt8]) -> (kernel: kern_return_t, smcResult: UInt8)? {
        guard (1...32).contains(bytes.count) else { return nil }
        var request = Param()
        request.key = Self.fourCC(key)
        request.keyInfo.dataSize = UInt32(bytes.count)
        request.data8 = Self.cmdWrite
        withUnsafeMutableBytes(of: &request.bytes) { destination in
            destination.copyBytes(from: bytes)
        }
        let reply = callStruct(&request)
        return (reply.kernel, reply.output.result)
    }
}

