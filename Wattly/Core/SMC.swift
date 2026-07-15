import Foundation
import IOKit

/// Minimal read-only `AppleSMC` client (issue 07; reusable for issue 08 temperature).
/// SMC exposes LIVE (~1 s) power sensors the AppleSmartBattery gauge doesn't — `B0AP`
/// (battery power mW, signed), `B0AV`/`B0AC` (battery mV/mA), `PSTR`/`PDTR`/`PPBR`
/// (system/adapter/battery W). Verified on Mac17,2 (2026-06-21): every field updates each
/// poll, vs AppleSmartBattery's ~10–20 s plateaus.
///
/// Holds the `io_connect_t` for the process lifetime, only ever touched inside an `actor`,
/// so `@unchecked Sendable` (same basis as `IOReportEnergySubscription`). Reads only — no
/// writes, no entitlements. Byte decoding lives in pure `smcDouble` (tested).
final class SMCConnection: @unchecked Sendable {
    // 80-byte AppleSMC parameter struct. `keyInfo` is padded to a full 12 bytes so Swift
    // doesn't pack `result`/`status`/`data8` into its tail padding (which yields 76 and the
    // kernel rejects with kIOReturnBadArgument); `IOByteCount dataSize` is the 32-bit form.
    private typealias Bytes32 = (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                                 UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                                 UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                                 UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8)
    private struct Vers { var major: UInt8=0, minor: UInt8=0, build: UInt8=0, reserved: UInt8=0; var release: UInt16=0 }
    private struct PLimit { var version: UInt16=0, length: UInt16=0; var cpu: UInt32=0, gpu: UInt32=0, mem: UInt32=0 }
    private struct KeyInfo { var dataSize: UInt32=0; var dataType: UInt32=0; var dataAttributes: UInt8=0; var p0: UInt8=0, p1: UInt8=0, p2: UInt8=0 }
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
    private static let cmdKeyInfo: UInt8 = 9
    private static let kernelIndex: UInt32 = 2

    private let connection: io_connect_t

    /// nil if `AppleSMC` is unavailable (graceful degrade — the caller then falls back).
    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS, conn != 0 else { return nil }
        connection = conn
    }
    deinit { IOServiceClose(connection) }

    private func callStruct(_ input: inout Param) -> (kernel: kern_return_t, output: Param) {
        var output = Param()
        var outSize = MemoryLayout<Param>.stride
        let kr = IOConnectCallStructMethod(connection, Self.kernelIndex, &input,
                                           MemoryLayout<Param>.stride, &output, &outSize)
        return (kr, output)
    }

    /// One 4-char SMC key as its FourCC type label + raw value bytes, or nil if the key is
    /// absent / unreadable (e.g. battery keys on a desktop). Decoding is left to `smcDouble`.
    func read(_ key: String) -> (type: String, bytes: [UInt8])? {
        let k = Self.fourCC(key)
        var probe = Param(); probe.key = k; probe.data8 = Self.cmdKeyInfo
        let infoReply = callStruct(&probe)
        guard infoReply.kernel == KERN_SUCCESS else { return nil }
        let info = infoReply.output
        let size = Int(info.keyInfo.dataSize)
        guard size > 0, size <= 32 else { return nil }
        var request = Param(); request.key = k; request.keyInfo = info.keyInfo; request.data8 = Self.cmdRead
        let readReply = callStruct(&request)
        guard readReply.kernel == KERN_SUCCESS else { return nil }
        let out = readReply.output
        var tuple = out.bytes
        let bytes = withUnsafeBytes(of: &tuple) { Array($0.prefix(size)) }
        return (Self.string(info.keyInfo.dataType), bytes)
    }

    private static func fourCC(_ s: String) -> UInt32 { var r: UInt32 = 0; for b in s.utf8.prefix(4) { r = (r << 8) | UInt32(b) }; return r }
    private static func string(_ v: UInt32) -> String {
        String(bytes: [UInt8((v>>24)&0xff), UInt8((v>>16)&0xff), UInt8((v>>8)&0xff), UInt8(v&0xff)], encoding: .ascii) ?? ""
    }
}
