# 커뮤니티 테스트 요청 초안 (충전 제한 레지스터 프로브)

> **v2 — 웹 조사 후 전제 수정.** v1은 "M1~M3는 `CH0B`, 2023년 이후 기종은 `CHTE`"라는 칩 세대 기준으로 썼는데, 이건 사실이 아닙니다. 키를 가르는 축은 **칩이 아니라 펌웨어 버전**입니다 (근거: `charlie0129/batt` 소스와 호환성 표, `lslqtz/bclm_loop#5`). 그래서 제보받을 때 칩 이름이 아니라 **펌웨어 버전**을 받아야 합니다.
>
> 게시 전 확인: ① `jjundev/project_wattly` 저장소가 공개 상태인지 (링크가 죽으면 신뢰 요청이 통째로 무너집니다) ② `main` 브랜치에 `scripts/probe-charge-registers.swift`가 실제로 올라가 있는지.
> 본문의 코드는 저장소 파일과 **한 글자도 다르지 않게** 유지하세요. 붙여넣은 코드와 링크 속 코드가 다르면 그 자체가 의심 신호가 됩니다.

---

## 제목 (택 1)

- `[테스트 요청] 맥북 충전 제한 — 펌웨어 버전별로 SMC 키가 다릅니다. 내 맥은 뭘 쓰는지 알려주실 분 (읽기 전용)`
- `아직 macOS 15 이하 쓰시는 분 / 인텔 맥북 쓰시는 분 계신가요? 충전 제한 기능 실기 확인이 필요합니다`
- `[개발] 애플이 충전 제어 SMC 키를 펌웨어마다 바꿉니다 — 제보 부탁드립니다`

---

## 본문

안녕하세요. 맥용 메뉴바 모니터링 앱을 만들고 있고, 지금 **배터리 충전 제한**(원하는 %에서 충전을 멈추는 기능)을 붙이는 중입니다.

문제는 애플이 이 기능이 쓰는 SMC 키를 **펌웨어 업데이트마다 갈아치운다**는 점입니다. 지금까지 파악된 건 이렇습니다.

- 예전 펌웨어(대략 `118xx` 이하): `CH0B` / `CH0C` 쌍 — **주의: macOS 15.7 업데이트가 이미 Tahoe 계열 펌웨어(`138xx`)를 배포했기 때문에, macOS 15를 쓰고 계셔도 `CH0B`가 없을 수 있습니다.**
- Tahoe 계열 펌웨어(`138xx`/`18xxx`): `CHTE` 하나로 교체
- macOS 27 계열 펌웨어: 또 바뀌어서 `bfF0` / `bfD0` / `bfE0` — 펌웨어가 상·하한을 직접 관리
- 인텔 맥: `BCLM`로 알려져 있음 (상한값 자체를 저장)

> **먼저 알려드릴 것**: macOS 26.4 이상 + 애플 실리콘이라면 시스템 설정 → 배터리 → 충전 옆 ⓘ 에서 **애플이 제공하는 충전 제한(80~100%)을 이미 쓰실 수 있습니다** (Apple 지원 문서 102338). 제가 만드는 건 80% 미만 한도, 메뉴바 조작, 그리고 그 이전 macOS를 위한 것입니다. 두 기능을 동시에 켜면 서로 간섭할 수 있으니, 실제 적용 테스트를 도와주실 분은 내장 충전 제한을 꺼주세요.

중요한 건 **칩 세대가 아니라 펌웨어 기준**이라는 겁니다. M1을 쓰더라도 macOS 26으로 올렸으면 `CHTE`일 가능성이 높고, 반대로 신형이어도 구 펌웨어면 `CH0B`일 수 있습니다. 그래서 "M1은 이거, M4는 저거" 식으로 코드에 박아두면 틀립니다.

제 개발 장비는 M5 / 펌웨어 `18000.161.10` **한 대뿐**이고, 여기서 실제로 측정해 확인한 건 `CHTE` 하나입니다. `CHTE`에 1을 쓰자 배터리 충전 전류가 2511 mA → 0 mA로 3초 안에 떨어지고, 그동안 어댑터 입력은 그대로 유지됐습니다(= 배터리는 안 채우고 어댑터로만 구동). 0을 쓰면 다시 충전됩니다. 나머지 조합은 **제 손으로 확인할 방법이 없습니다.**

### 부탁드리는 것

아래 스크립트를 **한 번 실행하고, 출력 전체를 댓글에 붙여주시면** 됩니다. 1초면 끝납니다.

### 안전한가요

- **읽기 전용입니다.** SMC에는 읽기(5) / 키정보(9) / 쓰기(6) 명령이 있는데, 이 스크립트에 선언된 명령 상수는 `cmdRead = 5`와 `cmdKeyInfo = 9` 둘뿐입니다. 쓰기 명령(6)은 상수도, 그걸 부르는 코드도 없습니다 — 하드웨어 상태를 바꾸고 싶어도 바꿀 수단 자체가 없습니다.
- **sudo 필요 없습니다.** root 권한을 요구하면 그때는 의심하셔야 합니다.
- **개인정보 안 나갑니다.** 출력에 시리얼 번호, 사용자명, 호스트명은 일부러 넣지 않았습니다. 모델 식별자(`Mac17,2` 같은), 칩 이름, macOS 버전, 펌웨어 버전만 나옵니다. 실행해서 눈으로 확인하고 붙이실지 결정하시면 됩니다.
- **외부 명령은 두 개뿐입니다.** `/usr/bin/sw_vers`와 `/usr/sbin/system_profiler`, 둘 다 macOS 기본 도구이고 인자도 고정돼 있습니다. `system_profiler` 출력에서는 펌웨어 버전 한 줄만 뽑아 쓰고 시리얼·UUID·모델 번호 등 나머지는 전부 버립니다.
- 전체 소스는 아래 본문에 그대로 붙여뒀고, 저장소에서도 같은 파일을 보실 수 있습니다:
  https://github.com/jjundev/project_wattly/blob/main/scripts/probe-charge-registers.swift

### 실행 방법

Xcode Command Line Tools가 필요합니다. 없으시면 터미널에서 `xcode-select --install` (없는 분은 그냥 넘어가셔도 됩니다. 굳이 몇 GB 받아가면서까지 해주실 필요는 없습니다).

1. 아래 코드를 복사해서 `probe-charge-registers.swift`로 저장 (또는 위 깃허브 링크에서 다운로드)
2. 터미널에서 그 폴더로 이동한 뒤:

```
swift probe-charge-registers.swift
```

3. 나온 내용을 통째로 댓글에 붙여넣기

### 제 M5에서는 이렇게 나옵니다

```
--- Wattly charge-register probe v1 (read-only) ---
model:  Mac17,2
chip:   Apple M5
macOS:  26.6.2 (25G83)
fw:     18000.161.10
deciding keys:
  CHTE  present  type=ui32 size=4 attr=0xd4 writable  value=[00 00 00 00]
  CH0B  absent
  BCLM  absent
firmware-managed keys (macOS 27-era):
  bfF0  absent
  bfD0  present  type=hex_ size=2 attr=0x84 read-only  value=[00 00]
  bfE0  absent
companion keys:
  CH0C  absent
  CH0I  absent
  CH0J  absent
  CHWA  absent
  CHIE  present  type=hex_ size=1 attr=0xd4 writable  value=[00]
battery observation:
  B0AC  present  type=si16 size=2 attr=0x84 read-only  value=[37 fa]
  BC1I  present  type=si32 size=4 attr=0x84 read-only  value=[b8 00 00 00]
verdict: modern
--- end ---
```

`fw:` 줄과 `verdict:` 줄이 핵심입니다.

### 특히 이런 경우가 궁금합니다

- **아직 macOS 15(Sequoia) 이하를 쓰고 계신 애플실리콘 맥북** — `CH0B`/`CH0C` 경로가 진짜 맞는지. 지금 제일 아쉬운 데이터입니다.
- **인텔 맥북** — `BCLM`이 실제로 있는지. 한 번도 확인 못 했습니다.
- **M1 / M2를 macOS 26으로 올리신 분** — 정말 구형 칩에서도 키가 `CHTE`로 바뀌는지. "펌웨어 기준"이라는 가설을 직접 검증하는 케이스입니다.
- **macOS 27 베타를 쓰고 계신 분** — `bfF0`/`bfD0`/`bfE0`가 어떻게 나오는지.
- `unsupported`가 나온 경우도 꼭 알려주세요. 그것도 데이터입니다.

같은 기종이 겹쳐도 괜찮습니다. 펌웨어 버전이 다르면 결과가 달라질 수 있어서 중복 제보가 오히려 도움이 됩니다.

### 실제로 충전이 멈추는지까지 봐주실 분

키가 존재한다는 것과 그 키를 썼을 때 진짜로 충전이 멈춘다는 건 다른 얘기라, 한 걸음 더 도와주실 분을 따로 찾고 있습니다. 이건 root 권한으로 SMC에 쓰기를 해야 해서 위 스크립트로는 안 되고 앱을 설치하셔야 합니다. 결과가 `legacy`나 `intel`로 나오신 분은 댓글이나 쪽지 주시면 방법을 안내드리겠습니다.

인텔 맥은 한 가지 더 있습니다 — macOS 15 이상에서 커널 entitlement가 강화되면서 `BCLM` **쓰기**가 막혔다는 보고가 있습니다(`zackelia/bclm`). 위 읽기 전용 프로브는 아무 문제 없지만, 실제 적용 테스트는 macOS 14 이하에서만 가능할 수 있습니다.

감사합니다. 제보해주신 결과는 어떤 펌웨어가 어떤 키를 쓰는지 표로 정리해서 이 글에 다시 공유하겠습니다.

---

## 코드 전문

```swift
#!/usr/bin/swift
//
// Wattly — charge-control register probe (READ-ONLY)
//
// Prints which SMC charge-control registers this Mac exposes, so the register table in
// `FanControlShared/BatteryControlKeys.swift` can be checked against real hardware other than the
// single M5 it was measured on.
//
// This script only ever issues the SMC "key info" command (9) and the "read" command (5). It
// contains no write path at all — the write opcode is not implemented here — so it cannot change
// any hardware state, and it needs no root. Run it with:
//
//     swift probe-charge-registers.swift
//
import Foundation
import IOKit

// MARK: - Minimal read-only AppleSMC client

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

private let cmdRead: UInt8 = 5
private let cmdKeyInfo: UInt8 = 9
private let kernelIndex: UInt32 = 2

private func fourCC(_ string: String) -> UInt32 {
    var result: UInt32 = 0
    for byte in string.utf8.prefix(4) { result = (result << 8) | UInt32(byte) }
    return result
}

private func string(_ value: UInt32) -> String {
    String(bytes: [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
                   UInt8((value >> 8) & 0xff), UInt8(value & 0xff)], encoding: .ascii) ?? ""
}

private final class SMCReader {
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

    func keyInfo(_ key: String) -> (type: String, size: Int, attributes: UInt8)? {
        var probe = Param(); probe.key = fourCC(key); probe.data8 = cmdKeyInfo
        let reply = call(&probe)
        guard reply.kernel == KERN_SUCCESS else { return nil }
        let size = Int(reply.output.keyInfo.dataSize)
        guard (1...32).contains(size) else { return nil }
        return (string(reply.output.keyInfo.dataType), size, reply.output.keyInfo.dataAttributes)
    }

    func read(_ key: String) -> [UInt8]? {
        let k = fourCC(key)
        var probe = Param(); probe.key = k; probe.data8 = cmdKeyInfo
        let infoReply = call(&probe)
        guard infoReply.kernel == KERN_SUCCESS else { return nil }
        let info = infoReply.output
        let size = Int(info.keyInfo.dataSize)
        guard (1...32).contains(size) else { return nil }
        var request = Param(); request.key = k; request.keyInfo = info.keyInfo; request.data8 = cmdRead
        let readReply = call(&request)
        guard readReply.kernel == KERN_SUCCESS else { return nil }
        var tuple = readReply.output.bytes
        return withUnsafeBytes(of: &tuple) { Array($0.prefix(size)) }
    }

    private func call(_ input: inout Param) -> (kernel: kern_return_t, output: Param) {
        var output = Param()
        var outSize = MemoryLayout<Param>.stride
        let kernel = IOConnectCallStructMethod(connection, kernelIndex, &input,
                                               MemoryLayout<Param>.stride, &output, &outSize)
        return (kernel, output)
    }
}

// MARK: - Report

/// Mirrors `BatteryControlKeys.probeOrder`: first key present *at the expected size* wins.
let probeOrder: [(generation: String, key: String, expectedSize: Int)] = [
    ("modern", "CHTE", 4),
    ("legacy", "CH0B", 1),
    ("intel",  "BCLM", 1)
]
/// macOS 27-era firmware (`20xxx`) hands the limit to the firmware itself through these three keys.
/// All three are printed below for the raw per-key data — that is the point of this script — but
/// only two of them decide the verdict; see `firmwareManagedDecidingKeys`.
let firmwareManagedKeys = ["bfF0", "bfD0", "bfE0"]
/// Mirrors `BatteryControlKeys.firmwareManagedKeys`: the verdict takes precedence over `CHTE`/`CH0B`
/// when both of *these* are present, and `bfD0` is deliberately left out of the vote. `bfD0` shows up
/// on Tahoe firmware all by itself as a 2-byte read-only key (confirmed on the M5 this table was
/// measured on, where the charge limit works fine through `CHTE`), so counting it would report
/// firmware-managed status on a Mac that works today. See the doc comment on
/// `BatteryControlKeys.firmwareManagedKeys` for the full reasoning — this must stay in lockstep with
/// that property, not drift into requiring all three the way `charlie0129/batt` does.
let firmwareManagedDecidingKeys = ["bfF0", "bfE0"]
/// Written alongside the deciding key, or simply worth knowing about. Never decides the generation.
let companionKeys = ["CH0C", "CH0I", "CH0J", "CHWA", "CHIE"]
/// Not charge control — the current the cell is actually taking, which is how a volunteer can tell
/// whether an applied limit really stopped charging.
let observationKeys = ["B0AC", "BC1I"]

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
    return String(cString: buffer)
}

func shell(_ launchPath: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return "unknown" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
}

var lines: [String] = []
lines.append("--- Wattly charge-register probe v1 (read-only) ---")
// Deliberately no serial number and no user or host name: the register table only needs the model,
// the chip and the OS, and a paste headed for a public forum should carry nothing else.
lines.append("model:  \(sysctlString("hw.model"))")
lines.append("chip:   \(sysctlString("machdep.cpu.brand_string"))")
lines.append("macOS:  \(shell("/usr/bin/sw_vers", ["-productVersion"])) (\(shell("/usr/bin/sw_vers", ["-buildVersion"])))")
// The register set tracks the *firmware*, not the chip and not the OS release: an old macOS can
// carry new firmware and vice versa. `system_profiler` also prints the serial number, the hardware
// UUID and the provisioning UDID — each on its own line — so exactly one line is lifted out of it
// and the rest is dropped on the floor.
//
// Two labels, because Apple silicon reports `System Firmware Version` while Intel Macs report
// `Boot ROM Version` for the same field. Taking only the first would print `unknown` on precisely
// the machines whose firmware string is least known.
let hardware = shell("/usr/sbin/system_profiler", ["SPHardwareDataType"])
let firmwareLabels = ["System Firmware Version", "Boot ROM Version"]
let firmware = hardware.split(separator: "\n")
    .compactMap { line -> String? in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let label = firmwareLabels.first(where: { trimmed.hasPrefix($0 + ":") }) else { return nil }
        return trimmed.replacingOccurrences(of: label + ": ", with: "")
    }
    .first ?? "unknown"
lines.append("fw:     \(firmware)")

guard let smc = SMCReader() else {
    lines.append("result: FAILED — could not open AppleSMC")
    print(lines.joined(separator: "\n"))
    exit(1)
}

func describe(_ key: String, expectedSize: Int?) -> String {
    guard let info = smc.keyInfo(key) else {
        return "  \(key)  absent"
    }
    let hex = smc.read(key).map { $0.map { String(format: "%02x", $0) }.joined(separator: " ") } ?? "??"
    let writable = (info.attributes & 0x40) != 0 ? "writable" : "read-only"
    var line = "  \(key)  present  type=\(info.type) size=\(info.size) attr=0x\(String(format: "%02x", info.attributes)) \(writable)  value=[\(hex)]"
    if let expectedSize, info.size != expectedSize {
        line += "  ** SIZE MISMATCH (expected \(expectedSize)) **"
    }
    return line
}

lines.append("deciding keys:")
for candidate in probeOrder {
    lines.append(describe(candidate.key, expectedSize: candidate.expectedSize))
}
lines.append("firmware-managed keys (macOS 27-era):")
for key in firmwareManagedKeys {
    lines.append(describe(key, expectedSize: nil))
}
lines.append("companion keys:")
for key in companionKeys {
    lines.append(describe(key, expectedSize: nil))
}
lines.append("battery observation:")
for key in observationKeys {
    lines.append(describe(key, expectedSize: nil))
}

// Firmware-managed is decided first, exactly like `BatteryControlKeys.registerSet(probing:)`: it
// must win over any of `probeOrder` below, or this script could print `verdict: modern` on a Mac
// where the app itself would decide `.firmwareManaged` and refuse to touch `CHTE`.
let isFirmwareManaged = firmwareManagedDecidingKeys.allSatisfy { smc.keyInfo($0) != nil }
let verdict = isFirmwareManaged
    ? "firmware-managed"
    : probeOrder.first {
        guard let info = smc.keyInfo($0.key) else { return false }
        return info.size == $0.expectedSize
    }?.generation ?? "unsupported"
lines.append("verdict: \(verdict)")
if isFirmwareManaged {
    lines.append("note:    firmware-managed charge limit present (bfF0+bfE0 decide; bfD0 shown above but never votes)")
}
lines.append("--- end ---")

print(lines.joined(separator: "\n"))
```
