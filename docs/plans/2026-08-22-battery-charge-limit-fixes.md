# Battery Charge Limit — Review Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the 14 defects found reviewing `feat/battery-charge-limit`, so that the charge limit is actually enforced, honestly reported, survives sleep and helper restarts, and stops polling IOKit twice a second.

**Architecture:** Push every decision that can be pure into `FanControlShared` (`BatteryControlKeys`, `BatteryControlPolicy`, `BatteryControlConfiguration.normalized`) because the `WattlyFanDaemon` target has no test host — the daemon and hardware layers become thin executors of tested tables and predicates. The engine stops assuming SMC writes succeed: a failed write leaves the state machine unchanged, which turns the existing "write only on transition" loop into a free retry. The app grows the two loops the fan path already has — an error-surfacing `send` and a periodic reconcile — so a helper that restarts empty is repaired without a user action.

**Tech Stack:** Swift 6, Swift Testing (`import Testing`), IOKit (`AppleSMC`, `IOPSCopyPowerSourcesInfo`), XPC (`NSXPCConnection`), SwiftUI, `@Observable`, xcodegen.

## Global Constraints

- Never poll or write SMC keys continuously in a loop; only write SMC registers when transitioning state, to prevent `PerfPowerServices` CPU spikes and `PowerLog` database bloat.
- Support both Apple Silicon (`CH0B`/`CH0C` registers 0x02/0x00) and Intel Macs (`BCLM` percentage register).
- Keep the 2% hysteresis buffer: target 85% stops charging at `>= 85`, resumes at `<= 83`.
- Must keep sharing the existing root daemon (`WattlyFanDaemon`) and its `SMCControlConnection` — no second helper, no second admin authentication.
- All new user-facing strings are Korean, matching the existing `detail` strings.
- `WattlyFanDaemon` and its files (`FanControlDaemon.swift`, `BatteryControlHardware.swift`, `main.swift`) are **not** reachable from `WattlyTests` (see `project.yml:87-93` — the test target depends on `Wattly` only). Any logic that needs a unit test must live in `FanControlShared`.
- `BatteryControlServiceStatus` is decoded by app builds talking to an **older installed helper**. New fields must be `Optional` so the synthesized `decodeIfPresent` keeps old payloads decodable.
- A failed SMC write may be retried at most `BatteryControlEngine.maxConsecutiveWriteFailures` (3) consecutive times; past that the engine must stop writing until `configure` is called again.
- Full gate for every task: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'` must stay green (baseline: 537 tests / 52 suites).

## Out of Scope

- **Review finding #5** (the daemon's `NSWorkspace` sleep/wake observers almost certainly never fire in a system-context LaunchDaemon; the correct API is `IORegisterForSystemPower`). Converting the daemon's sleep/wake path would also change the **fan** release-on-sleep path, which is out of this branch's blast radius, so it remains out of scope. The daemon's own wake observer is not reliably delivered in the system domain, so the re-assert that repairs a register cleared during sleep is driven instead by the **app's** wake notification through `configureBattery` (see the final whole-branch review fix).
- Menu-bar / popover surfacing of the charge-limit state.
- Changing the product behaviour that the limit **persists while Wattly is not running** (there is deliberately no heartbeat deadman for battery, unlike fans).

---

## File Structure

**Create:**
- `FanControlShared/BatteryControlKeys.swift` — the SMC register table for a charge-limit transition. Pure, so the CH0B/CH0C/BCLM choice is testable outside the daemon target.
- `FanControlShared/BatteryControlPolicy.swift` — pure predicates for the app: "does the helper still hold my limit?", "does turning this on need the installer?", plus the reconcile cadence constant. Mirrors `FanControlPolicy`.
- `Wattly/Control/PrivilegedHelperInstallSession.swift` — the accessory-app window-survival dance around `FanHelperInstaller.install()`, extracted from `FanControlClient.installAndEngage` so both clients share one copy.
- `WattlyTests/BatteryControlKeysTests.swift`
- `WattlyTests/BatteryControlPolicyTests.swift`

**Modify:**
- `FanControlShared/BatteryControlProtocol.swift` — `normalized` on the config; `appliedLimitPercentage` on the status.
- `FanControlShared/BatteryControlEngine.swift` — honour write results, `.unsupported` + retry, normalize on configure, expose `needsSampling`, publish the applied limit.
- `WattlyFanDaemon/BatteryControlHardware.swift` — execute the key table instead of branching inline.
- `WattlyFanDaemon/FanControlDaemon.swift` — split sleep from termination, gate + slow battery sampling, hold the last power reading, tighten the generation guard.
- `Wattly/Control/BatteryControlClient.swift` — surface XPC errors, add `reconcile` and `installAndApply`, drop the bare `installHelper`.
- `Wattly/Control/FanControlClient.swift` — `installAndEngage` delegates to the shared install session (behaviour unchanged).
- `Wattly/Views/BatteryControlBridge.swift` — periodic reconcile loop.
- `Wattly/Views/Settings/SettingsBatterySection.swift` — probe-then-install-then-apply flow, live status polling.
- `Wattly/Views/SettingsView.swift` — drop the fabricating default parameter.
- `Wattly/Core/AppUninstaller.swift` — release the limit before the helper is removed.
- `WattlyTests/BatteryControlEngineTests.swift`, `WattlyTests/BatteryControlProtocolTests.swift`, `WattlyTests/BatteryControlClientTests.swift`, `WattlyTests/AppUninstallerTests.swift`.

---

## Task 1: Config normalization and applied-limit reporting

Closes review finding **#9** (the synthesized `Codable` initializer bypasses the memberwise clamp, so a root daemon consumes unvalidated XPC input) and lays the field that **#6**'s reconcile needs.

**Files:**
- Modify: `FanControlShared/BatteryControlProtocol.swift:3-21` (config), `:38-59` (status)
- Test: `WattlyTests/BatteryControlProtocolTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `BatteryControlConfiguration.normalized -> BatteryControlConfiguration`
  - `BatteryControlServiceStatus.appliedLimitPercentage: Int?` and the new trailing initializer parameter `appliedLimitPercentage: Int? = nil`

- [ ] **Step 1: Write the failing tests**

Append to `WattlyTests/BatteryControlProtocolTests.swift`, inside `struct BatteryControlProtocolTests`:

```swift
    @Test func hostileDecodedConfigurationIsNormalizedAndSafeUnnormalized() throws {
        // The synthesized init(from:) bypasses the memberwise initializer, so this is exactly
        // what the root daemon receives over XPC.
        let hostile = Data("""
        {"enabled":true,"limitPercentage":999,"lowerHysteresisDelta":900}
        """.utf8)
        let decoded = try BatteryControlCodec.decode(BatteryControlConfiguration.self, from: hostile)
        #expect(decoded.limitPercentage == 999)   // raw decode is untouched

        let safe = decoded.normalized
        #expect(safe.limitPercentage == 100)
        #expect(safe.lowerHysteresisDelta == 5)
        #expect(safe.resumePercentage == 95)

        // Even without normalizing, the derived values must stay inside their range.
        #expect(decoded.clampedLimitPercentage == 100)
        #expect(decoded.resumePercentage == 95)
    }

    @Test func normalizationLeavesValidValuesAlone() {
        let config = BatteryControlConfiguration(enabled: true, limitPercentage: 85, lowerHysteresisDelta: 2)
        #expect(config.normalized == config)
    }

    @Test func statusFromOlderHelperDecodesWithoutAppliedLimit() throws {
        let legacy = Data("""
        {"mode":"charging","currentPercentage":70,"isPowerAdapterConnected":true,"detail":"충전 중","updatedAt":1.0}
        """.utf8)
        let decoded = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: legacy)
        #expect(decoded.appliedLimitPercentage == nil)
        #expect(decoded.mode == .charging)
        #expect(decoded.currentPercentage == 70)
    }

    @Test func statusRoundTripsAppliedLimit() throws {
        let status = BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 85,
            isPowerAdapterConnected: true,
            detail: "충전 제한 85% 도달 (전원 어댑터 바이패스 구동)",
            updatedAt: 1000.0,
            appliedLimitPercentage: 85
        )
        let decoded = try BatteryControlCodec.decode(
            BatteryControlServiceStatus.self,
            from: try BatteryControlCodec.encode(status)
        )
        #expect(decoded == status)
        #expect(decoded.appliedLimitPercentage == 85)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlProtocolTests 2>&1 | tail -30
```

Expected: compile failure — `value of type 'BatteryControlConfiguration' has no member 'normalized'` and `extra argument 'appliedLimitPercentage' in call`.

- [ ] **Step 3: Implement**

In `FanControlShared/BatteryControlProtocol.swift`, replace the whole `BatteryControlConfiguration` struct with:

```swift
public struct BatteryControlConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var limitPercentage: Int
    public var lowerHysteresisDelta: Int

    public init(enabled: Bool = false, limitPercentage: Int = 80, lowerHysteresisDelta: Int = 2) {
        self.enabled = enabled
        self.limitPercentage = limitPercentage
        self.lowerHysteresisDelta = lowerHysteresisDelta
    }

    /// Range-clamped copy. Configurations reach the root daemon through the synthesized
    /// `init(from:)`, which never runs the memberwise initializer — so clamping has to be an
    /// explicit step the daemon takes, not an initializer side effect.
    public var normalized: BatteryControlConfiguration {
        var copy = self
        copy.limitPercentage = Self.clampLimit(limitPercentage)
        copy.lowerHysteresisDelta = Self.clampDelta(lowerHysteresisDelta)
        return copy
    }

    public var clampedLimitPercentage: Int {
        Self.clampLimit(limitPercentage)
    }

    public var resumePercentage: Int {
        max(45, clampedLimitPercentage - Self.clampDelta(lowerHysteresisDelta))
    }

    private static func clampLimit(_ value: Int) -> Int { max(50, min(100, value)) }
    private static func clampDelta(_ value: Int) -> Int { max(1, min(5, value)) }
}
```

Then replace the whole `BatteryControlServiceStatus` struct with:

```swift
public struct BatteryControlServiceStatus: Codable, Equatable, Sendable {
    public var mode: BatteryControlServiceMode
    public var currentPercentage: Int
    public var isPowerAdapterConnected: Bool
    public var detail: String
    public var updatedAt: TimeInterval
    /// The limit the helper is enforcing right now, or `nil` when the limit is off. The app
    /// compares this against its own opt-in to notice a helper that restarted and came back with
    /// an empty configuration. Optional so a payload from an older installed helper still decodes.
    public var appliedLimitPercentage: Int?

    public init(
        mode: BatteryControlServiceMode,
        currentPercentage: Int,
        isPowerAdapterConnected: Bool,
        detail: String,
        updatedAt: TimeInterval,
        appliedLimitPercentage: Int? = nil
    ) {
        self.mode = mode
        self.currentPercentage = currentPercentage
        self.isPowerAdapterConnected = isPowerAdapterConnected
        self.detail = detail
        self.updatedAt = updatedAt
        self.appliedLimitPercentage = appliedLimitPercentage
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlProtocolTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 8 tests in `BatteryControlProtocolTests`.

- [ ] **Step 5: Commit**

```bash
git add FanControlShared/BatteryControlProtocol.swift WattlyTests/BatteryControlProtocolTests.swift && git commit -m "fix(battery): normalize XPC config and publish the applied limit"
```

---

## Task 2: SMC register table with CH0C, extracted from the daemon

Closes review finding **#15** (Apple Silicon models differ in whether `CH0B` or `CH0C` actually inhibits charging; known implementations write both). The table moves to `FanControlShared` because `WattlyFanDaemon` has no test host.

**Files:**
- Create: `FanControlShared/BatteryControlKeys.swift`
- Modify: `WattlyFanDaemon/BatteryControlHardware.swift:20-38`
- Test: `WattlyTests/BatteryControlKeysTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `BatteryControlKeyWrite(key: String, byte: UInt8, isRequired: Bool)`
  - `BatteryControlKeys.writes(inhibited: Bool, isAppleSilicon: Bool, targetLimit: Int) -> [BatteryControlKeyWrite]`

- [ ] **Step 1: Write the failing test**

Create `WattlyTests/BatteryControlKeysTests.swift`:

```swift
import Foundation
import Testing
@testable import Wattly

@Suite struct BatteryControlKeysTests {
    @Test func appleSiliconInhibitWritesBothChargerRegisters() {
        let writes = BatteryControlKeys.writes(inhibited: true, isAppleSilicon: true, targetLimit: 85)
        #expect(writes.count == 2)
        #expect(writes[0] == BatteryControlKeyWrite(key: "CH0B", byte: 0x02, isRequired: true))
        #expect(writes[1] == BatteryControlKeyWrite(key: "CH0C", byte: 0x02, isRequired: false))
    }

    @Test func appleSiliconReleaseRestoresBothChargerRegisters() {
        let writes = BatteryControlKeys.writes(inhibited: false, isAppleSilicon: true, targetLimit: 100)
        #expect(writes.map(\.key) == ["CH0B", "CH0C"])
        #expect(writes.allSatisfy { $0.byte == 0x00 })
    }

    @Test func onlyCH0BIsRequiredSoAModelWithoutCH0CStillCounts() {
        let writes = BatteryControlKeys.writes(inhibited: true, isAppleSilicon: true, targetLimit: 80)
        #expect(writes.filter(\.isRequired).map(\.key) == ["CH0B"])
    }

    @Test func intelWritesTheCeilingItself() {
        let inhibit = BatteryControlKeys.writes(inhibited: true, isAppleSilicon: false, targetLimit: 85)
        #expect(inhibit == [BatteryControlKeyWrite(key: "BCLM", byte: 85, isRequired: true)])

        let release = BatteryControlKeys.writes(inhibited: false, isAppleSilicon: false, targetLimit: 85)
        #expect(release == [BatteryControlKeyWrite(key: "BCLM", byte: 100, isRequired: true)])
    }

    @Test func intelCeilingIsClampedIntoAByte() {
        let writes = BatteryControlKeys.writes(inhibited: true, isAppleSilicon: false, targetLimit: 4000)
        #expect(writes[0].byte == 255)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlKeysTests 2>&1 | tail -20
```

Expected: compile failure — `cannot find 'BatteryControlKeys' in scope`.

- [ ] **Step 3: Implement the table**

Create `FanControlShared/BatteryControlKeys.swift`:

```swift
import Foundation

/// One SMC register write that a charge-limit transition needs.
public struct BatteryControlKeyWrite: Equatable, Sendable {
    public let key: String
    public let byte: UInt8
    /// `false` for a register only some models expose. A failed optional write must not fail the
    /// transition, or the engine would report `.unsupported` on hardware that actually works.
    public let isRequired: Bool

    public init(key: String, byte: UInt8, isRequired: Bool) {
        self.key = key
        self.byte = byte
        self.isRequired = isRequired
    }
}

/// Picks the SMC registers for a charge-limit transition. This lives in `FanControlShared` rather
/// than beside the hardware because the `WattlyFanDaemon` target has no test host — keeping the
/// register table here is what makes it verifiable at all.
public enum BatteryControlKeys {
    public static func writes(inhibited: Bool,
                              isAppleSilicon: Bool,
                              targetLimit: Int) -> [BatteryControlKeyWrite] {
        if isAppleSilicon {
            // Apple Silicon inhibits charging through the charger-control registers. Models differ
            // in which one they honour, so both are written; only CH0B decides success.
            let byte: UInt8 = inhibited ? 0x02 : 0x00
            return [
                BatteryControlKeyWrite(key: "CH0B", byte: byte, isRequired: true),
                BatteryControlKeyWrite(key: "CH0C", byte: byte, isRequired: false)
            ]
        }
        // Intel stores the ceiling itself: the target percentage while limiting, 100 when off.
        return [BatteryControlKeyWrite(key: "BCLM",
                                       byte: UInt8(clamping: inhibited ? targetLimit : 100),
                                       isRequired: true)]
    }
}
```

- [ ] **Step 4: Make the hardware execute the table**

Replace the body of `setChargingInhibited` in `WattlyFanDaemon/BatteryControlHardware.swift`:

```swift
    public func setChargingInhibited(_ inhibited: Bool, targetLimit: Int) -> Bool {
        var requiredWritesSucceeded = true
        for write in BatteryControlKeys.writes(inhibited: inhibited,
                                               isAppleSilicon: isAppleSilicon,
                                               targetLimit: targetLimit) {
            let reply = smc.write(write.key, bytes: [write.byte])
            let succeeded = reply?.kernel == KERN_SUCCESS && reply?.smcResult == 0
            // An absent optional register reports a non-zero SMC result; that is expected on the
            // models that only implement one of the two, so it must not fail the transition.
            if !succeeded && write.isRequired { requiredWritesSucceeded = false }
        }
        return requiredWritesSucceeded
    }
```

- [ ] **Step 5: Run tests to verify they pass and the daemon still builds**

```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlKeysTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 5 tests.

```bash
xcodebuild build -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **` (this is what compiles `WattlyFanDaemon`).

- [ ] **Step 6: Commit**

```bash
git add FanControlShared/BatteryControlKeys.swift WattlyFanDaemon/BatteryControlHardware.swift WattlyTests/BatteryControlKeysTests.swift && git commit -m "fix(battery): write CH0C alongside CH0B via a testable register table"
```

---

## Task 3: Engine honours SMC write failures and retries

Closes review finding **#3** — today `_ = hardware.setChargingInhibited(...)` discards the result and flips the state anyway, so a Mac that cannot inhibit charging still reports "충전 제한 85% 도달 (전원 어댑터 바이패스 구동)" while charging to 100%, and never retries. The fix needs almost no retry machinery: leaving the state unchanged on failure means the same transition branch is re-entered next tick. That retry is bounded at `maxConsecutiveWriteFailures` (3) so it cannot become the SMC write loop Global Constraint 1 forbids — recovery past the bound comes from `configure`, which the app's 60 s reconcile pass drives once the status reports a nil applied limit.

Also finishes **#9** (normalize on configure) and produces the `needsSampling` gate that Task 6 uses for **#7**.

**Files:**
- Modify: `FanControlShared/BatteryControlEngine.swift:7-83`
- Test: `WattlyTests/BatteryControlEngineTests.swift`

**Interfaces:**
- Consumes: `BatteryControlConfiguration.normalized`, `BatteryControlServiceStatus.appliedLimitPercentage` (Task 1).
- Produces: `BatteryControlEngine.needsSampling: Bool`.

- [ ] **Step 1: Make the mock count every call and support failure**

The existing mock in `WattlyTests/BatteryControlEngineTests.swift:5-20` only increments `writeCount` when the state actually changes, which would hide a retry. Replace the whole `MockBatteryHardware` class with:

```swift
final class MockBatteryHardware: BatteryControlHardwareProtocol, @unchecked Sendable {
    var isAppleSilicon: Bool = true
    var chargingInhibited: Bool = false
    var appliedLimit: Int = 100
    /// Counts EVERY call, including a redundant one — a retry has to be visible to the tests.
    var writeCount: Int = 0
    var writeShouldFail: Bool = false

    func setChargingInhibited(_ inhibited: Bool, targetLimit: Int) -> Bool {
        writeCount += 1
        if writeShouldFail { return false }
        chargingInhibited = inhibited
        appliedLimit = targetLimit
        return true
    }
}
```

The four existing tests keep passing unchanged: the engine only calls the hardware on a transition, so counting calls and counting state changes agree on every path they exercise.

- [ ] **Step 2: Write the failing tests**

Append to `struct BatteryControlEngineTests` in the same file:

```swift
    @Test func failedInhibitWriteReportsUnsupportedAndRetriesUpToTheBound() {
        let mockHW = MockBatteryHardware()
        mockHW.writeShouldFail = true
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))

        let failed = engine.update(currentSoC: 85, isPluggedIn: true)
        #expect(failed.mode == .unsupported)
        #expect(failed.appliedLimitPercentage == nil)   // nothing is actually being enforced
        #expect(!mockHW.chargingInhibited)
        #expect(mockHW.writeCount == 1)

        // The state machine did not advance, so the same branch retries — but only up to the
        // bound, because the global constraint forbids writing SMC registers in a loop.
        for _ in 0..<5 { _ = engine.update(currentSoC: 85, isPluggedIn: true) }
        #expect(mockHW.writeCount == BatteryControlEngine.maxConsecutiveWriteFailures)
    }

    @Test func reconfiguringClearsTheFailureLatchAndLetsItTryAgain() {
        let mockHW = MockBatteryHardware()
        mockHW.writeShouldFail = true
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))
        for _ in 0..<5 { _ = engine.update(currentSoC: 85, isPluggedIn: true) }
        #expect(mockHW.writeCount == BatteryControlEngine.maxConsecutiveWriteFailures)

        // This is exactly what the app's 60 s reconcile does once it sees a nil applied limit.
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))
        mockHW.writeShouldFail = false
        let recovered = engine.update(currentSoC: 85, isPluggedIn: true)
        #expect(recovered.mode == .inhibited)
        #expect(recovered.appliedLimitPercentage == 85)
        #expect(mockHW.chargingInhibited)
    }

    @Test func failedReleaseWriteRetriesWithinTheBound() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))
        _ = engine.update(currentSoC: 85, isPluggedIn: true)
        #expect(mockHW.chargingInhibited)

        mockHW.writeShouldFail = true
        let failed = engine.update(currentSoC: 83, isPluggedIn: true)
        #expect(failed.mode == .unsupported)
        #expect(mockHW.chargingInhibited)   // still latched — the release did not take

        mockHW.writeShouldFail = false
        let recovered = engine.update(currentSoC: 83, isPluggedIn: true)
        #expect(recovered.mode == .charging)
        #expect(!mockHW.chargingInhibited)
    }

    @Test func releaseBypassesTheFailureLatchForDaemonShutdown() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))
        _ = engine.update(currentSoC: 85, isPluggedIn: true)
        #expect(mockHW.chargingInhibited)

        mockHW.writeShouldFail = true
        for _ in 0..<5 { _ = engine.update(currentSoC: 83, isPluggedIn: true) }
        #expect(mockHW.chargingInhibited)   // release kept failing, then the latch stopped trying

        // Shutdown must still try: leaving the register set would stop the Mac charging with no
        // helper left to ever clear it.
        mockHW.writeShouldFail = false
        engine.release()
        #expect(!mockHW.chargingInhibited)
    }

    @Test func statusCarriesTheLimitTheEngineIsEnforcing() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 90))
        #expect(engine.update(currentSoC: 70, isPluggedIn: true).appliedLimitPercentage == 90)

        engine.configure(BatteryControlConfiguration(enabled: false, limitPercentage: 90))
        #expect(engine.update(currentSoC: 70, isPluggedIn: true).appliedLimitPercentage == nil)
    }

    @Test func configureNormalizesHostileValues() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 999, lowerHysteresisDelta: 900))

        let status = engine.update(currentSoC: 100, isPluggedIn: true)
        #expect(status.appliedLimitPercentage == 100)
        #expect(status.mode == .inhibited)
    }

    @Test func needsSamplingIsFalseOnceIdleAndDisabled() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        #expect(engine.needsSampling)   // startup normalization has not run yet

        _ = engine.update(currentSoC: 70, isPluggedIn: true)
        #expect(!engine.needsSampling)  // disabled, hardware already normal — nothing to evaluate

        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 80))
        #expect(engine.needsSampling)
    }
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlEngineTests 2>&1 | tail -30
```

Expected: compile failure on `engine.needsSampling`, and (once that is stubbed) failures asserting `.unsupported` — the engine currently returns `.inhibited`.

- [ ] **Step 4: Implement**

Replace the whole body of `BatteryControlEngine` in `FanControlShared/BatteryControlEngine.swift` (keep the `BatteryControlHardwareProtocol` declaration above it untouched):

```swift
public final class BatteryControlEngine: @unchecked Sendable {
    /// Consecutive failed SMC writes before the engine stops trying. The global constraint forbids
    /// writing registers in a loop, and a machine that rejects the write would otherwise be written
    /// to on every tick forever. Recovery is deliberately slow rather than busy: `configure` clears
    /// the latch, and the app's reconcile pass re-pushes the configuration, backing its cadence off
    /// the longer the hardware keeps refusing.
    public static let maxConsecutiveWriteFailures = 3

    private let hardware: BatteryControlHardwareProtocol
    private var config: BatteryControlConfiguration
    private var isCurrentlyInhibited: Bool = false
    private var hasInitializedState: Bool = false
    private var lastWriteFailed: Bool = false
    private var consecutiveWriteFailures: Int = 0

    private var isWriteLatched: Bool {
        consecutiveWriteFailures >= Self.maxConsecutiveWriteFailures
    }

    public init(hardware: BatteryControlHardwareProtocol, initialConfig: BatteryControlConfiguration = .init()) {
        self.hardware = hardware
        self.config = initialConfig.normalized
    }

    /// True while the engine still has something a fresh power reading could change. With the
    /// limit off and the charger already back to normal there is nothing to evaluate, so the
    /// daemon can skip its IOPS snapshot entirely instead of copying one on every tick.
    public var needsSampling: Bool {
        config.enabled || isCurrentlyInhibited || !hasInitializedState
    }

    public func configure(_ newConfig: BatteryControlConfiguration) {
        let normalized = newConfig.normalized
        // A new configuration is the user — or the app's reconcile pass — asking again, so clear
        // the latch and let the next tick spend a fresh set of attempts.
        consecutiveWriteFailures = 0
        if config.enabled && !normalized.enabled && isCurrentlyInhibited {
            if attemptWrite(inhibited: false, targetLimit: 100) { isCurrentlyInhibited = false }
        }
        config = normalized
    }

    public func update(currentSoC: Int, isPluggedIn: Bool) -> BatteryControlServiceStatus {
        guard config.enabled && isPluggedIn else {
            if isCurrentlyInhibited || !hasInitializedState {
                if attemptWrite(inhibited: false, targetLimit: 100) { isCurrentlyInhibited = false }
            }
            hasInitializedState = true
            let detail: String
            if !config.enabled {
                detail = "충전 제한 비활성화됨"
            } else if lastWriteFailed {
                detail = "이 Mac에서 충전 제어를 적용하지 못했습니다"
            } else {
                detail = "배터리 전원으로 구동 중"
            }
            return status(currentSoC: currentSoC, isPluggedIn: isPluggedIn, detail: detail)
        }

        hasInitializedState = true
        let target = config.clampedLimitPercentage

        // Only a transition writes. A failed write deliberately leaves `isCurrentlyInhibited`
        // alone, so the very same branch is re-entered on the next tick — that IS the retry, and
        // it costs no extra state. `attemptWrite` is what stops it after the bound.
        if isCurrentlyInhibited {
            if currentSoC <= config.resumePercentage,
               attemptWrite(inhibited: false, targetLimit: 100) {
                isCurrentlyInhibited = false
            }
        } else if currentSoC >= target,
                  attemptWrite(inhibited: true, targetLimit: target) {
            isCurrentlyInhibited = true
        }

        let detail: String
        if lastWriteFailed {
            detail = "이 Mac에서 충전 제어를 적용하지 못했습니다"
        } else if isCurrentlyInhibited {
            detail = "충전 제한 \(target)% 도달 (전원 어댑터 바이패스 구동)"
        } else {
            detail = "목표치(\(target)%)까지 충전 중"
        }
        return status(currentSoC: currentSoC, isPluggedIn: isPluggedIn, detail: detail)
    }

    /// The last chance to hand the battery back before the daemon exits, so it bypasses the failure
    /// latch on purpose: leaving the register set would stop the Mac charging with no helper left
    /// to ever clear it.
    public func release() {
        guard isCurrentlyInhibited else { return }
        if hardware.setChargingInhibited(false, targetLimit: 100) {
            isCurrentlyInhibited = false
            consecutiveWriteFailures = 0
            lastWriteFailed = false
        }
    }

    /// Every routine hardware write goes through here, so the failure latch has exactly one home.
    @discardableResult
    private func attemptWrite(inhibited: Bool, targetLimit: Int) -> Bool {
        guard !isWriteLatched else { return false }
        if hardware.setChargingInhibited(inhibited, targetLimit: targetLimit) {
            consecutiveWriteFailures = 0
            lastWriteFailed = false
            return true
        }
        consecutiveWriteFailures += 1
        lastWriteFailed = true
        return false
    }

    private func status(currentSoC: Int, isPluggedIn: Bool, detail: String) -> BatteryControlServiceStatus {
        let mode: BatteryControlServiceMode
        if config.enabled && lastWriteFailed {
            // Only report unsupported for work the user actually asked for; a failed startup
            // normalization while the feature is off is not something to alarm them about.
            mode = .unsupported
        } else if isCurrentlyInhibited {
            mode = .inhibited
        } else {
            mode = .charging
        }
        return BatteryControlServiceStatus(
            mode: mode,
            currentPercentage: currentSoC,
            isPowerAdapterConnected: isPluggedIn,
            detail: detail,
            updatedAt: Date().timeIntervalSince1970,
            // Report the limit actually being enforced. A failed write means nothing is, and
            // reporting `nil` is what makes the app's reconcile pass re-push and clear the latch.
            appliedLimitPercentage: (config.enabled && !lastWriteFailed) ? config.clampedLimitPercentage : nil
        )
    }
}
```

Note: the old `lastTargetLimit` property is deleted — it was written and never read.

- [ ] **Step 5: Run tests to verify they pass**

```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlEngineTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 12 tests (5 original + 7 new).

- [ ] **Step 6: Commit**

```bash
git add FanControlShared/BatteryControlEngine.swift WattlyTests/BatteryControlEngineTests.swift && git commit -m "fix(battery): stop reporting success for failed SMC writes and retry them"
```

---

## Task 4: Pure reconcile and install-decision policy

The predicates Task 5 and Task 7 need, isolated so they are testable without XPC or SwiftUI. Mirrors `FanControlPolicy.shouldReapplyAfterMenuBarOpen`.

**Files:**
- Create: `FanControlShared/BatteryControlPolicy.swift`
- Test: `WattlyTests/BatteryControlPolicyTests.swift`

**Interfaces:**
- Consumes: `BatteryControlServiceStatus.appliedLimitPercentage` (Task 1).
- Produces:
  - `BatteryControlPolicy.reconcileInterval: Double`
  - `BatteryControlPolicy.shouldReapply(enabled: Bool, limitPercentage: Int, status: BatteryControlServiceStatus) -> Bool`
  - `BatteryControlPolicy.shouldRunInstaller(mode: BatteryControlServiceMode) -> Bool`

- [ ] **Step 1: Write the failing test**

Create `WattlyTests/BatteryControlPolicyTests.swift`:

```swift
import Foundation
import Testing
@testable import Wattly

@Suite struct BatteryControlPolicyTests {
    private func status(mode: BatteryControlServiceMode, applied: Int?) -> BatteryControlServiceStatus {
        BatteryControlServiceStatus(
            mode: mode,
            currentPercentage: 70,
            isPowerAdapterConnected: true,
            detail: "테스트",
            updatedAt: 0,
            appliedLimitPercentage: applied
        )
    }

    @Test func reapplyWhenHelperRestartedAndForgotTheLimit() {
        // A KeepAlive relaunch brings the helper back with an empty configuration.
        let forgotten = status(mode: .charging, applied: nil)
        #expect(BatteryControlPolicy.shouldReapply(enabled: true, limitPercentage: 85, status: forgotten))
    }

    @Test func reapplyWhenHelperHoldsADifferentLimit() {
        let stale = status(mode: .charging, applied: 80)
        #expect(BatteryControlPolicy.shouldReapply(enabled: true, limitPercentage: 85, status: stale))
    }

    @Test func doNotReapplyWhenHelperAlreadyAgrees() {
        #expect(!BatteryControlPolicy.shouldReapply(enabled: true, limitPercentage: 85,
                                                    status: status(mode: .charging, applied: 85)))
        #expect(!BatteryControlPolicy.shouldReapply(enabled: true, limitPercentage: 85,
                                                    status: status(mode: .inhibited, applied: 85)))
    }

    @Test func doNotReapplyWhenTheUserOptedOut() {
        #expect(!BatteryControlPolicy.shouldReapply(enabled: false, limitPercentage: 85,
                                                    status: status(mode: .charging, applied: nil)))
    }

    @Test func doNotReapplyIntoAnUnreachableHelper() {
        // Connecting or installing is the settings screen's job, not a background loop's.
        #expect(!BatteryControlPolicy.shouldReapply(enabled: true, limitPercentage: 85,
                                                    status: status(mode: .unavailable, applied: nil)))
    }

    @Test func reapplyEvenWhenTheHardwareRejectedTheWrite() {
        // `.unsupported` still means the helper is answering; re-pushing is how a transient
        // failure gets another chance.
        #expect(BatteryControlPolicy.shouldReapply(enabled: true, limitPercentage: 85,
                                                   status: status(mode: .unsupported, applied: nil)))
    }

    @Test func installerRunsOnlyWhenTheHelperIsUnreachable() {
        #expect(BatteryControlPolicy.shouldRunInstaller(mode: .unavailable))
        #expect(!BatteryControlPolicy.shouldRunInstaller(mode: .charging))
        #expect(!BatteryControlPolicy.shouldRunInstaller(mode: .inhibited))
        #expect(!BatteryControlPolicy.shouldRunInstaller(mode: .unsupported))
    }

    @Test func reconcileIntervalIsSlowEnoughToBeFree() {
        #expect(BatteryControlPolicy.reconcileInterval >= 60.0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlPolicyTests 2>&1 | tail -20
```

Expected: compile failure — `cannot find 'BatteryControlPolicy' in scope`.

- [ ] **Step 3: Implement**

Create `FanControlShared/BatteryControlPolicy.swift`:

```swift
import Foundation

/// Pure decisions for the battery charge limit, the counterpart to `FanControlPolicy`. Every
/// branch here is exercised by unit tests; the SwiftUI bridge and the settings screen only wire
/// them up.
public enum BatteryControlPolicy {
    /// How often the always-mounted bridge re-checks that the helper still holds the user's limit.
    /// The helper comes back from a `KeepAlive` relaunch, a `kickstart`, or a crash with an empty
    /// configuration, and nothing else would notice: `onChange` needs a user edit and the wake
    /// notification needs a sleep. One status round-trip a minute is the cost of never silently
    /// losing the limit.
    public static let reconcileInterval = 60.0

    /// True when the helper is reachable but is not enforcing the limit the user opted into.
    /// `.unavailable` is left alone on purpose — installing or connecting belongs to the settings
    /// screen, where the user can see an auth prompt, not to a background loop.
    public static func shouldReapply(enabled: Bool,
                                     limitPercentage: Int,
                                     status: BatteryControlServiceStatus) -> Bool {
        guard enabled, status.mode != .unavailable else { return false }
        return status.appliedLimitPercentage != limitPercentage
    }

    /// True when turning the opt-in on has to run the privileged installer. A helper that already
    /// answers is reused, so enabling the charge limit after fan control never asks for a second
    /// admin authentication.
    public static func shouldRunInstaller(mode: BatteryControlServiceMode) -> Bool {
        mode == .unavailable
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlPolicyTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add FanControlShared/BatteryControlPolicy.swift WattlyTests/BatteryControlPolicyTests.swift && git commit -m "feat(battery): add pure reconcile and installer-gate policy"
```

---

## Task 5: Client surfaces XPC errors, reconciles, and applies after install

Closes review findings **#2** (the `NSError` is discarded, so a dead helper leaves the UI reporting "충전 제한 85% 도달" forever and permanently hides the install button), **#1** (installing from the battery section never pushes the limit, so the helper stays at its disabled default while the toggle reads ON) and **#12** (the battery install path skips the accessory-app window-survival dance that `installAndEngage` documents at length).

The window dance is extracted rather than copied — two 40-line near-identical methods would be the third place that comment has to stay correct.

**Files:**
- Create: `Wattly/Control/PrivilegedHelperInstallSession.swift`
- Modify: `Wattly/Control/BatteryControlClient.swift:36-63`, `Wattly/Control/FanControlClient.swift:89-146`
- Test: `WattlyTests/BatteryControlClientTests.swift`

**Interfaces:**
- Consumes: `BatteryControlPolicy.shouldReapply` (Task 4), `BatteryControlServiceStatus.appliedLimitPercentage` (Task 1).
- Produces:
  - `PrivilegedHelperInstallSession.run(window: NSWindow?, postInstall: @MainActor () async -> Void) async -> Error?` (nil = success)
  - `BatteryControlClient.refreshStatus() async -> BatteryControlServiceStatus?` (was `-> Void`)
  - `BatteryControlClient.reconcile(enabled: Bool, limitPercentage: Int) async`
  - `BatteryControlClient.installAndApply(limitPercentage: Int, window: NSWindow?) async -> Error?`
  - `BatteryControlClient.installHelper()` is **removed**.

- [ ] **Step 1: Write the failing tests**

In `WattlyTests/BatteryControlClientTests.swift`, replace the existing `clientHandlesErrorGracefully` test — it only passes because the initial status is already `.unavailable`, so it never proved anything — and add the reconcile tests:

```swift
    @MainActor @Test func clientMarksItselfUnavailableAfterAGoodStatusGoesBad() async {
        let good = BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 85,
            isPowerAdapterConnected: true,
            detail: "충전 제한 85% 도달 (전원 어댑터 바이패스 구동)",
            updatedAt: 1.0,
            appliedLimitPercentage: 85
        )
        let failNow = FailureSwitch()
        let client = BatteryControlClient { _ in
            if await failNow.isOn {
                return (nil, NSError(domain: "WattlyTest", code: -1,
                                     userInfo: [NSLocalizedDescriptionKey: "도우미 연결 끊김"]))
            }
            return (try? BatteryControlCodec.encode(good), nil)
        }

        await client.apply(enabled: true, limitPercentage: 85)
        #expect(client.status.mode == .inhibited)

        await failNow.turnOn()
        await client.refreshStatus()
        #expect(client.status.mode == .unavailable)
        #expect(client.status.detail == "도우미 연결 끊김")
        #expect(client.status.appliedLimitPercentage == nil)
    }

    @MainActor @Test func clientMarksItselfUnavailableWhenTheReplyIsUndecodable() async {
        let client = BatteryControlClient { _ in (Data("not json".utf8), nil) }
        await client.refreshStatus()
        #expect(client.status.mode == .unavailable)
    }

    @MainActor @Test func reconcileRepushesTheLimitWhenTheHelperForgotIt() async {
        let forgetful = BatteryControlServiceStatus(
            mode: .charging,
            currentPercentage: 70,
            isPowerAdapterConnected: true,
            detail: "충전 제한 비활성화됨",
            updatedAt: 1.0,
            appliedLimitPercentage: nil
        )
        let recorder = RequestRecorder()
        let client = BatteryControlClient { request in
            await recorder.record(request)
            return (try? BatteryControlCodec.encode(forgetful), nil)
        }

        await client.reconcile(enabled: true, limitPercentage: 85)

        let kinds = await recorder.kinds
        #expect(kinds.count == 2)
        #expect(kinds.first == "status")
        #expect(kinds.last == "configure")
    }

    @MainActor @Test func reconcileIsSilentWhenTheHelperAlreadyAgrees() async {
        let agreeing = BatteryControlServiceStatus(
            mode: .charging,
            currentPercentage: 70,
            isPowerAdapterConnected: true,
            detail: "목표치(85%)까지 충전 중",
            updatedAt: 1.0,
            appliedLimitPercentage: 85
        )
        let recorder = RequestRecorder()
        let client = BatteryControlClient { request in
            await recorder.record(request)
            return (try? BatteryControlCodec.encode(agreeing), nil)
        }

        await client.reconcile(enabled: true, limitPercentage: 85)

        let kinds = await recorder.kinds
        #expect(kinds == ["status"])
    }
```

Add these two helpers at file scope in the same file, next to the existing `RequestReceiver`:

```swift
private actor FailureSwitch {
    var isOn = false
    func turnOn() { isOn = true }
}

private actor RequestRecorder {
    var kinds: [String] = []
    func record(_ request: BatteryControlClient.BatteryControlClientRequest) {
        switch request {
        case .configure: kinds.append("configure")
        case .status: kinds.append("status")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlClientTests 2>&1 | tail -30
```

Expected: compile failure on `client.reconcile`, and the unavailable tests failing with `.inhibited`/`.charging` because the current client never downgrades its status.

- [ ] **Step 3: Extract the install session**

Create `Wattly/Control/PrivilegedHelperInstallSession.swift`:

```swift
import AppKit

/// Runs the privileged-helper install while keeping a window alive across the admin-auth dialog.
///
/// Wattly is an accessory (LSUIElement) app, and the auth dialog deactivates it long enough for
/// macOS to destroy the Settings window — reopening it afterwards proved unreliable. So a regular
/// activation policy is held for the duration of the install (a regular app keeps its windows when
/// deactivated) and the window is re-fronted with `orderFrontRegardless` only — NOT `activate`,
/// which would steal keyboard focus from the password field. The menubar-only policy is restored
/// once the window is back up front.
///
/// Both the fan and the battery client drive this; it is one copy on purpose.
@MainActor
enum PrivilegedHelperInstallSession {
    /// Installs the helper, runs `postInstall` before handing the window back, and returns `nil` on
    /// success or the failure (including a cancelled auth prompt).
    static func run(window: NSWindow?, postInstall: @MainActor () async -> Void) async -> Error? {
        let priorPolicy = NSApp.activationPolicy()
        let raised = priorPolicy != .regular
        if raised { NSApp.setActivationPolicy(.regular) }

        // Keep the window visible UNDER the auth panel for the whole prompt + script run (~seconds)
        // so it does not sink behind other apps. `install()` runs its `osascript` off the main
        // thread, so the main actor is free to run this loop while we await it.
        let keepVisible = Task { @MainActor in
            while !Task.isCancelled {
                window?.orderFrontRegardless()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }

        var failure: Error?
        do {
            try await FanHelperInstaller.install()
        } catch {
            failure = error
        }
        keepVisible.cancel()

        // Re-raise the window the INSTANT the auth dialog is gone — before `postInstall`, which
        // connects to the just-started daemon over XPC and can stall for several seconds.
        raiseFront(window)
        if failure == nil { await postInstall() }

        // Drop the transient Dock icon, then re-front once more (restoring `.accessory` while
        // another app is active can sink the window), with retries to win any late focus steal.
        if raised { NSApp.setActivationPolicy(priorPolicy) }
        for _ in 0..<3 {
            raiseFront(window)
            try? await Task.sleep(for: .milliseconds(300))
        }
        return failure
    }

    private static func raiseFront(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
```

- [ ] **Step 4: Point the fan client at the shared session**

In `Wattly/Control/FanControlClient.swift`, replace the entire body of `installAndEngage(curve:window:)` (keep its doc comment, and delete the now-unused `private func raiseFront(_:)` below it):

```swift
    @discardableResult
    func installAndEngage(curve: FanCurve, window: NSWindow?) async -> Bool {
        isInstallingHelper = true
        defer { isInstallingHelper = false }
        let failure = await PrivilegedHelperInstallSession.run(window: window) {
            await self.apply(enabled: true, curve: curve)
        }
        return failure == nil
    }
```

This must be behaviour-identical: same policy hold, same 400 ms re-front loop, same post-install `apply`, same three 300 ms retries. The full suite in Step 7 is the regression gate.

- [ ] **Step 5: Rewrite the battery client's transport**

In `Wattly/Control/BatteryControlClient.swift`, replace `apply`, `refreshStatus`, and `installHelper` (lines 36-63) with:

```swift
    public func apply(enabled: Bool, limitPercentage: Int) async {
        commandGeneration &+= 1
        let config = BatteryControlConfiguration(enabled: enabled, limitPercentage: limitPercentage)
        let request = BatteryControlConfigurationRequest(configuration: config, generation: commandGeneration)
        guard let data = try? BatteryControlCodec.encode(request) else {
            updateUnavailable("충전 제한 설정을 인코딩할 수 없음")
            return
        }
        await send(.configure(data))
    }

    @discardableResult
    public func refreshStatus() async -> BatteryControlServiceStatus? {
        await send(.status)
    }

    /// Repairs a helper that restarted and lost its configuration. Reads the helper's state first,
    /// so a healthy helper costs one status call and no SMC traffic at all.
    public func reconcile(enabled: Bool, limitPercentage: Int) async {
        await refreshStatus()
        guard BatteryControlPolicy.shouldReapply(enabled: enabled,
                                                 limitPercentage: limitPercentage,
                                                 status: status) else { return }
        await apply(enabled: enabled, limitPercentage: limitPercentage)
    }

    /// Installs the privileged helper with one admin-auth prompt and immediately pushes the user's
    /// limit — without this the helper would sit at its disabled default while the toggle reads ON.
    /// Returns `nil` on success or the install failure.
    public func installAndApply(limitPercentage: Int, window: NSWindow?) async -> Error? {
        isInstallingHelper = true
        defer { isInstallingHelper = false }
        return await PrivilegedHelperInstallSession.run(window: window) {
            await self.apply(enabled: true, limitPercentage: limitPercentage)
        }
    }

    @discardableResult
    private func send(_ request: BatteryControlClientRequest) async -> BatteryControlServiceStatus? {
        let (replyData, error) = await requestHandler(request)
        guard error == nil,
              let replyData,
              let decoded = try? BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: replyData) else {
            updateUnavailable(error?.localizedDescription ?? "도우미 응답 오류")
            return nil
        }
        status = decoded
        return decoded
    }

    /// A dropped helper has to be visible: the settings screen gates its install button on
    /// `.unavailable`, so silently keeping the last good status would hide the only recovery
    /// action the user has.
    private func updateUnavailable(_ detail: String) {
        status = BatteryControlServiceStatus(
            mode: .unavailable,
            currentPercentage: status.currentPercentage,
            isPowerAdapterConnected: status.isPowerAdapterConnected,
            detail: detail,
            updatedAt: Date().timeIntervalSince1970,
            appliedLimitPercentage: nil
        )
    }
```

- [ ] **Step 6: Run the client tests**

```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlClientTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 7 tests.

- [ ] **Step 7: Run the whole suite to guard the fan refactor**

```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 | tail -8
```

Expected: `** TEST SUCCEEDED **` with no `FanControlClientTests` regressions.

- [ ] **Step 8: Commit**

```bash
git add Wattly/Control/PrivilegedHelperInstallSession.swift Wattly/Control/BatteryControlClient.swift Wattly/Control/FanControlClient.swift WattlyTests/BatteryControlClientTests.swift && git commit -m "fix(battery): surface XPC errors, reconcile, and apply the limit after install"
```

---

## Task 6: Daemon stops releasing on sleep and stops polling at 2 Hz

Closes review findings **#4** (sleep releases the charge limit, so an overnight sleep charges straight to 100% — the exact case the feature exists to prevent), **#7** (both the 0.5 s control timer and the 5 s watchdog call `sampleBatteryAndEvaluate()`, so a root daemon copies two IOPS snapshots per second forever, even with the feature off), **#10** (a failed power read returns `(0, false)`, which reads as "unplugged" and releases the limit — failing open), and **#14** (`generation >=` re-applies a replayed request).

**No unit tests exist for this task by construction:** `WattlyFanDaemon` is an executable target with no test host (`project.yml:71-85`). Every decision this task depends on — `needsSampling`, the register table, the reconcile predicate — is already covered by Tasks 2–4. The gate here is a clean build plus the manual on-device checklist at the bottom of this plan.

**Files:**
- Modify: `WattlyFanDaemon/FanControlDaemon.swift:55-62` (run), `:120-152` (XPC), `:153-171` (sampling), `:173-196` (timers), `:198-215` (sleep/wake), `:217-232` (signals), `:233-247` (release)

**Interfaces:**
- Consumes: `BatteryControlEngine.needsSampling` (Task 3).
- Produces: nothing new for other tasks.

- [ ] **Step 1: Split sleep from termination**

In `WattlyFanDaemon/FanControlDaemon.swift`, change the sleep observer inside `observeSleep()`:

```swift
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Fans MUST go back to automatic before sleep. The charge limit must NOT: dropping the
            // inhibit here is what lets an overnight sleep charge straight to 100 %, which is the
            // exact case this feature exists to prevent. The SMC register holds across sleep on its
            // own, and the app-side reconcile loop repairs it if anything does clear it.
            self?.releaseSynchronously(reason: "system sleep", releaseBattery: false)
        }
```

In `observeTerminationSignals()`, pass `releaseBattery: true`:

```swift
                if self?.releaseSynchronously(reason: "daemon terminated", releaseBattery: true) == true {
                    exit(0)
                }
```

And give `releaseSynchronously` the parameter:

```swift
    @discardableResult
    private func releaseSynchronously(reason: String, releaseBattery: Bool) -> Bool {
        queue.sync { [self] in
            if releaseBattery { batteryEngine.release() }
            engine.release(now: now(), reason: reason)
            let deadline = now() + FanControlPolicy.modeRetryDeadline
            while true {
                if engine.recoverAutomaticSynchronously(now: now()) { return true }
                guard now() < deadline else { return false }
                Thread.sleep(forTimeInterval: FanControlPolicy.modeRetryDelay)
            }
        }
    }
```

- [ ] **Step 2: Gate and slow the sampling, and hold the last reading**

Add the stored property next to `latestBatteryStatus`:

```swift
    private var lastPowerReading: (soc: Int, plugged: Bool)?
```

Replace `sampleBatteryAndEvaluate()` and `readPowerSourceState()` with:

```swift
    /// `force` is for the XPC entry points and startup, where a caller is waiting on a fresh
    /// answer. The timers pass `false` so an idle machine with the limit off does no IOKit work.
    private func sampleBatteryAndEvaluate(force: Bool = false) {
        guard force || batteryEngine.needsSampling else { return }
        // Hold the last good reading rather than falling back to "0 %, unplugged": that reads as
        // "on battery" and would make the engine release a limit it should be holding.
        guard let reading = readPowerSourceState() ?? lastPowerReading else {
            latestBatteryStatus = BatteryControlServiceStatus(
                mode: .unsupported,
                currentPercentage: 0,
                isPowerAdapterConnected: false,
                detail: "전원 소스를 읽을 수 없습니다",
                updatedAt: Date().timeIntervalSince1970
            )
            return
        }
        lastPowerReading = reading
        latestBatteryStatus = batteryEngine.update(currentSoC: reading.soc, isPluggedIn: reading.plugged)
    }

    private func readPowerSourceState() -> (soc: Int, plugged: Bool)? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        let descriptions = list.compactMap {
            IOPSGetPowerSourceDescription(snapshot, $0)?.takeUnretainedValue() as? [String: Any]
        }
        // Prefer the internal battery — "whatever source is listed first" picks up an attached UPS
        // — but fall back to the first source rather than reporting nothing, so a machine that does
        // not tag its type still works exactly as it did before.
        let battery = descriptions.first { ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType }
        guard let desc = battery ?? descriptions.first else { return nil }

        let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maxCap = desc[kIOPSMaxCapacityKey] as? Int ?? 100
        let soc = maxCap > 0 ? Int((Double(current) / Double(maxCap) * 100.0).rounded()) : current
        let isPlugged = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        return (soc, isPlugged)
    }
```

- [ ] **Step 3: Take battery sampling off the 0.5 s timer**

Replace `startTimers()` and `makeTimer(interval:)`:

```swift
    private func startTimers() {
        // This drives stateful manual/automatic retries at the policy cadence. The engine
        // independently limits successful target-RPM writes to `controlInterval`.
        controlTimer = makeTimer(interval: FanControlPolicy.modeRetryDelay, samplesBattery: false)
        // The charge limit moves on the order of minutes, so it rides the 5 s watchdog only.
        // Sampling it at the 0.5 s fan cadence meant two IOPS snapshot copies a second in a root
        // daemon, forever, including for users who never enabled the feature.
        watchdogTimer = makeTimer(interval: FanControlPolicy.heartbeatCheckInterval, samplesBattery: true)
    }

    private func makeTimer(interval: TimeInterval, samplesBattery: Bool) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            try? engine.tick(now: now())
            if samplesBattery { sampleBatteryAndEvaluate() }
            resumeListenerIfSafe()
        }
        timer.resume()
        return timer
    }
```

- [ ] **Step 4: Force the sample where a caller is waiting, and tighten the generation guard**

In `run()`:

```swift
            engine.resetAllFansToAutomatic(now: now())
            // Startup normalization has to run whatever the gate says: a helper that was SIGKILLed
            // while inhibiting leaves the SMC register latched, and this is what clears it.
            sampleBatteryAndEvaluate(force: true)
            resumeListenerIfSafe()
```

In `configureBattery(_:withReply:)`, change the guard and force the sample:

```swift
                guard request.generation > lastBatteryGeneration else {
                    reply.send((try BatteryControlCodec.encode(latestBatteryStatus), nil))
                    return
                }
                lastBatteryGeneration = request.generation
                batteryEngine.configure(request.configuration)
                sampleBatteryAndEvaluate(force: true)
```

In `batteryStatus(withReply:)`:

```swift
            sampleBatteryAndEvaluate(force: true)
```

In the wake observer inside `observeSleep()`:

```swift
            self?.queue.async {
                self?.sampleBatteryAndEvaluate(force: true)
            }
```

- [ ] **Step 5: Build and run the full suite**

```bash
xcodegen generate && xcodebuild build -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 | tail -8
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add WattlyFanDaemon/FanControlDaemon.swift && git commit -m "fix(battery): hold the limit across sleep and stop sampling power at 2 Hz"
```

---

## Task 7: Bridge reconcile loop and the settings install flow

Closes review findings **#6** (nothing re-pushes the configuration after a helper restart, so the limit silently disappears), **#1**'s UI half (turning the toggle on has to install *and* apply, and revert itself if the user cancels the prompt), **#11** (a one-shot `refreshStatus` freezes the status dot, so the user never sees the limit engage) and **#13** (a default parameter that fabricates a second, disconnected client).

Like Task 6 this is wiring over already-tested predicates: `BatteryControlPolicy` (Task 4) and the client transport (Task 5) carry the logic, and SwiftUI views are not unit-testable here. The gate is the build, the full suite, and the manual checklist.

**Files:**
- Modify: `Wattly/Views/BatteryControlBridge.swift`, `Wattly/Views/Settings/SettingsBatterySection.swift`, `Wattly/Views/SettingsView.swift:12-18`

**Interfaces:**
- Consumes: `BatteryControlPolicy.reconcileInterval` / `.shouldRunInstaller` (Task 4), `BatteryControlClient.reconcile` / `.installAndApply` / `.refreshStatus` (Task 5).
- Produces: nothing for other tasks.

- [ ] **Step 1: Add the reconcile loop to the bridge**

Replace the body of `BatteryControlBridge` in `Wattly/Views/BatteryControlBridge.swift`:

```swift
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            // Unconditional on purpose, unlike the fan bridge: a helper that survived the last app
            // session may still be holding an inhibit the user has since switched off, and this is
            // the push that clears it.
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
            // The helper restarts with an empty configuration (KeepAlive relaunch, kickstart, a
            // crash) and nothing else would notice: `onChange` needs a user edit, the wake handler
            // needs a sleep. The id covers BOTH values so an edit mid-loop restarts the task —
            // otherwise a stale captured `limit` could be reconciled back over the new one.
            .task(id: "\(enabled)-\(limit)") {
                guard enabled else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(BatteryControlPolicy.reconcileInterval))
                    guard !Task.isCancelled else { return }
                    await client.reconcile(enabled: enabled, limitPercentage: limit)
                }
            }
    }
```

- [ ] **Step 2: Rewrite the settings install flow and poll the status**

In `Wattly/Views/Settings/SettingsBatterySection.swift`, replace the `.task { await batteryControl.refreshStatus() }` modifier attached to `SettingsCard` with the polling loop plus the toggle handler:

```swift
            // A one-shot refresh freezes the dot: the interesting moment — reaching the limit —
            // happens minutes after the window opens.
            .task {
                while !Task.isCancelled {
                    await batteryControl.refreshStatus()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            // Turning the opt-in on installs the helper if it is missing (one macOS admin-auth
            // prompt) and pushes the limit either way, so the helper never sits at its disabled
            // default while this toggle reads ON. If the user cancels the prompt, revert the toggle
            // so it reflects reality.
            .onChange(of: batteryLimitEnabled) { _, isEnabled in
                guard isEnabled, !batteryControl.isInstallingHelper else { return }
                let window = NSApp.keyWindow
                let limit = batteryLimitPercentage
                Task {
                    let mode = await batteryControl.refreshStatus()?.mode ?? .unavailable
                    guard BatteryControlPolicy.shouldRunInstaller(mode: mode) else {
                        // The helper already answers — reuse it, no second admin prompt.
                        await batteryControl.apply(enabled: true, limitPercentage: limit)
                        return
                    }
                    if let failure = await batteryControl.installAndApply(limitPercentage: limit, window: window) {
                        installErrorMessage = failure.localizedDescription
                        isInstallFailedAlertPresented = true
                        batteryLimitEnabled = false
                    }
                }
            }
```

Add `import AppKit` at the top of the file (for `NSApp`).

Then route the manual "도우미 설치" button — which stays for the case where the toggle is already on and the helper went missing — through the same call. Replace the button's action in `batteryStatusIndicator`:

```swift
                Button {
                    let window = NSApp.keyWindow
                    let limit = batteryLimitPercentage
                    Task {
                        if let failure = await batteryControl.installAndApply(limitPercentage: limit, window: window) {
                            installErrorMessage = failure.localizedDescription
                            isInstallFailedAlertPresented = true
                        }
                    }
                } label: {
```

Note the bridge's own `onChange(of: enabled)` also fires an `apply` here. A double-apply is harmless — the fan section carries the same note — and the 5 s poll above repairs the one bad interleaving (a bridge `apply` that fails mid-install and briefly shows `.unavailable`).

- [ ] **Step 3: Drop the fabricating default parameter**

In `Wattly/Views/SettingsView.swift`, remove the default value so nothing can silently get a client that is disconnected from the app's:

```swift
    init(monitor: SystemMonitor, fanControl: FanControlClient, batteryControl: BatteryControlClient) {
        self.monitor = monitor
        self.fanControl = fanControl
        self.batteryControl = batteryControl
    }
```

`Wattly/App/WattlyApp.swift:44` is the only call site and already passes it explicitly.

- [ ] **Step 4: Build and run the full suite**

```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 | tail -8
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Views/BatteryControlBridge.swift Wattly/Views/Settings/SettingsBatterySection.swift Wattly/Views/SettingsView.swift && git commit -m "fix(battery): reconcile the helper periodically and install-then-apply from settings"
```

---

## Task 8: Hand the battery back before the helper is removed

Closes review finding **#8**. `launchctl bootout` does SIGTERM the daemon, and after Task 6 that handler releases the limit — but a helper that was SIGKILLed earlier leaves the SMC charge-inhibit latched with nothing left on disk to clear it, and the Mac simply stops charging with no app to explain why. An explicit release before removal closes that deterministically.

**Files:**
- Modify: `Wattly/Core/AppUninstaller.swift:42-60`
- Test: `WattlyTests/AppUninstallerTests.swift`

**Interfaces:**
- Consumes: `BatteryControlClient.apply` (Task 5).
- Produces: `AppUninstaller.cleanUserData(..., releaseBatteryLimit:)` trailing parameter.

- [ ] **Step 1: Write the failing test**

Add to `@Suite struct AppUninstallerTests` in `WattlyTests/AppUninstallerTests.swift`, and add the spy next to `MockLoginItem`:

```swift
    final class ReleaseSpy: @unchecked Sendable {
        var callCount = 0
    }

    @Test @MainActor func testCleanUserDataReleasesTheChargeLimitBeforeRemovingTheHelper() async {
        let mockLogin = MockLoginItem()
        let spy = ReleaseSpy()
        let suiteName = "test.uninstall.battery.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        await AppUninstaller.cleanUserData(
            userDefaults: testDefaults,
            loginItem: mockLogin,
            fileManager: .default,
            homeDirectory: tempHome,
            bundleID: suiteName,
            releaseBatteryLimit: { spy.callCount += 1 }
        )

        #expect(spy.callCount == 1)
        #expect(mockLogin.disabledCallCount == 1)
    }
```

The injected closure is what keeps this test off real XPC — the production default builds a client and talks to the helper.

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/AppUninstallerTests 2>&1 | tail -20
```

Expected: compile failure — `extra argument 'releaseBatteryLimit' in call`.

- [ ] **Step 3: Implement**

In `Wattly/Core/AppUninstaller.swift`, add the parameter and the call:

```swift
    @MainActor
    static func cleanUserData(
        userDefaults: UserDefaults = .standard,
        loginItem: LoginItemControlling = LoginItem(),
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleID: String = Bundle.main.bundleIdentifier ?? "dev.jjundev.Wattly",
        releaseBatteryLimit: @MainActor () async -> Void = {
            await BatteryControlClient().apply(enabled: false, limitPercentage: 100)
        }
    ) async {
        // 1. Unregister login item
        try? loginItem.setEnabled(false)

        // 2. Hand the battery back before the helper goes away. `bootout` below SIGTERMs the
        // daemon, which releases on its own — but a helper that was SIGKILLed earlier would leave
        // the SMC charge-inhibit latched with nothing left on disk to ever clear it.
        await releaseBatteryLimit()

        // 3. Remove privileged helper daemon if installed
        let daemonPath = "/Library/PrivilegedHelperTools/\(FanHelperInstaller.label)"
```

Renumber the remaining comments in the function (`// 4. Clear user defaults`, `// 5. Delete user files in Library`).

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/AppUninstallerTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 4 tests.

- [ ] **Step 5: Run the full suite and commit**

```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 | tail -8
```

Expected: `** TEST SUCCEEDED **`, 581 tests in 54 suites.

```bash
git add Wattly/Core/AppUninstaller.swift WattlyTests/AppUninstallerTests.swift && git commit -m "fix(battery): release the charge limit before uninstalling the helper"
```

---

## Verification Plan

### Automated

```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'
```

Baseline is 537 tests / 52 suites. This plan's eight tasks, plus the final whole-branch review's fixes (an added engine test and a replaced policy test), brought the suite to **581 tests / 54 suites**, all passing — the actual count the full-suite run reports, not the ~565 this section originally estimated.

### Manual, on-device — required before merge

The daemon and UI wiring in Tasks 6 and 7 have no test host, and the SMC registers cannot be exercised off real hardware. Run this on a MacBook:

1. **Install + apply in one go (#1, #12).** Fresh state — `sudo launchctl bootout system/dev.jjundev.WattlyFanDaemon` and `sudo rm -f /Library/PrivilegedHelperTools/dev.jjundev.WattlyFanDaemon /Library/LaunchDaemons/dev.jjundev.WattlyFanDaemon.plist` first. Open Settings → 배터리 충전 제어, toggle on, pick 85%. The Settings window must stay visible under the auth prompt, and after authenticating the dot must go green with "목표치(85%)까지 충전 중" — **not** "충전 제한 비활성화됨".
2. **Limit engages (#3).** Charge past 85%. Status must read "충전 제한 85% 도달 (전원 어댑터 바이패스 구동)" and `pmset -g batt` must stop reporting `AC attached; charging`. If the status instead reads "이 Mac에서 충전 제어를 적용하지 못했습니다", the register table needs revisiting — capture `sudo log show --last 5m --predicate 'process == "WattlyFanDaemon"'`.
3. **Hysteresis holds (#7).** Let it drift to 84% and sit there for several minutes. No oscillation, and `sudo powermetrics --samplers tasks -n 1 | grep -i perfpower` must show `PerfPowerServices` under 1%.
4. **Sleep keeps the limit (#4).** Close the lid plugged in at ≥ 85% for at least 30 minutes. On wake the battery must still be at the limit, **not** 100%.
5. **Helper restart self-heals (#6).** With the limit engaged, `sudo launchctl kickstart -k system/dev.jjundev.WattlyFanDaemon`. Within 60 seconds the status must return to "충전 제한 85% 도달" without touching the UI.
6. **Helper loss is visible (#2).** `sudo launchctl bootout system/dev.jjundev.WattlyFanDaemon`. Within ~5 seconds the Settings dot must turn red and the "도우미 설치" button must reappear.
7. **Uninstall hands the battery back (#8).** With the limit engaged, run the in-app 완전 삭제. Afterwards `pmset -g batt` must show charging resumed.
8. **Fan path unregressed (Task 5 refactor).** Toggle 팬 제어 on from a fresh state and confirm the Settings window survives the auth prompt exactly as before.

---

## Traceability

| Review finding | Task |
|---|---|
| #1 install never applies the limit | 5, 7 |
| #2 XPC errors discarded | 5 |
| #3 SMC write failures swallowed | 3 |
| #4 sleep drops the limit | 6 |
| #5 `NSWorkspace` in a system daemon | out of scope — the daemon's own wake observer is not reliably delivered in the system domain; the app's wake notification drives the re-assert through `configureBattery` instead |
| #6 no reconcile after helper restart | 4, 5, 7 |
| #7 2 Hz IOPS polling | 6 |
| #8 uninstall leaves the register latched | 8 |
| #9 `Codable` bypasses the clamp | 1, 3 |
| #10 power read fails open | 6 |
| #11 status frozen in Settings | 7 |
| #12 install skips the window dance | 5 |
| #13 fabricating default parameter | 7 |
| #14 `generation >=` | 6 |
| #15 `CH0C` alongside `CH0B` | 2 |
