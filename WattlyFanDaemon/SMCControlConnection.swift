import Foundation
import IOKit

/// Raw AppleSMC control client compiled exclusively into the root helper. The similarly named
/// application `SMCConnection` deliberately has no write or key-info API.
final class SMCControlConnection: @unchecked Sendable {
    private typealias Bytes32 = (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                                 UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                                 UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                                 UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8)
    private struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
    private struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    private struct KeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0; var p0: UInt8 = 0, p1: UInt8 = 0, p2: UInt8 = 0 }
    private struct Param {
        var key: UInt32 = 0
        var vers = Vers()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes32 = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }

    private static let cmdRead: UInt8 = 5
    private static let cmdWrite: UInt8 = 6
    private static let cmdKeyInfo: UInt8 = 9
    private static let kernelIndex: UInt32 = 2

    private let connection: io_connect_t

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS, conn != 0 else { return nil }
        connection = conn
    }

    deinit { IOServiceClose(connection) }

    func keyInfo(_ key: String) -> (type: String, size: Int)? {
        var probe = Param(); probe.key = Self.fourCC(key); probe.data8 = Self.cmdKeyInfo
        let reply = callStruct(&probe)
        guard reply.kernel == KERN_SUCCESS else { return nil }
        let size = Int(reply.output.keyInfo.dataSize)
        guard (1...32).contains(size) else { return nil }
        return (Self.string(reply.output.keyInfo.dataType), size)
    }

    func read(_ key: String) -> (type: String, bytes: [UInt8])? {
        let k = Self.fourCC(key)
        var probe = Param(); probe.key = k; probe.data8 = Self.cmdKeyInfo
        let infoReply = callStruct(&probe)
        guard infoReply.kernel == KERN_SUCCESS else { return nil }
        let info = infoReply.output
        let size = Int(info.keyInfo.dataSize)
        guard (1...32).contains(size) else { return nil }
        var request = Param(); request.key = k; request.keyInfo = info.keyInfo; request.data8 = Self.cmdRead
        let readReply = callStruct(&request)
        guard readReply.kernel == KERN_SUCCESS else { return nil }
        var tuple = readReply.output.bytes
        let bytes = withUnsafeBytes(of: &tuple) { Array($0.prefix(size)) }
        return (Self.string(info.keyInfo.dataType), bytes)
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

    private func callStruct(_ input: inout Param) -> (kernel: kern_return_t, output: Param) {
        var output = Param()
        var outSize = MemoryLayout<Param>.stride
        let kernel = IOConnectCallStructMethod(connection, Self.kernelIndex, &input,
                                               MemoryLayout<Param>.stride, &output, &outSize)
        return (kernel, output)
    }

    private static func fourCC(_ string: String) -> UInt32 {
        var result: UInt32 = 0
        for byte in string.utf8.prefix(4) { result = (result << 8) | UInt32(byte) }
        return result
    }

    private static func string(_ value: UInt32) -> String {
        String(bytes: [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
                       UInt8((value >> 8) & 0xff), UInt8(value & 0xff)], encoding: .ascii) ?? ""
    }
}
