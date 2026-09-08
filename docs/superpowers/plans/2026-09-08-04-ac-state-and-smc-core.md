# AC 상태 공유 + SMC 코어 심화 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 메뉴바 애니메이션이 프레임마다 powerd에 묻던 AC 연결 여부를 `SystemMonitor`가 이미 아는 값으로 바꾸고, SMC 읽기 코어를 하나로 합쳐 `keyInfo` 캐시·result byte 검사·정수 변환 가드를 앱과 데몬이 같이 쓰게 만든다.

**Architecture:** `SystemMonitor.isACConnected`를 관찰 가능한 `private(set)`로 열고 `HardwarePowerSource`를 삭제한다. `SMCConnection`은 IOKit 호출을 클로저(`StructCall`)로 받아 테스트 더블이 가능해지고, `keyInfo`를 키별로 캐시하며, 읽기 응답의 result byte를 검사한다. 데몬의 `SMCControlConnection`은 `SMCConnection`의 typealias + 쓰기 확장으로 줄어 80바이트 `Param` 구조체와 마샬링이 한 벌만 남는다. 순수 `smcInt`가 NaN·inf·범위 밖을 거른다.

**Tech Stack:** Swift 6, IOKit, Swift Testing.

**Spec:** 감사 보고서 §2 High("메뉴바 애니메이션 프레임마다 IOPSCopyPowerSourcesInfo"), Medium("SMC 바이트 Int() 트랩"), Medium("keyInfo 재조회로 RPC 2배"), Low("앱 쪽 SMCConnection.read가 result byte 무시"), §3 "#2 심화 기회" — https://claude.ai/code/artifact/20a3c5b7-ad33-4ec3-ae78-288a0259454d

## Global Constraints

- `project.yml`의 데몬 타깃 소스에 `Wattly/Core/SMC.swift`가 이미 포함돼 있다. `SMC.swift`에 넣는 코드는 데몬에서도 컴파일되므로 AppKit/SwiftUI를 import하지 않는다.
- `SMCConnection`은 액터 격리 안에서만 접근된다는 기존 `@unchecked Sendable` 근거를 유지한다. 캐시 딕셔너리도 같은 격리 아래에 있다.
- `Wattly/Core/Temperature.swift`의 M5 키 목록 등 키 테이블은 건드리지 않는다.
- Swift 6 strict concurrency, macOS 14.0.

---

## 파일 구조

| 파일 | 책임 |
|------|------|
| `Wattly/Core/BatteryPower.swift` (수정) | `smcInt(_:type:) -> Int?` 추가. |
| `Wattly/Providers/BatteryProvider.swift:56-60`, `Wattly/Core/AppleSmartBatteryReader.swift:72-75` (수정) | `smcInt` 사용. |
| `Wattly/Core/SMC.swift` (재작성) | 주입 가능한 `StructCall`, `keyInfo` 캐시, result byte 검사, 내부 타입 `internal`. |
| `WattlyFanDaemon/SMCControlConnection.swift` (재작성) | `typealias SMCControlConnection = SMCConnection` + 쓰기/프로브 확장. |
| `Wattly/Core/SystemMonitor.swift:102` (수정) | `private(set) var isACConnected`. |
| `Wattly/Views/MenuBarLabel.swift:98-100`, `Wattly/Views/Settings/SettingsMenuBarSection.swift:33,191-193,269-271` (수정) | `monitor.isACConnected`. |
| `Wattly/Core/KineticNotchMotion.swift:1-21` (수정) | `HardwarePowerSource` 삭제. |
| `WattlyTests/BatteryPowerTests.swift`, `WattlyTests/SMCConnectionTests.swift` (신규) | |

---

### Task 1: `smcInt` — 트랩 없는 정수 변환

**Files:**
- Modify: `Wattly/Core/BatteryPower.swift:134-145` 아래
- Modify: `Wattly/Providers/BatteryProvider.swift:52-60`, `Wattly/Core/AppleSmartBatteryReader.swift:72-75`
- Test: `WattlyTests/BatteryPowerTests.swift`

**Interfaces:**
- Produces: `func smcInt(_ bytes: [UInt8], type: String) -> Int?`

- [ ] **Step 1: 실패하는 테스트** — `BatteryPowerTests`의 `smcDouble` 섹션 아래에 추가:

```swift
    // MARK: smcInt — Int() 트랩 가드

    @Test func smcIntRoundsFiniteValuesAndRejectsTheRest() {
        #expect(smcInt([0x7f, 0xb6, 0xff, 0xff], type: "si32") == -18817)
        #expect(smcInt([0xb6, 0x30], type: "ui16") == 12470)
        #expect(smcInt([0x95, 0x8a, 0x96, 0x41], type: "flt ") == 19)          // 18.818 → 19
        // NaN·inf 비트 패턴의 flt
        #expect(smcInt([0x00, 0x00, 0xc0, 0x7f], type: "flt ") == nil)          // NaN
        #expect(smcInt([0x00, 0x00, 0x80, 0x7f], type: "flt ") == nil)          // +inf
        // ui64 최대값은 Int 범위를 넘는다
        #expect(smcInt(Array(repeating: 0xff, count: 8), type: "ui64") == nil)
    }
```

- [ ] **Step 2: 실패 확인** — Expected: 컴파일 실패.

- [ ] **Step 3: 구현** — `smcDouble` 바로 아래:

```swift
/// `Int(Double)`은 NaN·inf·범위 밖에서 트랩한다. SMC 바이트는 손상된 `keyInfo`나 `flt ` 키에서 그 셋을 전부
/// 만들 수 있으므로 옵셔널로 거른다. `Fan.swift`의 `fanCount(fromRawFNum:)`이 같은 이유로 가드한다.
func smcInt(_ bytes: [UInt8], type: String) -> Int? {
    let value = smcDouble(bytes, type: type).rounded()
    guard value.isFinite, value >= -9.0e18, value <= 9.0e18 else { return nil }
    return Int(value)
}
```

- [ ] **Step 4: 호출부 교체**

`BatteryProvider.smcSample`:

```swift
        guard let smc,
              let power = smc.read("B0AP"),
              let voltage = smc.read("B0AV"),
              let milliwatts = smcInt(power.bytes, type: power.type) else { return nil }
        let volts = smcDouble(voltage.bytes, type: voltage.type) / 1000.0
        let netW = netWatts(batteryMilliwatts: milliwatts)
        let mA = smc.read("B0AC").flatMap { smcInt($0.bytes, type: $0.type) }
            ?? batteryMilliamps(batteryMilliwatts: milliwatts, volts: volts)
```

`AppleSmartBatteryReader.read()`:

```swift
        if let smc, let power = smc.read("B0AP"),
           let milliwatts = smcInt(power.bytes, type: power.type) {
            reading.netWatts = netWatts(batteryMilliwatts: milliwatts)
        }
```

- [ ] **Step 5: 통과 확인** — Run: `… -only-testing:WattlyTests/BatteryPowerTests`, `… -only-testing:WattlyTests/AppleSmartBatteryReaderTests` — Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Wattly/Core/BatteryPower.swift Wattly/Providers/BatteryProvider.swift Wattly/Core/AppleSmartBatteryReader.swift WattlyTests/BatteryPowerTests.swift
git commit -m "fix(battery): guard SMC byte to Int conversion against NaN, inf and overflow"
```

---

### Task 2: `SMCConnection` — 주입 가능한 호출, `keyInfo` 캐시, result byte 검사

**Files:**
- Rewrite: `Wattly/Core/SMC.swift`
- Create: `WattlyTests/SMCConnectionTests.swift`

**Interfaces:**
- Produces:
  ```swift
  final class SMCConnection: @unchecked Sendable {
      struct KeyInfo { var dataSize: UInt32; var dataType: UInt32; var dataAttributes: UInt8; var p0, p1, p2: UInt8 }
      struct Param { var key: UInt32; var vers: Vers; var pLimit: PLimit; var keyInfo: KeyInfo; var result, status, data8: UInt8; var data32: UInt32; var bytes: Bytes32 }
      typealias StructCall = (inout Param) -> (kernel: kern_return_t, output: Param)
      static let cmdRead: UInt8, cmdKeyInfo: UInt8, kernelIndex: UInt32
      init?()                              // 실제 AppleSMC
      init(call: @escaping StructCall)     // 테스트 더블
      func callStruct(_ input: inout Param) -> (kernel: kern_return_t, output: Param)
      func probeKeyInfo(_ key: String) -> (kernel: kern_return_t, output: Param)   // 캐시 없음, 데몬 프로브용
      func cachedKeyInfo(_ key: String) -> KeyInfo?                                // 캐시
      func read(_ key: String) -> (type: String, bytes: [UInt8])?
      func invalidateKeyInfoCache()
      static func fourCC(_ s: String) -> UInt32
      static func string(_ v: UInt32) -> String
  }
  ```
- Consumes: 없음. Task 3의 데몬 확장이 `callStruct`, `probeKeyInfo`, `Param`, `fourCC`, `string`을 쓴다.

- [ ] **Step 1: 실패하는 테스트**

```swift
// WattlyTests/SMCConnectionTests.swift
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
```

- [ ] **Step 2: 실패 확인** — Expected: 컴파일 실패(`init(call:)`, `cmdKeyInfo` 접근 불가 등).

- [ ] **Step 3: `SMC.swift` 재작성**

```swift
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
```

- [ ] **Step 4: 통과 확인** — Run: `… -only-testing:WattlyTests/SMCConnectionTests` — Expected: 5개 PASS. 앱 타깃 빌드 성공.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/SMC.swift WattlyTests/SMCConnectionTests.swift
git commit -m "refactor(smc): inject the IOKit call, cache keyInfo per key, check the SMC result byte on reads"
```

---

### Task 3: 데몬의 `SMCControlConnection`을 확장으로 축소

**Files:**
- Rewrite: `WattlyFanDaemon/SMCControlConnection.swift`
- 확인만: `WattlyFanDaemon/FanControlHardware.swift`, `WattlyFanDaemon/BatteryControlHardware.swift`, `WattlyFanDaemon/main.swift` (호출 시그니처 유지)

**Interfaces:**
- Produces(데몬 타깃 전용):
  - `typealias SMCControlConnection = SMCConnection`
  - `extension SMCConnection { func keyInfo(_ key: String) -> (type: String, size: Int)?; func batteryKeyProbe(_ key: String) -> BatteryControlKeyProbeResult; func write(_ key: String, bytes: [UInt8]) -> (kernel: kern_return_t, smcResult: UInt8)? }`

- [ ] **Step 1: 재작성**

```swift
// WattlyFanDaemon/SMCControlConnection.swift
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
```

- [ ] **Step 2: 데몬 빌드**

Run: `xcodebuild … -scheme Wattly build` (스킴이 데몬도 빌드한다)
Expected: BUILD SUCCEEDED. `FanControlHardware`/`BatteryControlHardware`의 `smc.keyInfo(...)`, `smc.read(...)`, `smc.write(...)`, `smc.batteryKeyProbe(...)` 호출이 그대로 컴파일된다.

- [ ] **Step 3: 실기 확인** — 도우미를 재설치하고 팬 제어를 켜서 RPM이 바뀌는지, 충전 한도가 걸리는지 1회 확인. 앱 쪽은 `Wattly.app/Contents/MacOS/Wattly -WattlyThermalProbe`(DEBUG)로 온도 샘플 3개가 정상 출력되는지 본다.

- [ ] **Step 4: Commit**

```bash
git add WattlyFanDaemon/SMCControlConnection.swift
git commit -m "refactor(daemon): reuse the shared SMCConnection core; keep only the write extension"
```

---

### Task 4: AC 연결 여부를 `SystemMonitor`에서 읽기

**Files:**
- Modify: `Wattly/Core/SystemMonitor.swift:102`
- Modify: `Wattly/Views/MenuBarLabel.swift:98-100`
- Modify: `Wattly/Views/Settings/SettingsMenuBarSection.swift:33, 190-193, 269-271`
- Modify: `Wattly/Core/KineticNotchMotion.swift:1-21` (`HardwarePowerSource` 삭제, `import IOKit.ps` 제거)
- Test: `WattlyTests/SystemMonitorTests.swift`

- [ ] **Step 1: 실패하는 테스트** — `SystemMonitorTests`에 추가(파일의 `ScriptedProvider`/`ManualClock` 픽스처를 쓴다; 배터리 샘플 생성은 파일 안의 기존 헬퍼를 따른다):

```swift
    @Test func isACConnectedMirrorsTheLatestBatterySample() async {
        let plugged = BatterySample(netW: -20, milliamps: 1500, volts: 12, charging: true, externalConnected: true)
        let unplugged = BatterySample(netW: 15, milliamps: 1200, volts: 12, charging: false, externalConnected: false)
        let provider = ScriptedProvider(kind: .battery, [.value(.battery(plugged)), .value(.battery(unplugged))])
        let monitor = SystemMonitor(providers: [provider], clock: ManualClock())
        #expect(monitor.isACConnected == false)
        await monitor.pollOnce()
        #expect(monitor.isACConnected == true)
        await monitor.pollOnce()
        #expect(monitor.isACConnected == false)
    }
```

(`ScriptedProvider`·`ManualClock`·`pollOnce()`는 이 파일의 `loadingThenValueTransition`이 이미 쓰는 픽스처다. `@MainActor`는 스위트의 다른 테스트와 같은 방식으로 붙인다 — `SystemMonitor`가 `@MainActor`이므로 컴파일러가 요구하면 `@MainActor @Test`.)

- [ ] **Step 2: 실패 확인** — Expected: `isACConnected`가 private이라 컴파일 실패.

- [ ] **Step 3: 구현**

`SystemMonitor.swift:102`:

```swift
    /// 마지막 배터리 샘플의 어댑터 연결 여부. 메뉴바 애니메이션의 프레임 간격이 이 값을 읽는다 —
    /// 프레임마다 `IOPSCopyPowerSourcesInfo`(powerd XPC 왕복)를 부르던 자리다.
    private(set) var isACConnected = false
```

`MenuBarLabel.swift:98-100`을 삭제하고 `interFrameDelay(... isACConnected: isACConnected ...)`를 `isACConnected: monitor.isACConnected`로 바꾼다.

`SettingsMenuBarSection.swift`: `@State private var liveACConnected: Bool = HardwarePowerSource.isACConnected()` 삭제; 루프 안의

```swift
                    let ac = HardwarePowerSource.isACConnected()
                    if ac != liveACConnected {
                        liveACConnected = ac
                    }
```

삭제; `isACConnected: liveACConnected`를 `isACConnected: monitor.isACConnected`로; `private var isACConnected: Bool { liveACConnected }`를 `{ monitor.isACConnected }`로.

`KineticNotchMotion.swift`: `enum HardwarePowerSource { … }` 블록과 `import IOKit.ps`를 삭제한다.

```bash
grep -rn "HardwarePowerSource" Wattly WattlyTests   # 남은 참조가 없어야 한다
```

- [ ] **Step 4: 통과 확인** — Run: `… -only-testing:WattlyTests/SystemMonitorTests`, `… -only-testing:WattlyTests/KineticNotchMotionTests` + 전체 빌드 — Expected: PASS.

- [ ] **Step 5: 실기 확인** — 메뉴바 아이콘 모션을 켠 채 어댑터를 뽑았다 꽂는다. 다음 배터리 폴링(1~5초) 안에 프레임 속도가 24↔60fps로 바뀌면 된다(`MenuBarIconMotion.interFrameDelay`). Activity Monitor에서 Wattly의 "에너지 영향"이 이전보다 낮아졌는지 본다.

- [ ] **Step 6: Commit**

```bash
git add Wattly/Core/SystemMonitor.swift Wattly/Views/MenuBarLabel.swift Wattly/Views/Settings/SettingsMenuBarSection.swift Wattly/Core/KineticNotchMotion.swift WattlyTests/SystemMonitorTests.swift
git commit -m "fix(menubar): read AC state from SystemMonitor instead of querying powerd every frame"
```

---

## Self-Review

- **Spec coverage:** IOPS 프레임 호출 → Task 4 ✔. `Int()` 트랩 → Task 1 ✔. `keyInfo` 재조회 → Task 2 캐시 ✔. result byte → Task 2 ✔. SMC 마샬링 복제 → Task 3 ✔.
- **Placeholder scan:** Task 4 Step 1은 픽스처 이름을 기존 파일에 맞추라고 지시하지만 코드 본문은 완전하다.
- **Type consistency:** `SMCConnection.cmdKeyInfo/cmdRead/fourCC/string/Param/probeKeyInfo/callStruct` Task 2 정의·Task 3 사용 일치. `smcInt(_:type:)` Task 1 정의·호출 일치 ✔.
