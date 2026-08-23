# Battery Charge Limit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a customizable battery charge limit (80%, 85%, 90%, 95%, etc.) to Wattly to preserve MacBook battery health by preventing continuous 100% charging while connected to AC power, leveraging the existing root helper daemon and AppleSMC register control (`CH0B` on Apple Silicon / `BCLM` on Intel) with hysteresis to prevent system CPU bloat.

**Architecture:** Extend the existing root-level Privileged Helper Daemon (`WattlyFanDaemon`) with a `BatteryControlEngine` that monitors battery SoC (State of Charge) and writes to AppleSMC (`CH0B` = 0x02 to bypass charge, 0x00 to enable) only on state transitions. Connect the SwiftUI Settings UI and background app lifecycle to the daemon via XPC with `BatteryControlClient` and `BatteryControlBridge`.

**Tech Stack:** Swift 6, Swift Testing (`import Testing`), IOKit (`AppleSMC`, `IOPSCopyPowerSourcesInfo`), XPC (`NSXPCConnection`), SwiftUI, `@Observable`.

## Global Constraints

- Never poll or write SMC keys continuously in a loop; only write SMC registers when transitioning state (e.g. crossing the upper or lower threshold) to prevent `PerfPowerServices` CPU spikes and `PowerLog` database bloat.
- Support both Apple Silicon (`CH0B` register 0x02/0x00) and Intel Macs (`BCLM` percentage register).
- Implement a 2% hysteresis buffer (e.g., target 85% stops charging at >= 85%, resumes charging at <= 83%) to prevent charging oscillation.
- Re-evaluate and re-apply battery control state upon system wake (`didWakeNotification` / DarkWake) and app launch.
- Must seamlessly share the existing root daemon (`WattlyFanDaemon`) and its `SMCControlConnection` without requiring a second helper or double admin authentication.

---

### Task 1: Shared Battery Control Protocol & Models

**Files:**
- Create: `FanControlShared/BatteryControlProtocol.swift`
- Test: `WattlyTests/BatteryControlProtocolTests.swift`

**Interfaces:**
- Produces:
  - `struct BatteryControlConfiguration: Codable, Equatable, Sendable` (`enabled: Bool`, `limitPercentage: Int`, `lowerHysteresisDelta: Int`)
  - `struct BatteryControlConfigurationRequest: Codable, Equatable, Sendable` (`configuration: BatteryControlConfiguration`, `generation: UInt64`)
  - `enum BatteryControlServiceMode: String, Codable, Equatable, Sendable` (`unavailable`, `charging`, `inhibited`, `unsupported`)
  - `struct BatteryControlServiceStatus: Codable, Equatable, Sendable` (`mode: BatteryControlServiceMode`, `currentPercentage: Int`, `isPowerAdapterConnected: Bool`, `detail: String`, `updatedAt: TimeInterval`)
  - `enum BatteryControlCodec`

- [ ] **Step 1: Write the failing test for BatteryControlProtocol serialization & validation**

Create `WattlyTests/BatteryControlProtocolTests.swift`:
```swift
import Foundation
import Testing
@testable import Wattly

struct BatteryControlProtocolTests {
    @Test func configurationRoundTrips() throws {
        let input = BatteryControlConfiguration(enabled: true, limitPercentage: 85, lowerHysteresisDelta: 2)
        let encoded = try BatteryControlCodec.encode(input)
        let decoded = try BatteryControlCodec.decode(BatteryControlConfiguration.self, from: encoded)
        #expect(decoded == input)
    }

    @Test func requestCarriesGeneration() throws {
        let config = BatteryControlConfiguration(enabled: true, limitPercentage: 85, lowerHysteresisDelta: 2)
        let request = BatteryControlConfigurationRequest(configuration: config, generation: 42)
        let encoded = try BatteryControlCodec.encode(request)
        let decoded = try BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: encoded)
        #expect(decoded == request)
    }

    @Test func statusRoundTrips() throws {
        let status = BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 85,
            isPowerAdapterConnected: true,
            detail: "충전 제한 활성화됨 (AC 바이패스 구동 중)",
            updatedAt: 1000.0
        )
        let encoded = try BatteryControlCodec.encode(status)
        let decoded = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: encoded)
        #expect(decoded == status)
    }

    @Test func limitPercentageClamping() {
        let lowConfig = BatteryControlConfiguration(enabled: true, limitPercentage: 30)
        #expect(lowConfig.clampedLimitPercentage == 50)
        let highConfig = BatteryControlConfiguration(enabled: true, limitPercentage: 110)
        #expect(highConfig.clampedLimitPercentage == 100)
        #expect(lowConfig.resumePercentage == 48) // 50 - 2 = 48
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'`
Expected: FAIL (Cannot find `BatteryControlConfiguration` in scope)

- [ ] **Step 3: Implement BatteryControlProtocol.swift**

Create `FanControlShared/BatteryControlProtocol.swift`:
```swift
import Foundation

public struct BatteryControlConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var limitPercentage: Int
    public var lowerHysteresisDelta: Int

    public init(enabled: Bool = false, limitPercentage: Int = 80, lowerHysteresisDelta: Int = 2) {
        self.enabled = enabled
        self.limitPercentage = limitPercentage
        self.lowerHysteresisDelta = max(1, min(5, lowerHysteresisDelta))
    }

    public var clampedLimitPercentage: Int {
        max(50, min(100, limitPercentage))
    }

    public var resumePercentage: Int {
        max(45, clampedLimitPercentage - lowerHysteresisDelta)
    }
}

public struct BatteryControlConfigurationRequest: Codable, Equatable, Sendable {
    public var configuration: BatteryControlConfiguration
    public var generation: UInt64

    public init(configuration: BatteryControlConfiguration, generation: UInt64) {
        self.configuration = configuration
        self.generation = generation
    }
}

public enum BatteryControlServiceMode: String, Codable, Equatable, Sendable {
    case unavailable
    case charging
    case inhibited
    case unsupported
}

public struct BatteryControlServiceStatus: Codable, Equatable, Sendable {
    public var mode: BatteryControlServiceMode
    public var currentPercentage: Int
    public var isPowerAdapterConnected: Bool
    public var detail: String
    public var updatedAt: TimeInterval

    public init(mode: BatteryControlServiceMode, currentPercentage: Int, isPowerAdapterConnected: Bool, detail: String, updatedAt: TimeInterval) {
        self.mode = mode
        self.currentPercentage = currentPercentage
        self.isPowerAdapterConnected = isPowerAdapterConnected
        self.detail = detail
        self.updatedAt = updatedAt
    }
}

public enum BatteryControlCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add FanControlShared/BatteryControlProtocol.swift WattlyTests/BatteryControlProtocolTests.swift
git commit -m "feat(battery): add battery control protocol and models"
```

---

### Task 2: Battery Control Hardware & State Machine Engine

**Files:**
- Create: `WattlyFanDaemon/BatteryControlHardware.swift`
- Create: `FanControlShared/BatteryControlEngine.swift`
- Test: `WattlyTests/BatteryControlEngineTests.swift`

**Interfaces:**
- Consumes: `BatteryControlConfiguration`, `BatteryControlServiceStatus`
- Produces:
  - `protocol BatteryControlHardwareProtocol`
  - `final class BatteryControlEngine`

- [ ] **Step 1: Write the failing test for BatteryControlEngine state transitions and hysteresis**

Create `WattlyTests/BatteryControlEngineTests.swift`:
```swift
import Foundation
import Testing
@testable import Wattly

final class MockBatteryHardware: BatteryControlHardwareProtocol, @unchecked Sendable {
    var isAppleSilicon: Bool = true
    var chargingInhibited: Bool = false
    var appliedLimit: Int = 100
    var writeCount: Int = 0

    func setChargingInhibited(_ inhibited: Bool, targetLimit: Int) -> Bool {
        if chargingInhibited != inhibited || appliedLimit != targetLimit {
            chargingInhibited = inhibited
            appliedLimit = targetLimit
            writeCount += 1
        }
        return true
    }
}

struct BatteryControlEngineTests {
    @Test func hysteresisTransitionStopsAtLimitAndResumesBelowThreshold() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85, lowerHysteresisDelta: 2))

        // 1. Below limit while plugged in -> Charging allowed
        let s1 = engine.update(currentSoC: 84, isPluggedIn: true)
        #expect(s1.mode == .charging)
        #expect(!mockHW.chargingInhibited)
        #expect(mockHW.writeCount == 0)

        // 2. Reaches limit (85%) -> Inhibits charging (1 write)
        let s2 = engine.update(currentSoC: 85, isPluggedIn: true)
        #expect(s2.mode == .inhibited)
        #expect(mockHW.chargingInhibited)
        #expect(mockHW.writeCount == 1)

        // 3. Stays at 84% (within hysteresis band) -> Still inhibited, NO redundant SMC write
        let s3 = engine.update(currentSoC: 84, isPluggedIn: true)
        #expect(s3.mode == .inhibited)
        #expect(mockHW.chargingInhibited)
        #expect(mockHW.writeCount == 1) // write count must NOT increase

        // 4. Drops to 83% (resume threshold: 85 - 2 = 83) -> Re-enables charging (1 write)
        let s4 = engine.update(currentSoC: 83, isPluggedIn: true)
        #expect(s4.mode == .charging)
        #expect(!mockHW.chargingInhibited)
        #expect(mockHW.writeCount == 2)
    }

    @Test func disabledConfigReEnablesCharging() {
        let mockHW = MockBatteryHardware()
        mockHW.chargingInhibited = true
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: false, limitPercentage: 85))

        let status = engine.update(currentSoC: 85, isPluggedIn: true)
        #expect(status.mode == .charging)
        #expect(!mockHW.chargingInhibited)
    }

    @Test func intelMacReceivesCustomTargetLimit() {
        let mockHW = MockBatteryHardware()
        mockHW.isAppleSilicon = false
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 90))

        _ = engine.update(currentSoC: 90, isPluggedIn: true)
        #expect(mockHW.appliedLimit == 90)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'`
Expected: FAIL (Cannot find `BatteryControlEngine` in scope)

- [ ] **Step 3: Implement BatteryControlHardware and BatteryControlEngine**

Create `WattlyFanDaemon/BatteryControlHardware.swift`:
```swift
import Foundation

public protocol BatteryControlHardwareProtocol: Sendable {
    var isAppleSilicon: Bool { get }
    func setChargingInhibited(_ inhibited: Bool, targetLimit: Int) -> Bool
}

public final class SMCBatteryControlHardware: BatteryControlHardwareProtocol, @unchecked Sendable {
    private let smc: SMCControlConnection

    public var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    public init(smc: SMCControlConnection) {
        self.smc = smc
    }

    public func setChargingInhibited(_ inhibited: Bool, targetLimit: Int) -> Bool {
        if isAppleSilicon {
            // Apple Silicon: CH0B = 0x02 (disable charging/inhibit), 0x00 (enable charging)
            let val: UInt8 = inhibited ? 0x02 : 0x00
            guard let reply = smc.write("CH0B", bytes: [val]), reply.kernel == KERN_SUCCESS else {
                return false
            }
            return true
        } else {
            // Intel Mac: BCLM = target percentage (e.g. 85) when inhibited, 100 when normal
            let limitByte = UInt8(clamping: inhibited ? targetLimit : 100)
            guard let reply = smc.write("BCLM", bytes: [limitByte]), reply.kernel == KERN_SUCCESS else {
                return false
            }
            return true
        }
    }
}
```

Create `FanControlShared/BatteryControlEngine.swift`:
```swift
import Foundation

public final class BatteryControlEngine: @unchecked Sendable {
    private let hardware: BatteryControlHardwareProtocol
    private var config: BatteryControlConfiguration
    private var isCurrentlyInhibited: Bool = false
    private var lastTargetLimit: Int = 100

    public init(hardware: BatteryControlHardwareProtocol, initialConfig: BatteryControlConfiguration = .init()) {
        self.hardware = hardware
        self.config = initialConfig
    }

    public func configure(_ newConfig: BatteryControlConfiguration) {
        self.config = newConfig
    }

    public func update(currentSoC: Int, isPluggedIn: Bool) -> BatteryControlServiceStatus {
        guard config.enabled && isPluggedIn else {
            if isCurrentlyInhibited {
                _ = hardware.setChargingInhibited(false, targetLimit: 100)
                isCurrentlyInhibited = false
            }
            return BatteryControlServiceStatus(
                mode: .charging,
                currentPercentage: currentSoC,
                isPowerAdapterConnected: isPluggedIn,
                detail: config.enabled ? "배터리 전원으로 구동 중" : "충전 제한 비활성화됨",
                updatedAt: Date().timeIntervalSince1970
            )
        }

        let target = config.clampedLimitPercentage
        let resume = config.resumePercentage

        if isCurrentlyInhibited {
            if currentSoC <= resume {
                // Resume charging
                _ = hardware.setChargingInhibited(false, targetLimit: 100)
                isCurrentlyInhibited = false
            }
        } else {
            if currentSoC >= target {
                // Inhibit charging (AC passthrough)
                _ = hardware.setChargingInhibited(true, targetLimit: target)
                isCurrentlyInhibited = true
                lastTargetLimit = target
            }
        }

        let mode: BatteryControlServiceMode = isCurrentlyInhibited ? .inhibited : .charging
        let detail = isCurrentlyInhibited
            ? "충전 제한 \(target)% 도달 (전원 어댑터 바이패스 구동)"
            : "목표치(\(target)%)까지 충전 중"

        return BatteryControlServiceStatus(
            mode: mode,
            currentPercentage: currentSoC,
            isPowerAdapterConnected: isPluggedIn,
            detail: detail,
            updatedAt: Date().timeIntervalSince1970
        )
    }

    public func release() {
        if isCurrentlyInhibited {
            _ = hardware.setChargingInhibited(false, targetLimit: 100)
            isCurrentlyInhibited = false
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add FanControlShared/BatteryControlEngine.swift WattlyFanDaemon/BatteryControlHardware.swift WattlyTests/BatteryControlEngineTests.swift
git commit -m "feat(battery): implement battery control hardware and hysteresis engine"
```

---

### Task 3: Daemon XPC Integration & Power Sampling

**Files:**
- Modify: `FanControlShared/FanControlProtocol.swift`
- Modify: `WattlyFanDaemon/FanControlDaemon.swift`
- Modify: `WattlyFanDaemon/main.swift`

**Interfaces:**
- Updates `FanControlXPCService` protocol:
  - `func configureBattery(_ data: Data, withReply reply: @escaping (Data?, NSError?) -> Void)`
  - `func batteryStatus(withReply reply: @escaping (Data?, NSError?) -> Void)`
- In `FanControlDaemon`: instantiates `BatteryControlEngine`, samples `IOPSCopyPowerSourcesInfo` for battery percentage and external power connected state, handles system wake notifications.

- [ ] **Step 1: Extend FanControlProtocol.swift**

```swift
@objc(FanControlXPCService)
protocol FanControlXPCService {
    func configure(_ data: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func heartbeat(withReply reply: @escaping (Data?, NSError?) -> Void)
    func release(_ data: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func status(withReply reply: @escaping (Data?, NSError?) -> Void)
    func configureBattery(_ data: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func batteryStatus(withReply reply: @escaping (Data?, NSError?) -> Void)
}
```

- [ ] **Step 2: Update FanControlDaemon.swift to coordinate BatteryControlEngine**

In `WattlyFanDaemon/FanControlDaemon.swift`:
```swift
// Add property:
private let batteryEngine: BatteryControlEngine
private var lastBatteryGeneration: UInt64 = 0
private var latestBatteryStatus: BatteryControlServiceStatus

// In init(allowedUID:hardware:batteryHardware:):
self.batteryEngine = BatteryControlEngine(hardware: batteryHardware)
self.latestBatteryStatus = BatteryControlServiceStatus(
    mode: .unavailable,
    currentPercentage: 0,
    isPowerAdapterConnected: false,
    detail: "초기화 중",
    updatedAt: 0
)

// Implement XPC methods:
func configureBattery(_ data: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
    let reply = Reply(reply)
    queue.async { [weak self] in
        guard let self else { return }
        do {
            let request = try BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
            guard request.generation >= lastBatteryGeneration else {
                reply.send((try BatteryControlCodec.encode(latestBatteryStatus), nil))
                return
            }
            lastBatteryGeneration = request.generation
            batteryEngine.configure(request.configuration)
            sampleBatteryAndEvaluate()
            reply.send((try BatteryControlCodec.encode(latestBatteryStatus), nil))
        } catch {
            reply.send((nil, error as NSError))
        }
    }
}

func batteryStatus(withReply reply: @escaping (Data?, NSError?) -> Void) {
    let reply = Reply(reply)
    queue.async { [weak self] in
        guard let self else { return }
        sampleBatteryAndEvaluate()
        do {
            reply.send((try BatteryControlCodec.encode(latestBatteryStatus), nil))
        } catch {
            reply.send((nil, error as NSError))
        }
    }
}

// In tick / timer event handler & wake observer:
private func sampleBatteryAndEvaluate() {
    let (soc, plugged) = readPowerSourceState()
    latestBatteryStatus = batteryEngine.update(currentSoC: soc, isPluggedIn: plugged)
}

private func readPowerSourceState() -> (soc: Int, plugged: Bool) {
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
        return (0, false)
    }
    for source in list {
        guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else { continue }
        let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let isPlugged = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        return (current, isPlugged)
    }
    return (0, false)
}

// In observeSleep():
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification,
    object: nil,
    queue: .main
) { [weak self] _ in
    self?.queue.async {
        self?.sampleBatteryAndEvaluate()
    }
}
```

- [ ] **Step 3: Update main.swift to inject SMCBatteryControlHardware**

In `WattlyFanDaemon/main.swift`:
```swift
guard let smc = SMCControlConnection() else {
    fputs("Unable to open SMC control connection\n", stderr)
    exit(69)
}
let fanHW = SMCFanControlHardware(connection: smc)
let batteryHW = SMCBatteryControlHardware(smc: smc)
let daemon = FanControlDaemon(allowedUID: uid_t(uid), fanHardware: fanHW, batteryHardware: batteryHW)
daemon.run()
RunLoop.main.run()
```

- [ ] **Step 4: Run test to verify build and test passes**

Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add FanControlShared/FanControlProtocol.swift WattlyFanDaemon/FanControlDaemon.swift WattlyFanDaemon/main.swift
git commit -m "feat(battery): integrate battery engine and power sampling into daemon"
```

---

### Task 4: App-Side Battery Control Client & Bridge

**Files:**
- Create: `Wattly/Control/BatteryControlClient.swift`
- Create: `Wattly/Views/BatteryControlBridge.swift`
- Modify: `Wattly/Core/StorageKey.swift`
- Modify: `Wattly/Core/Defaults.swift`
- Test: `WattlyTests/BatteryControlClientTests.swift`

**Interfaces:**
- Produces:
  - `@Observable @MainActor final class BatteryControlClient`
  - `struct BatteryControlBridge: View`
  - Storage keys: `StorageKey.batteryLimitEnabled`, `StorageKey.batteryLimitPercentage`

- [ ] **Step 1: Write test for BatteryControlClient**

Create `WattlyTests/BatteryControlClientTests.swift`:
```swift
import Foundation
import Testing
@testable import Wattly

struct BatteryControlClientTests {
    @MainActor @Test func clientAppliesConfigurationAndUpdatesStatus() async {
        let expectedStatus = BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 85,
            isPowerAdapterConnected: true,
            detail: "85% 바이패스 구동 중",
            updatedAt: 1.0
        )
        let client = BatteryControlClient { request in
            switch request {
            case .configure:
                let data = try? BatteryControlCodec.encode(expectedStatus)
                return (data, nil)
            case .status:
                let data = try? BatteryControlCodec.encode(expectedStatus)
                return (data, nil)
            }
        }

        await client.apply(enabled: true, limitPercentage: 85)
        #expect(client.status.mode == .inhibited)
        #expect(client.status.currentPercentage == 85)
    }

    @MainActor @Test func clientInitialStateIsUnavailable() {
        let client = BatteryControlClient()
        #expect(client.status.mode == .unavailable)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'`
Expected: FAIL (Cannot find `BatteryControlClient`)

- [ ] **Step 3: Implement StorageKey, Defaults, BatteryControlClient, and BatteryControlBridge**

Add to `StorageKey.swift`:
```swift
static let batteryLimitEnabled = "batteryLimitEnabled"
static let batteryLimitPercentage = "batteryLimitPercentage"
```

Add to `Defaults.swift`:
```swift
static let batteryLimitEnabled = false
static let batteryLimitPercentage = 80
```

Create `Wattly/Control/BatteryControlClient.swift`:
```swift
import Foundation
import Observation
import AppKit

@MainActor
@Observable public final class BatteryControlClient {
    public enum BatteryControlClientRequest: Sendable {
        case configure(Data)
        case status
    }

    public typealias RequestHandler = @Sendable (BatteryControlClientRequest) async -> (Data?, NSError?)

    private let requestHandler: RequestHandler
    public private(set) var status = BatteryControlServiceStatus(
        mode: .unavailable,
        currentPercentage: 0,
        isPowerAdapterConnected: false,
        detail: "도우미에 연결되지 않음",
        updatedAt: 0
    )
    public private(set) var isInstallingHelper = false
    private var commandGeneration = UInt64(Date().timeIntervalSince1970 * 1_000_000)

    public init(requestHandler: RequestHandler? = nil) {
        self.requestHandler = requestHandler ?? { req in
            switch req {
            case .configure(let data):
                return await Self.sendXPC { svc, reply in svc.configureBattery(data, withReply: reply) }
            case .status:
                return await Self.sendXPC { svc, reply in svc.batteryStatus(withReply: reply) }
            }
        }
    }

    public func apply(enabled: Bool, limitPercentage: Int) async {
        commandGeneration += 1
        let config = BatteryControlConfiguration(enabled: enabled, limitPercentage: limitPercentage)
        let request = BatteryControlConfigurationRequest(configuration: config, generation: commandGeneration)
        guard let data = try? BatteryControlCodec.encode(request) else { return }

        let (replyData, _) = await requestHandler(.configure(data))
        if let replyData, let decoded = try? BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: replyData) {
            self.status = decoded
        }
    }

    public func refreshStatus() async {
        let (replyData, _) = await requestHandler(.status)
        if let replyData, let decoded = try? BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: replyData) {
            self.status = decoded
        }
    }

    public func installHelper() async throws {
        isInstallingHelper = true
        defer { isInstallingHelper = false }
        try await FanHelperInstaller.install()
        await refreshStatus()
    }

    private static func sendXPC(_ block: @escaping (FanControlXPCService, @escaping (Data?, NSError?) -> Void) -> Void) async -> (Data?, NSError?) {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: FanControlXPC.machService)
            connection.remoteObjectInterface = NSXPCInterface(with: FanControlXPCService.self)
            connection.resume()
            guard let service = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(returning: (nil, error as NSError))
            }) as? FanControlXPCService else {
                continuation.resume(returning: (nil, NSError(domain: "Wattly", code: 1)))
                return
            }
            block(service) { data, error in
                connection.invalidate()
                continuation.resume(returning: (data, error))
            }
        }
    }
}
```

Create `Wattly/Views/BatteryControlBridge.swift`:
```swift
import SwiftUI
import AppKit

struct BatteryControlBridge: View {
    let client: BatteryControlClient

    @AppStorage(StorageKey.batteryLimitEnabled) private var enabled = Defaults.batteryLimitEnabled
    @AppStorage(StorageKey.batteryLimitPercentage) private var limit = Defaults.batteryLimitPercentage

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task {
                await client.apply(enabled: enabled, limitPercentage: limit)
            }
            .onChange(of: enabled) { _, val in
                Task { await client.apply(enabled: val, limitPercentage: limit) }
            }
            .onChange(of: limit) { _, val in
                Task { await client.apply(enabled: enabled, limitPercentage: val) }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                Task { await client.apply(enabled: enabled, limitPercentage: limit) }
            }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Control/BatteryControlClient.swift Wattly/Views/BatteryControlBridge.swift Wattly/Core/StorageKey.swift Wattly/Core/Defaults.swift WattlyTests/BatteryControlClientTests.swift
git commit -m "feat(battery): add battery control client, preferences, and background bridge"
```

---

### Task 5: Settings UI & User Guidance

**Files:**
- Create: `Wattly/Views/Settings/SettingsBatterySection.swift`
- Modify: `Wattly/Views/SettingsView.swift`
- Modify: `Wattly/App/WattlyApp.swift`

**Interfaces:**
- SwiftUI Section with:
  - Toggle: "배터리 충전 제한 (수명 보호)"
  - Limit percentage selector: Segmented buttons (80%, 85%, 90%, 95%)
  - Status badge: "바이패스 구동 중(충전 멈춤)", "충전 중", "도우미 미설치"
  - In-app helper install trigger
  - Advisory callout: macOS '최적화된 배터리 충전' 옵션 끄기 권장

- [ ] **Step 1: Implement SettingsBatterySection.swift**

Create `Wattly/Views/Settings/SettingsBatterySection.swift`:
```swift
import SwiftUI

struct SettingsBatterySection: View {
    @Environment(\.tokens) private var t
    let batteryControl: BatteryControlClient

    @AppStorage(StorageKey.batteryLimitEnabled) private var batteryLimitEnabled = Defaults.batteryLimitEnabled
    @AppStorage(StorageKey.batteryLimitPercentage) private var batteryLimitPercentage = Defaults.batteryLimitPercentage
    @State private var isInstallFailedAlertPresented = false
    @State private var installErrorMessage = ""

    private let presetLimits = [80, 85, 90, 95]

    var body: some View {
        SettingsSection(title: "배터리 충전 제어") {
            SettingsCard {
                SettingsToggleRow(isOn: $batteryLimitEnabled, divider: batteryLimitEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        SettingsRowTitle("배터리 충전 제한")
                        Text("설정한 한도에 도달하면 충전을 멈추고 전원 어댑터로만 작동하여 배터리 수명을 보호합니다.")
                            .font(WattlyFont.at(10.5, weight: .regular))
                            .foregroundStyle(t.faint)
                    }
                }

                if batteryLimitEnabled {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("최대 충전 한도")
                                .font(WattlyFont.at(12, weight: .medium))
                                .foregroundStyle(t.text)
                            Spacer()
                            Text("\(batteryLimitPercentage)%")
                                .font(WattlyFont.at(12, weight: .bold))
                                .foregroundStyle(t.text)
                        }

                        WattlySegment(
                            selection: Binding(
                                get: { batteryLimitPercentage },
                                set: { batteryLimitPercentage = $0 }
                            ),
                            options: presetLimits.map { ($0, "\($0)%") },
                            pillVPadding: 6
                        )

                        // Live status indicator
                        HStack(spacing: 8) {
                            Circle()
                                .fill(statusDotColor)
                                .frame(width: 7, height: 7)
                            Text(batteryControl.status.detail)
                                .font(WattlyFont.at(11, weight: .regular))
                                .foregroundStyle(t.faint)
                            Spacer()
                            if batteryControl.status.mode == .unavailable {
                                Button("도우미 설치") {
                                    Task {
                                        do {
                                            try await batteryControl.installHelper()
                                        } catch {
                                            installErrorMessage = error.localizedDescription
                                            isInstallFailedAlertPresented = true
                                        }
                                    }
                                }
                                .font(WattlyFont.at(11, weight: .medium))
                            }
                        }
                        .padding(.vertical, 4)

                        // macOS Optimized Battery Charging conflict advisory
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(Tokens.statusOrange)
                            Text("원활한 동작을 위해 시스템 설정 > 배터리의 '최적화된 배터리 충전'을 꺼두는 것을 권장합니다.")
                                .font(WattlyFont.at(10.5, weight: .regular))
                                .foregroundStyle(t.faint)
                        }
                    }
                    .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
                }
            }
        }
        .alert("도우미 설치 실패", isPresented: $isInstallFailedAlertPresented) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(installErrorMessage)
        }
    }

    private var statusDotColor: Color {
        switch batteryControl.status.mode {
        case .inhibited: return Tokens.statusOrange
        case .charging: return Tokens.statusGreen
        case .unavailable, .unsupported: return Tokens.statusRed
        }
    }
}
```

- [ ] **Step 2: Embed SettingsBatterySection in SettingsView.swift and mount BatteryControlBridge in WattlyApp.swift**

In `SettingsView.swift`:
- Pass `batteryControl: BatteryControlClient` into `SettingsView`.
- In `advancedGroup` (or `behaviorGroup`), if `monitor.isPresent(.battery)` is true, display `SettingsBatterySection(batteryControl: batteryControl)`.

In `WattlyApp.swift`:
- Instantiate `let batteryControl = BatteryControlClient()` and mount `BatteryControlBridge(client: batteryControl)` onto `MenuBarLabel`.

- [ ] **Step 3: Run full suite of tests and build check**

Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add Wattly/Views/Settings/SettingsBatterySection.swift Wattly/Views/SettingsView.swift Wattly/App/WattlyApp.swift
git commit -m "feat(battery): add battery limit settings UI and bridge to app lifecycle"
```

---

## Verification Plan

### Automated Tests
- `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'`
  - `BatteryControlProtocolTests`: JSON codability and percentage clamping.
  - `BatteryControlEngineTests`: State machine transitions, hysteresis buffer, Intel BCLM support, and single-write transition guarantee.
  - `BatteryControlClientTests`: XPC request handling and status observation.

### Manual Verification
1. Open Wattly Settings -> Go to 배터리 충전 제어.
2. Toggle "배터리 충전 제한" On and select **85%**.
3. Plug in MagSafe / USB-C charger when battery is below 85%:
   - Verify battery charges normally until 85%.
   - At 85%, verify mode changes to "충전 제한 85% 도달 (전원 어댑터 바이패스 구동)", wattage reads AC power passthrough, and battery stops charging.
4. Let battery slightly drop to 84%:
   - Verify it stays in bypass mode without triggering SMC writes or CPU spikes.
5. Put MacBook to Sleep and Wake up:
   - Verify battery limit state is restored immediately upon wake.
6. Check `top` or Activity Monitor for `PerfPowerServices` CPU usage (must stay < 1%).
