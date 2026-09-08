import Foundation
import IOKit

/// 읽기 전용 `AppleSMC` 클라이언트(앱·데몬 공용 코어). 쓰기는 데몬 타깃의 확장에만 있다.
///
/// 80바이트 파라미터 구조체와 마샬링은 여기 **한 벌**만 있다. `keyInfo`는 12바이트로 패딩해야 Swift가
/// `result`/`status`/`data8`를 꼬리 패딩에 끼워 넣지 않는다(76바이트가 되면 커널이 kIOReturnBadArgument로 거부).
///
/// `io_connect_t`는 프로세스 수명 동안 하나의 액터 격리 안에서만 만지므로 `@unchecked Sendable`.
/// `keyInfo` 캐시도 같은 격리 아래에 있다 — 키의 타입·크기는 부팅 뒤 변하지 않는다.
final class SMCConnection: @unchecked Sendable {
    typealias Bytes32 = (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                         UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                         UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                         UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8)
    struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
    struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    struct KeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0; var p0: UInt8 = 0, p1: UInt8 = 0, p2: UInt8 = 0 }
    struct Param {
        var key: UInt32 = 0
        var vers = Vers()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes32 = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }

    typealias StructCall = (inout Param) -> (kernel: kern_return_t, output: Param)

    static let cmdRead: UInt8 = 5
    static let cmdKeyInfo: UInt8 = 9
    static let kernelIndex: UInt32 = 2

    private let connection: io_connect_t?
    private let call: StructCall
    private var keyInfoCache: [UInt32: KeyInfo] = [:]

    /// nil if `AppleSMC` is unavailable (graceful degrade — the caller then falls back).
    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS, conn != 0 else { return nil }
        connection = conn
        call = { input in
            var output = Param()
            var outSize = MemoryLayout<Param>.stride
            let kr = IOConnectCallStructMethod(conn, SMCConnection.kernelIndex, &input,
                                               MemoryLayout<Param>.stride, &output, &outSize)
            return (kr, output)
        }
    }

    /// 테스트 더블. IOKit 없이 `call`이 응답을 만든다.
    init(call: @escaping StructCall) {
        connection = nil
        self.call = call
    }

    deinit { if let connection { IOServiceClose(connection) } }

    func callStruct(_ input: inout Param) -> (kernel: kern_return_t, output: Param) {
        call(&input)
    }

    /// 캐시를 거치지 않는 원시 keyInfo 프로브. 데몬의 레지스터 탐색이 result byte까지 보려고 쓴다.
    func probeKeyInfo(_ key: String) -> (kernel: kern_return_t, output: Param) {
        var probe = Param()
        probe.key = Self.fourCC(key)
        probe.data8 = Self.cmdKeyInfo
        return call(&probe)
    }

    /// 키의 타입·크기. 성공한 프로브만 캐시하므로 없는 키는 매번 다시 묻는다(부팅 중 늦게 뜨는 키 대비).
    func cachedKeyInfo(_ key: String) -> KeyInfo? {
        let k = Self.fourCC(key)
        if let cached = keyInfoCache[k] { return cached }
        let reply = probeKeyInfo(key)
        guard reply.kernel == KERN_SUCCESS, reply.output.result == 0,
              (1...32).contains(Int(reply.output.keyInfo.dataSize)) else { return nil }
        keyInfoCache[k] = reply.output.keyInfo
        return reply.output.keyInfo
    }

    /// One 4-char SMC key as its FourCC type label + raw value bytes, or nil if the key is
    /// absent / unreadable. 읽기가 실패하면 캐시를 비워 다음 읽기가 다시 프로브하게 한다.
    func read(_ key: String) -> (type: String, bytes: [UInt8])? {
        let k = Self.fourCC(key)
        guard let info = cachedKeyInfo(key) else { return nil }
        var request = Param()
        request.key = k
        request.keyInfo = info
        request.data8 = Self.cmdRead
        let reply = call(&request)
        guard reply.kernel == KERN_SUCCESS, reply.output.result == 0 else {
            keyInfoCache[k] = nil
            return nil
        }
        var tuple = reply.output.bytes
        let bytes = withUnsafeBytes(of: &tuple) { Array($0.prefix(Int(info.dataSize))) }
        return (Self.string(info.dataType), bytes)
    }

    func invalidateKeyInfoCache() { keyInfoCache.removeAll() }

    static func fourCC(_ s: String) -> UInt32 {
        var r: UInt32 = 0
        for b in s.utf8.prefix(4) { r = (r << 8) | UInt32(b) }
        return r
    }

    static func string(_ v: UInt32) -> String {
        String(bytes: [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)],
               encoding: .ascii) ?? ""
    }
}
