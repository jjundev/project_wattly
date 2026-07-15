# Fan Control Phase B-2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Wattly의 CPU 온도 기반 fan curve를 root helper로 안전하게 적용하고, 앱 또는 helper가 제어를 잃으면 macOS automatic control로 복귀시킨다.

**Architecture:** root LaunchDaemon WattlyFanDaemon이 global XPC Mach service를 제공한다. daemon은 SMC write, CPU sensor read, 1초 control loop, 15초 heartbeat watchdog을 소유한다. 앱은 enable 설정, curve, 5초 heartbeat만 전달하며 기존 read-only SMC transport에는 write API를 추가하지 않는다.

**Tech Stack:** Swift 6, SwiftUI, Foundation/Observation, NSXPC, IOKit AppleSMC, XcodeGen, Swift Testing, macOS 14+ arm64.

## Global Constraints

- macOS 14.0+, Swift 6 strict concurrency, arm64만 지원하며 third-party dependency를 추가하지 않는다.
- 개인용 ad-hoc 설치만 지원한다. sudo install/uninstall script를 쓰며 Developer ID, notarization, SMAppService, 앱 내 권한 상승은 쓰지 않는다.
- Wattly가 Macs Fan Control을 대체한다. installer는 MFC 앱 또는 com.crystalidea.macsfancontrol.smcwrite helper가 실행 중이면 중단한다.
- GUI 앱은 writable AppleSMC connection을 열지 않는다. /Library/PrivilegedHelperTools/dev.jjundev.WattlyFanDaemon만 root로 SMC를 쓴다.
- control loop는 daemon 안에 두며 SystemMonitor, app poll cadence, card visibility에 의존하지 않는다.
- fan별 mode key는 F{n}md가 존재하면 M5, 아니면 F{n}Md다. Ftst가 존재할 때만 Ftst=1, 0.5초 대기, mode write를 실행한다.
- SMC result 0x82를 포함한 mode write 실패는 0.5초 간격으로 총 10초까지 재시도한다. 실패하면 target RPM을 쓰지 않고 auto mode로 복귀한다.
- target RPM은 hottest verified CPU sensor와 FanCurve.evaluate(inputCelsius:)로 구한다. max(curveRPM, F{n}Mn) 후 [F{n}Mn, F{n}Mx]로 clamp한다.
- verified CPU sensor 하나라도 95.0 °C 이상이면 무조건 F{n}Mx를 쓴다.
- explicit disable, sensor 불가, SMC 오류, sleep, SIGTERM/SIGINT, 15초 초과 heartbeat에서 모든 controlled fan mode를 0으로 쓴다. watchdog은 5초마다 확인한다.
- fan-control toggle은 false가 기본값이다. helper 미설치, 지원되지 않는 CPU profile, 제어 오류는 auto mode를 유지하며 UI가 제어 중이라고 표시하지 않는다.

---

## File Structure

| Path | Responsibility |
|---|---|
| FanControlShared/FanCurve.swift | app과 daemon이 같은 persisted curve model을 쓰도록 FanCurve를 이동한다. |
| FanControlShared/FanControlProtocol.swift | Codable config/status와 Data-only NSXPC protocol을 정의한다. |
| FanControlShared/FanControlPolicy.swift | pure clamp, safety override, heartbeat expiry를 정의한다. |
| FanControlShared/FanControlEngine.swift | fake hardware로 test 가능한 daemon control state machine이다. |
| Wattly/Core/HardwareModel.swift | app과 daemon 양쪽에서 hw.model을 읽는 작은 platform seam이다. |
| Wattly/Core/SMC.swift | low-level key-info/raw write만 추가한다. app provider에는 write API를 노출하지 않는다. |
| WattlyFanDaemon/FanControlHardware.swift | root-only concrete SMC mode/target/temp adapter다. |
| WattlyFanDaemon/FanControlDaemon.swift, main.swift | caller gate, XPC listener, timers, sleep/signal cleanup을 담당한다. |
| Wattly/Control/FanControlClient.swift | app-side XPC client 및 observable status다. |
| Wattly/Views/FanControlBridge.swift | 항상 mount되어 config/heartbeat를 전달한다. |
| Wattly/Views/SettingsView.swift | preview-only copy를 opt-in toggle 및 helper 상태 UI로 교체한다. |
| Wattly/Settings/Settings.swift, Wattly/Core/SettingsReset.swift | disabled-by-default 설정을 저장/초기화한다. |
| Resources plist, scripts, docs | local deployment, MFC conflict prevention, recovery를 제공한다. |
| WattlyTests/FanControl files | policy/protocol/engine 테스트를 추가한다. |
| project.yml | shared source, daemon tool/test target, scheme을 정의하고 xcodeproj를 regenerate한다. |

**Decision checkpoint:** 추가 질문은 필요 없다. 개인 로컬 설치 조건에서 text socket 대신 NSXPCConnection(machServiceName:options: .privileged)을 사용한다. installer UID와 audit-token PID의 executable basename Wattly를 확인한다. ad-hoc 빌드에서 이것은 distribution-grade code-signature authorization이 아니므로 문서에 제한을 명시한다.

### Task 1: Create shared contracts and build targets

**Files:**
- Create: FanControlShared/FanCurve.swift
- Create: FanControlShared/FanControlProtocol.swift
- Create: Wattly/Core/HardwareModel.swift
- Modify: Wattly/Core/Fan.swift
- Modify: Wattly/Providers/TemperatureProvider.swift
- Modify: project.yml
- Modify: Wattly.xcodeproj/project.pbxproj (generated)
- Test: WattlyTests/FanControlProtocolTests.swift

**Interfaces:**
- Consumes: existing FanCurve in Wattly/Core/Fan.swift.
- Produces: FanControlConfiguration, FanControlServiceMode, FanControlServiceStatus, FanControlCodec, FanControlXPCService.

- [ ] **Step 1: Write failing encoding tests**

~~~swift
import Testing
@testable import Wattly

struct FanControlProtocolTests {
    @Test func configurationRoundTrips() throws {
        let input = FanControlConfiguration(enabled: true,
                                            curve: FanCurve(rpms: [1200, 2500, 4500, 6000]))
        #expect(try FanControlCodec.decode(FanControlConfiguration.self,
                                           from: FanControlCodec.encode(input)) == input)
    }
    @Test func malformedConfigurationIsRejected() {
        #expect(throws: (any Error).self) {
            try FanControlCodec.decode(FanControlConfiguration.self, from: Data("{}".utf8))
        }
    }
}
~~~

- [ ] **Step 2: Run test to verify it fails**

Run: xcodebuild test -project Wattly.xcodeproj -scheme Wattly -only-testing:WattlyTests/FanControlProtocolTests

Expected: FAIL because shared protocol types do not exist.

- [ ] **Step 3: Move curve and define XPC contract**

Move the complete current FanCurve declaration, including anchors, JSON RawRepresentable, and 0...20000 validation, to FanControlShared/FanCurve.swift. Delete only that declaration from Fan.swift. Keep hottestCPUCelsius in Fan.swift because it consumes app-only TemperatureSnapshot. Add the following custom Codable conformance so all XPC-decoded curves pass the same validation as AppStorage:

~~~swift
extension FanCurve: Codable {
    init(from decoder: Decoder) throws {
        let values = try decoder.singleValueContainer().decode([Double].self)
        let data = try JSONSerialization.data(withJSONObject: values)
        guard let raw = String(data: data, encoding: .utf8),
              let curve = FanCurve(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                   debugDescription: "invalid fan curve")
        }
        self = curve
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rpms)
    }
}
~~~

Create Wattly/Core/HardwareModel.swift and move the existing currentHardwareModel implementation out of TemperatureProvider.swift:

~~~swift
import Darwin

func currentHardwareModel() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    guard size > 0 else { return "" }
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &buffer, &size, nil, 0)
    return String(cString: buffer)
}
~~~

~~~swift
import Foundation

struct FanControlConfiguration: Codable, Equatable, Sendable {
    var enabled: Bool
    var curve: FanCurve
}
enum FanControlServiceMode: String, Codable, Equatable, Sendable {
    case unavailable, automatic, engaging, controlling, failed
}
struct FanControlServiceStatus: Codable, Equatable, Sendable {
    var mode: FanControlServiceMode
    var detail: String
    var updatedAt: TimeInterval
}
enum FanControlCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }
}
@objc(FanControlXPCService)
protocol FanControlXPCService {
    func configure(_ data: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func heartbeat(withReply reply: @escaping (Data?, NSError?) -> Void)
    func release(withReply reply: @escaping (Data?, NSError?) -> Void)
    func status(withReply reply: @escaping (Data?, NSError?) -> Void)
}
enum FanControlXPC {
    static let machService = "dev.jjundev.WattlyFanDaemon"
    static let daemonPath = "/Library/PrivilegedHelperTools/dev.jjundev.WattlyFanDaemon"
}
~~~

Add FanControlShared to Wattly sources. Add WattlyFanDaemon as tool target with FanControlShared, Wattly/Core/SMC.swift, Wattly/Core/BatteryPower.swift, Wattly/Core/Temperature.swift, Wattly/Core/HardwareModel.swift, and WattlyFanDaemon sources. Keep engine tests in the existing WattlyTests target: FanControlShared is also compiled into Wattly, so the fake-hardware state machine has no executable-host dependency. Add the daemon product to the Wattly scheme, then regenerate with XcodeGen.

- [ ] **Step 4: Regenerate and run test**

Run: xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -only-testing:WattlyTests/FanControlProtocolTests

Expected: PASS and xcodebuild -list -project Wattly.xcodeproj lists WattlyFanDaemon.

- [ ] **Step 5: Commit**

~~~bash
git add FanControlShared/FanCurve.swift FanControlShared/FanControlProtocol.swift Wattly/Core/HardwareModel.swift \
  Wattly/Core/Fan.swift Wattly/Providers/TemperatureProvider.swift \
  WattlyTests/FanControlProtocolTests.swift project.yml Wattly.xcodeproj
git commit -m "feat(fan): add B2 shared control contracts"
~~~

### Task 2: Implement and test pure safety policy

**Files:**
- Create: FanControlShared/FanControlPolicy.swift
- Create: WattlyTests/FanControlPolicyTests.swift

**Interfaces:**
- Consumes: FanCurve from Task 1.
- Produces: FanLimits, FanControlPolicy.targetRPM(curve:hottestCPU:limits:), heartbeatExpired(last:now:).

- [ ] **Step 1: Write failing safety tests**

~~~swift
import Testing
@testable import Wattly

struct FanControlPolicyTests {
    let curve = FanCurve(rpms: [1200, 2500, 4500, 6000])
    let limits = FanLimits(minimum: 2317, maximum: 6550)
    @Test func curveOnlyRaisesFloor() {
        #expect(FanControlPolicy.targetRPM(curve: curve, hottestCPU: 40, limits: limits) == 2317)
        #expect(FanControlPolicy.targetRPM(curve: curve, hottestCPU: 70, limits: limits) == 3500)
    }
    @Test func criticalTemperatureForcesMaximum() {
        #expect(FanControlPolicy.targetRPM(curve: curve, hottestCPU: 95, limits: limits) == 6550)
    }
    @Test func heartbeatExpiresAtFifteenSeconds() {
        #expect(FanControlPolicy.heartbeatExpired(last: 10, now: 24.999) == false)
        #expect(FanControlPolicy.heartbeatExpired(last: 10, now: 25) == true)
    }
}
~~~

- [ ] **Step 2: Run test to verify it fails**

Run: xcodebuild test -project Wattly.xcodeproj -scheme Wattly -only-testing:WattlyTests/FanControlPolicyTests

Expected: FAIL because FanLimits and FanControlPolicy do not exist.

- [ ] **Step 3: Implement policy**

~~~swift
import Foundation

struct FanLimits: Equatable, Sendable { var minimum: Double; var maximum: Double }
enum FanControlPolicy {
    static let criticalCelsius = 95.0
    static let heartbeatTimeout = 15.0
    static let heartbeatCheckInterval = 5.0
    static let controlInterval = 1.0
    static let modeRetryDeadline = 10.0
    static let modeRetryDelay = 0.5
    static func targetRPM(curve: FanCurve, hottestCPU: Double, limits: FanLimits) -> Double {
        guard hottestCPU.isFinite, limits.minimum.isFinite, limits.maximum.isFinite,
              limits.minimum > 0, limits.maximum >= limits.minimum else { return 0 }
        if hottestCPU >= criticalCelsius { return limits.maximum }
        return min(max(curve.evaluate(inputCelsius: hottestCPU), limits.minimum), limits.maximum)
    }
    static func heartbeatExpired(last: TimeInterval, now: TimeInterval) -> Bool {
        now - last >= heartbeatTimeout
    }
}
~~~

- [ ] **Step 4: Run tests**

Run: xcodebuild test -project Wattly.xcodeproj -scheme Wattly -only-testing:WattlyTests/FanControlPolicyTests -only-testing:WattlyTests/FanTests

Expected: PASS, including existing FanCurve persistence tests.

- [ ] **Step 5: Commit**

~~~bash
git add FanControlShared/FanControlPolicy.swift WattlyTests/FanControlPolicyTests.swift
git commit -m "feat(fan): add B2 safety policy"
~~~

### Task 3: Build root-only SMC adapter and engine

**Files:**
- Modify: Wattly/Core/SMC.swift
- Create: FanControlShared/FanControlEngine.swift
- Create: WattlyFanDaemon/FanControlHardware.swift
- Create: WattlyTests/FanControlEngineTests.swift

**Interfaces:**
- Consumes: Task 1 contracts, Task 2 policy, TemperatureProfiles, smcDouble, SMCConnection.read(_:).
- Produces: FanControlHardware, FanControlEngine.configure(_:now:), heartbeat(now:), tick(now:), release(now:reason:).

- [ ] **Step 1: Write failing engine tests**

~~~swift
import Testing
@testable import Wattly

struct FanControlEngineTests {
    @Test func m5UsesLowercaseModeWithoutFtst() throws {
        let hw = FakeFanControlHardware(modeKey: "F0md", hasFtst: false, hottestCPU: 40,
                                        limits: FanLimits(minimum: 2317, maximum: 6550))
        let engine = FanControlEngine(hardware: hw)
        try engine.configure(.init(enabled: true, curve: .init(rpms: [1200,2500,4500,6000])), now: 0)
        try engine.tick(now: 0)
        #expect(hw.writes == [.mode("F0md", 1), .target(0, 2317)])
        #expect(hw.forceTestWrites == 0)
    }
    @Test func legacyModeUsesFtstAndRetries() throws {
        let hw = FakeFanControlHardware(modeKey: "F0Md", hasFtst: true, modeFailures: 2, hottestCPU: 70,
                                        limits: FanLimits(minimum: 2000, maximum: 6000))
        let engine = FanControlEngine(hardware: hw)
        try engine.configure(.init(enabled: true, curve: .init(rpms: [1200,2500,4500,6000])), now: 0)
        try engine.tick(now: 0)
        #expect(hw.forceTestWrites == 1)
        #expect(hw.modeAttempts == 3)
        #expect(hw.writes.last == .target(0, 3500))
    }
    @Test func expiredHeartbeatReturnsAutomaticMode() throws {
        let hw = FakeFanControlHardware(modeKey: "F0md", hasFtst: false, hottestCPU: 70,
                                        limits: FanLimits(minimum: 2000, maximum: 6000))
        let engine = FanControlEngine(hardware: hw)
        try engine.configure(.init(enabled: true, curve: .init(rpms: [1200,2500,4500,6000])), now: 0)
        try engine.tick(now: 0); try engine.tick(now: 15)
        #expect(hw.writes.last == .mode("F0md", 0))
        #expect(engine.status.mode == .automatic)
    }
    @Test func explicitDisableReturnsAutomaticMode() throws {
        let hw = FakeFanControlHardware(modeKey: "F0md", hasFtst: false, hottestCPU: 70,
                                        limits: FanLimits(minimum: 2000, maximum: 6000))
        let engine = FanControlEngine(hardware: hw)
        try engine.configure(.init(enabled: true, curve: .init(rpms: [1200,2500,4500,6000])), now: 0)
        try engine.tick(now: 0)
        try engine.configure(.init(enabled: false, curve: .init(rpms: [1200,2500,4500,6000])), now: 1)
        #expect(hw.writes.last == .mode("F0md", 0))
    }
    @Test func missingSensorReleasesManualMode() throws {
        let hw = FakeFanControlHardware(modeKey: "F0md", hasFtst: false, hottestCPU: 70,
                                        limits: FanLimits(minimum: 2000, maximum: 6000))
        let engine = FanControlEngine(hardware: hw)
        try engine.configure(.init(enabled: true, curve: .init(rpms: [1200,2500,4500,6000])), now: 0)
        try engine.tick(now: 0); hw.hottestCPU = nil; try engine.tick(now: 1)
        #expect(hw.writes.last == .mode("F0md", 0))
    }
    @Test func acquisitionDeadlineLeavesAutomaticMode() {
        let hw = FakeFanControlHardware(modeKey: "F0md", hasFtst: false, modeFailures: 99, hottestCPU: 70,
                                        limits: FanLimits(minimum: 2000, maximum: 6000))
        let engine = FanControlEngine(hardware: hw)
        #expect(throws: FanControlFailure.self) {
            try engine.configure(.init(enabled: true, curve: .init(rpms: [1200,2500,4500,6000])), now: 0)
            try engine.tick(now: 0)
        }
        #expect(engine.status.mode == .automatic)
    }
    @Test func laterFanFailureReleasesEarlierManualFan() {
        let hw = FakeFanControlHardware(fans: [0, 1], modeKeys: ["F0md", "F1md"],
                                        modeFailuresByFan: [1: 99], hottestCPU: 70,
                                        limits: FanLimits(minimum: 2000, maximum: 6000))
        let engine = FanControlEngine(hardware: hw)
        #expect(throws: FanControlFailure.self) {
            try engine.configure(.init(enabled: true, curve: .init(rpms: [1200,2500,4500,6000])), now: 0)
            try engine.tick(now: 0)
        }
        #expect(hw.writes.contains(.mode("F0md", 0)))
    }
}
~~~

Implement FakeFanControlHardware in this test file with injected fan indexes/mode keys, per-fan mode failure counts, mutable optional hottestCPU, per-fan limits, and recorded Write.mode(String, UInt8) and Write.target(Int, Double). Its single-fan initializer supplies [0] and the common modeKey/modeFailures values; its multi-fan initializer used above supplies the exact dictionaries.

- [ ] **Step 2: Run test to verify it fails**

Run: xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -only-testing:WattlyTests/FanControlEngineTests

Expected: FAIL because daemon engine does not exist.

- [ ] **Step 3: Add raw write support below app transport seam**

In SMC.swift add cmdWrite = 6, internal keyInfo(_:), and write(_:bytes:) returning kernel and smcResult. The method runs cmd 9, requires exact 1...32 byte count, packs Param.bytes, invokes selector 2, and returns output.result. Do not add writes to FanTransport, SMCFanTransport, or FanProvider.

~~~swift
protocol FanControlHardware: AnyObject {
    func fanIndexes() throws -> [Int]
    func modeKey(for index: Int) throws -> String
    func hasForceTestUnlock() throws -> Bool
    func writeForceTest() throws
    func setManual(index: Int, modeKey: String) throws -> Bool
    func setAutomatic(index: Int, modeKey: String) throws
    func limits(for index: Int) throws -> FanLimits
    func hottestCPUCelsius() throws -> Double?
    func setTarget(index: Int, rpm: Double) throws
}
~~~

Implement FanControlEngine with private configuration, lastHeartbeat, controlled [(index:Int, modeKey:String)], and private(set) status. tick rejects expired heartbeat; releases if hottest sensor is nil; engages each fan once; calculates Task 2 target; releases on invalid target or error. Engage detects keys before writing, performs Ftst only if present, sleeps 0.5 seconds between attempts, and on every accepted manual-mode write appends that fan to controlled before handling another fan; therefore a later failure releases every fan that was actually switched to manual. On deadline failure release before throwing. release uses try? to write mode 0 for every controlled fan, clears configuration/heartbeat/list, and sets automatic.

Implement SMCFanControlHardware: discover lower F{n}md by keyInfo then upper F{n}Md; legacy is keyInfo(Ftst) nonnil; require ui8 mode keys and flt size four RPM keys; encode Float32(rpm).bitPattern.littleEndian; accept manual only for KERN_SUCCESS and result zero. Resolve TemperatureProfiles.profile(forModel: currentHardwareModel()), read every cpuGroups key with flt, and return hottestCelsius(_:in:). Missing profile or no valid sensor returns nil and releases control.

- [ ] **Step 4: Run focused tests**

Run: xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -only-testing:WattlyTests/FanControlEngineTests -only-testing:WattlyTests/FanTests -only-testing:WattlyTests/FanProviderTests

Expected: PASS. Existing app fan transport remains read-only.

- [ ] **Step 5: Commit**

~~~bash
git add Wattly/Core/SMC.swift FanControlShared/FanControlEngine.swift WattlyFanDaemon/FanControlHardware.swift \
  WattlyTests/FanControlEngineTests.swift project.yml Wattly.xcodeproj
git commit -m "feat(fan): add privileged control engine"
~~~

### Task 4: Expose engine as root XPC LaunchDaemon

**Files:**
- Create: WattlyFanDaemon/FanControlDaemon.swift
- Create: WattlyFanDaemon/main.swift
- Create: Resources/com.dev.jjundev.WattlyFanDaemon.plist
- Modify: project.yml

**Interfaces:**
- Consumes: FanControlXPCService and FanControlEngine.
- Produces: XPC mach service dev.jjundev.WattlyFanDaemon for Task 6.

- [ ] **Step 1: Add status-codec regression test**

~~~swift
@Test func controllingStatusRoundTrips() throws {
    let input = FanControlServiceStatus(mode: .controlling, detail: "CPU 70°C", updatedAt: 100)
    #expect(try FanControlCodec.decode(FanControlServiceStatus.self,
                                      from: FanControlCodec.encode(input)) == input)
}
~~~

- [ ] **Step 2: Run status-codec regression test**

Run: xcodebuild test -project Wattly.xcodeproj -scheme Wattly -only-testing:WattlyTests/FanControlProtocolTests

Expected: PASS with no root process; this protects the shared XPC response format while the daemon is added.

- [ ] **Step 3: Implement listener, caller gate, timers, cleanup**

Implement FanControlDaemon as NSObject, NSXPCListenerDelegate, FanControlXPCService. Construct NSXPCListener(machServiceName: FanControlXPC.machService). In listener(_:shouldAcceptNewConnection:), use audit_token_to_euid(connection.auditToken) to require installer-provided WATTLY_ALLOWED_UID, get audit_token_to_pid, resolve proc_pidpath, and accept only basename Wattly. Set exported interface/object and resume.

All XPC calls run on one serial queue and reply with FanControlCodec.encode(engine.status). configure decodes FanControlConfiguration; heartbeat updates timestamp; release invokes engine.release(now:reason: "앱에서 해제"); status is read-only. Start a 1-second timer that runs engine.tick(now:) and a 5-second timer that runs tick for watchdog expiry. On SIGTERM, SIGINT, and NSWorkspace.willSleepNotification, synchronously call engine.release before exit or sleep.

~~~swift
import Foundation
let rawUID = ProcessInfo.processInfo.environment["WATTLY_ALLOWED_UID"] ?? ""
guard let uid = UInt32(rawUID), uid > 0 else { fputs("WATTLY_ALLOWED_UID is required\n", stderr); exit(78) }
let daemon = FanControlDaemon(allowedUID: uid_t(uid), hardware: SMCFanControlHardware())
daemon.run()
RunLoop.main.run()
~~~

~~~xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>dev.jjundev.WattlyFanDaemon</string>
<key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/dev.jjundev.WattlyFanDaemon</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>MachServices</key><dict><key>dev.jjundev.WattlyFanDaemon</key><true/></dict>
<key>EnvironmentVariables</key><dict><key>WATTLY_ALLOWED_UID</key><string>__WATTLY_ALLOWED_UID__</string></dict>
</dict></plist>
~~~

- [ ] **Step 4: Build daemon and run protocol tests**

Run: xcodegen generate && xcodebuild build -project Wattly.xcodeproj -scheme Wattly -configuration Debug && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -only-testing:WattlyTests/FanControlProtocolTests

Expected: BUILD SUCCEEDED and PASS. Do not start root daemon yet.

- [ ] **Step 5: Commit**

~~~bash
git add WattlyFanDaemon Resources/com.dev.jjundev.WattlyFanDaemon.plist project.yml Wattly.xcodeproj
git commit -m "feat(fan): add root XPC fan daemon"
~~~

### Task 5: Add local install, conflict prevention, recovery

**Files:**
- Create: scripts/install-fan-helper.sh
- Create: scripts/uninstall-fan-helper.sh
- Create: docs/fan-control-local-install.md

**Interfaces:**
- Consumes: daemon product, plist template, label, helper path from Tasks 1 and 4.
- Produces: root:wheel helper, launchd service bound to invoking UID, documented recovery path.

- [ ] **Step 1: Write failing shell syntax invocation**

~~~bash
zsh -n scripts/install-fan-helper.sh scripts/uninstall-fan-helper.sh
~~~

- [ ] **Step 2: Run it to verify it fails**

Run: zsh -n scripts/install-fan-helper.sh scripts/uninstall-fan-helper.sh

Expected: FAIL because scripts do not exist.

- [ ] **Step 3: Implement installer behavior**

~~~zsh
#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"; label="dev.jjundev.WattlyFanDaemon"
helper="/Library/PrivilegedHelperTools/$label"; plist="/Library/LaunchDaemons/$label.plist"
uid="$(id -u)"
[[ "$uid" -gt 0 ]] || { print -u2 "Run as the login user, not root."; exit 64; }
if pgrep -x "Macs Fan Control" >/dev/null || launchctl print system/com.crystalidea.macsfancontrol.smcwrite >/dev/null 2>&1; then
  print -u2 "Quit and uninstall Macs Fan Control before installing Wattly fan control."; exit 1
fi
xcodebuild -project "$root/Wattly.xcodeproj" -scheme Wattly -configuration Debug build
dir="$(xcodebuild -project "$root/Wattly.xcodeproj" -scheme Wattly -configuration Debug -showBuildSettings | awk -F ' = ' '/TARGET_BUILD_DIR/ {print $2; exit}')"
[[ -x "$dir/WattlyFanDaemon" ]] || { print -u2 "Daemon product missing."; exit 1; }
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
sed "s/__WATTLY_ALLOWED_UID__/$uid/g" "$root/Resources/$label.plist" > "$tmp"
sudo launchctl bootout system/$label 2>/dev/null || true
sudo install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools /Library/LaunchDaemons
sudo install -o root -g wheel -m 755 "$dir/WattlyFanDaemon" "$helper"
sudo install -o root -g wheel -m 644 "$tmp" "$plist"
sudo launchctl bootstrap system "$plist"
sudo launchctl kickstart -k system/$label
sudo launchctl print system/$label >/dev/null
~~~

~~~zsh
#!/bin/zsh
set -euo pipefail
label="dev.jjundev.WattlyFanDaemon"
sudo launchctl bootout system/$label 2>/dev/null || true
sudo rm -f "/Library/LaunchDaemons/$label.plist" "/Library/PrivilegedHelperTools/$label"
~~~

Document: quit/uninstall MFC first; install with script; toggle remains off until smoke test; uninstall is recovery. State UID/path authorization is local-owner-only. Require recorded original mode/target, target never below min, heartbeat auto release, reboot auto state, and cold boot without MFC.

- [ ] **Step 4: Verify scripts and docs**

Run: zsh -n scripts/install-fan-helper.sh scripts/uninstall-fan-helper.sh && rg -n 'Macs Fan Control|heartbeat|sudo|automatic' docs/fan-control-local-install.md scripts/install-fan-helper.sh

Expected: PASS; every safety term is present.

- [ ] **Step 5: Commit**

~~~bash
git add scripts/install-fan-helper.sh scripts/uninstall-fan-helper.sh docs/fan-control-local-install.md
git commit -m "docs(fan): add local B2 helper installation"
~~~

### Task 6: Add app client, heartbeat, opt-in UI

**Files:**
- Create: Wattly/Control/FanControlClient.swift
- Create: Wattly/Views/FanControlBridge.swift
- Modify: Wattly/App/WattlyApp.swift
- Modify: Wattly/Settings/Settings.swift
- Modify: Wattly/Core/SettingsReset.swift
- Modify: Wattly/Views/SettingsView.swift
- Modify: WattlyTests/SettingsResetTests.swift

**Interfaces:**
- Consumes: Tasks 1 and 4 XPC types and Task 5 installation contract.
- Produces: FanControlClient, StorageKey.fanControlEnabled, settings status UI.

- [ ] **Step 1: Write failing reset test**

~~~swift
@Test func resetDisablesFanControl() {
    let defaults = makeDefaults(#function)
    defaults.set(true, forKey: StorageKey.fanControlEnabled)
    SettingsReset.applyDefaults(into: defaults)
    #expect(defaults.bool(forKey: StorageKey.fanControlEnabled) == false)
}
~~~

- [ ] **Step 2: Run test to verify it fails**

Run: xcodebuild test -project Wattly.xcodeproj -scheme Wattly -only-testing:WattlyTests/SettingsResetTests/resetDisablesFanControl

Expected: FAIL because setting key does not exist.

- [ ] **Step 3: Implement client, bridge, persistence, UI**

~~~swift
import Foundation
import Observation

@MainActor @Observable final class FanControlClient {
    private(set) var status = FanControlServiceStatus(mode: .unavailable, detail: "도우미에 연결되지 않음", updatedAt: 0)
    func apply(enabled: Bool, curve: FanCurve) async {
        await send { service, reply in service.configure(try! FanControlCodec.encode(.init(enabled: enabled, curve: curve)), withReply: reply) }
    }
    func heartbeat() async { await send { $0.heartbeat(withReply: $1) } }
    func release() async { await send { $0.release(withReply: $1) } }
    private func send(_ call: @escaping (any FanControlXPCService, @escaping (Data?, NSError?) -> Void) -> Void) async {
        await withCheckedContinuation { continuation in
            let c = NSXPCConnection(machServiceName: FanControlXPC.machService, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: FanControlXPCService.self); c.resume()
            guard let service = c.remoteObjectProxyWithErrorHandler({ error in
                Task { @MainActor in self.status = .init(mode: .failed, detail: error.localizedDescription, updatedAt: Date().timeIntervalSince1970) }
                c.invalidate(); continuation.resume()
            }) as? any FanControlXPCService else { c.invalidate(); continuation.resume(); return }
            call(service) { data, error in
                Task { @MainActor in
                    defer { c.invalidate(); continuation.resume() }
                    guard error == nil, let data, let value = try? FanControlCodec.decode(FanControlServiceStatus.self, from: data) else {
                        self.status = .init(mode: .unavailable, detail: error?.localizedDescription ?? "도우미 응답 오류", updatedAt: Date().timeIntervalSince1970); return
                    }
                    self.status = value
                }
            }
        }
    }
}
~~~

Add Defaults.fanControlEnabled = false and StorageKey.fanControlEnabled = "fanControlEnabled"; SettingsReset.applyDefaults writes this default. Add FanControlBridge on menu-bar label background beside PollPolicyBridge: it observes enable and curve, calls apply in task and change handlers, then calls heartbeat every 5 seconds only while enabled. It must not release because Settings or popover unmounts.

In WattlyApp create one State FanControlClient, mount bridge, pass client to SettingsView. In existing fanCurveSection retain sliders and preview, then add SettingsToggleRow labeled 팬 커브 실제 적용 with secondary text Wattly가 macOS 기본 최소 RPM 이상으로만 팬을 제어합니다. Macs Fan Control은 종료해야 합니다. Render only under existing monitor.isPresent(.fan). Map status: unavailable → 도우미 미설치 — scripts/install-fan-helper.sh 실행; automatic → macOS 자동 제어; engaging → 수동 제어 연결 중; controlling → 팬 커브 적용 중; failed → 제어 실패 — macOS 자동 제어로 복귀.

- [ ] **Step 4: Run settings and full build verification**

Run: xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -only-testing:WattlyTests/SettingsResetTests && xcodebuild build -project Wattly.xcodeproj -scheme Wattly -configuration Debug

Expected: PASS then BUILD SUCCEEDED. With helper absent, UI says unavailable rather than controlling.

- [ ] **Step 5: Commit**

~~~bash
git add Wattly/Control/FanControlClient.swift Wattly/Views/FanControlBridge.swift Wattly/App/WattlyApp.swift \
  Wattly/Settings/Settings.swift Wattly/Core/SettingsReset.swift Wattly/Views/SettingsView.swift \
  WattlyTests/SettingsResetTests.swift project.yml Wattly.xcodeproj
git commit -m "feat(fan): add B2 control toggle and status"
~~~

### Task 7: Run automated tests and guarded M5 acceptance

**Files:**
- Modify: docs/fan-control-local-install.md
- Test: all WattlyTests and the manual M5 checklist

**Interfaces:**
- Consumes: all previous tasks.
- Produces: dated local acceptance record for Mac17,2/M5.

- [ ] **Step 1: Run complete automated suite**

Run: xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly

Expected: TEST SUCCEEDED with all existing suites plus policy, protocol, engine, and reset tests.

- [ ] **Step 2: Build and install after proving MFC is absent**

Run: pgrep -x "Macs Fan Control"; launchctl print system/com.crystalidea.macsfancontrol.smcwrite; ./scripts/install-fan-helper.sh

Expected: both conflict checks must be absent before install; installer prints running dev.jjundev.WattlyFanDaemon. If either is present, stop, quit/uninstall MFC, and retry this step.

- [ ] **Step 3: Execute and record safety acceptance checklist**

~~~text
1. Start with UI toggle off; verify mode 0 and macOS automatic.
2. Enable; allow at most 10 seconds for F0md=1; verify F0Tg >= F0Mn and F0Ac follows it.
3. Under normal load, record CPU temperature, F0Tg, F0Ac, F0Mn/F0Mx, and daemon status.
4. Quit Wattly without disabling. Within 20 seconds, verify watchdog timeout and F0md returns to 0.
5. Reboot and verify automatic idle. Cold-boot again with MFC absent; enable and record manual-mode acquisition time.
~~~

Do not deliberately force the machine past 95°C merely to test override. If naturally observed, record F0Tg == F0Mx.

- [ ] **Step 4: Commit acceptance result**

~~~bash
git add docs/fan-control-local-install.md
git commit -m "docs(fan): record B2 local acceptance"
~~~

## Self-Review

- **Spec coverage:** privileged helper/install (Tasks 3–5); M5 lower-case mode, M1–M4 Ftst and retry (Task 3); daemon-owned hottest-CPU loop, floor clamp, 95°C max, watchdog/release (Tasks 2–4); MFC replacement (Task 5); B1 curve/settings/presence integration (Task 6); cold-machine confirmation (Task 7).
- **Placeholder scan:** Every task has exact paths, test code, commands, concrete symbols, and a commit.
- **Type consistency:** app and daemon share FanCurve, FanControlConfiguration, FanControlServiceStatus, and FanControlXPCService. Engine depends only on FanControlHardware; root SMCFanControlHardware implements it. App fan transports remain read-only.
