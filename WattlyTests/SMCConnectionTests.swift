import Testing
import Foundation
import IOKit
@testable import Wattly

@Suite struct SMCConnectionTests {
    private final class Recorder: @unchecked Sendable { var commands: [UInt8] = [] }

    /// keyInfo → read 순서로 응답하는 가짜 SMC. `readResult`로 읽기 실패를, `keyInfoResult`로 키 없음을 흉내 낸다.
    private static func fakeSMC(_ rec: Recorder, keyInfoResult: UInt8 = 0, readResult: UInt8 = 0) -> SMCConnection {
        SMCConnection(call: { param in
            rec.commands.append(param.data8)
            var out = param
            if param.data8 == SMCConnection.cmdKeyInfo {
                out.result = keyInfoResult
                out.keyInfo.dataSize = keyInfoResult == 0 ? 4 : 0
                out.keyInfo.dataType = SMCConnection.fourCC("flt ")
            } else {
                out.result = readResult
                out.bytes.0 = 0x95; out.bytes.1 = 0x8a; out.bytes.2 = 0x96; out.bytes.3 = 0x41
            }
            return (KERN_SUCCESS, out)
        })
    }

    @Test func keyInfoIsProbedOnceAndReusedByLaterReads() {
        let rec = Recorder()
        let smc = Self.fakeSMC(rec)
        let first = smc.read("TC0P")
        let second = smc.read("TC0P")
        #expect(first?.type == "flt " && first?.bytes == [0x95, 0x8a, 0x96, 0x41])
        #expect(second?.bytes == first?.bytes)
        #expect(rec.commands == [SMCConnection.cmdKeyInfo, SMCConnection.cmdRead, SMCConnection.cmdRead])
    }

    @Test func failedReadReturnsNilAndEvictsTheCache() {
        let rec = Recorder()
        let smc = Self.fakeSMC(rec, readResult: 0x84)
        #expect(smc.read("TC0P") == nil)
        #expect(smc.read("TC0P") == nil)
        #expect(rec.commands == [SMCConnection.cmdKeyInfo, SMCConnection.cmdRead,
                                 SMCConnection.cmdKeyInfo, SMCConnection.cmdRead])
    }

    @Test func absentKeyIsNeverCached() {
        let rec = Recorder()
        let smc = Self.fakeSMC(rec, keyInfoResult: 0x84)
        #expect(smc.read("XXXX") == nil)
        #expect(smc.read("XXXX") == nil)
        #expect(rec.commands == [SMCConnection.cmdKeyInfo, SMCConnection.cmdKeyInfo])
    }

    @Test func invalidateForcesAFreshProbe() {
        let rec = Recorder()
        let smc = Self.fakeSMC(rec)
        _ = smc.read("TC0P")
        smc.invalidateKeyInfoCache()
        _ = smc.read("TC0P")
        #expect(rec.commands == [SMCConnection.cmdKeyInfo, SMCConnection.cmdRead,
                                 SMCConnection.cmdKeyInfo, SMCConnection.cmdRead])
    }

    @Test func fourCCRoundTrips() {
        #expect(SMCConnection.string(SMCConnection.fourCC("B0AP")) == "B0AP")
        #expect(SMCConnection.string(SMCConnection.fourCC("flt ")) == "flt ")
    }
}
