# Battery Charge Limit — Register Generations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the charge limit work on Apple Silicon Macs from ~2023 onward, which expose `CHTE` instead of the `CH0B`/`CH0C` pair the current code writes, and tell the user honestly when a Mac has no charge-control register at all.

**Architecture:** The state machine is correct and stays untouched — the hysteresis, the transition-only writes and the retry budget all survive verbatim. The defect is one layer down, in a register table that infers the key set from `#if arch(arm64)` instead of asking the hardware. The engine changes only to learn a new fact about itself: that some Macs have no register at all, which is a permanent condition rather than a write it can retry. This plan gives `BatteryControlKeys` a generation axis (`modern` / `legacy` / `intel` / `unsupported`), moves generation *detection* into the daemon as a read-only `keyInfo` probe, and threads a permanent "this Mac cannot do it" signal up to the settings screen so it can disable the toggle rather than leaving it on over a feature that will never engage.

**Tech Stack:** Swift 6, Swift Testing (`import Testing`), IOKit (`AppleSMC`), XPC (`NSXPCConnection`), SwiftUI, xcodegen.

## Why this plan exists — the measurement

Diagnosis on the development machine (Apple M5, Mac17,2, macOS 26.6.2) established, by enumerating all 2779 SMC keys:

- `CH0B`, `CH0C`, `CH0I`, `CHWA` and `BCLM` are **absent**. Every write the shipping code attempts fails because the key does not exist.
- `CHTE` is **present**: `ui32`, 4 bytes, attribute byte `0xd4` — the same attribute as `F0Tg`, the fan key this app already writes successfully. `0x40` is the writable bit; read-only sensors are `0x84`.
- Writing `CHTE = 01 00 00 00` was accepted (`kernel=0 smcResult=0`), the value held on readback, and the measured battery current `B0AC` fell from **2511 mA to 0 mA within ~3 seconds** and stayed there. Charger input `BC1I` held at ~1117 throughout — the adapter kept powering the system while nothing entered the cell, which is exactly the pass-through this feature wants. Writing `00 00 00 00` restored charging within ~3 seconds.

That measurement is the specification for the `modern` row of the table below. It also proved the existing `SMCControlConnection.write(_:bytes:)` handles a 4-byte `ui32` key correctly with no key-info round trip, so **the SMC transport needs no change**.

## Global Constraints

- Never poll or write SMC keys continuously in a loop; only write SMC registers when transitioning state, to prevent `PerfPowerServices` CPU spikes and `PowerLog` database bloat.
- A failed SMC write may be retried at most `BatteryControlEngine.maxConsecutiveWriteFailures` (3) consecutive times; past that the engine must stop writing until `configure` is called again.
- Keep the 2% hysteresis buffer: target 85% stops charging at `>= 85`, resumes at `<= 83`.
- Charging on Apple Silicon is **binary** — there is no firmware-level "stop at 80%". Holding a target means the engine flips the gate as the battery crosses the threshold, which is what it already does. No row of the register table may assume a firmware ceiling except `intel`, where `BCLM` genuinely is one.
- Generation detection must come from **probing the hardware**, never from `#if arch(arm64)` or a model-name table. Inferring it is the exact defect this plan fixes.
- `WattlyFanDaemon` and its files are **not** reachable from `WattlyTests` (the test target depends on the `Wattly` app target only). Any logic that needs a unit test must live in `FanControlShared`, which compiles into both.
- `BatteryControlServiceStatus` is decoded by app builds talking to an **older installed helper**. New fields must be `Optional` so the synthesized `decodeIfPresent` keeps old payloads decodable.
- All new user-facing strings are Korean, matching the existing `detail` strings.
- A clean checkout must build without anyone running xcodegen first, so a task that adds source files must commit the regenerated `Wattly.xcodeproj/project.pbxproj` too.
- Full gate for every task: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'` must stay green, plus `xcodebuild build` (which is what compiles the daemon target). Baseline before Task 1: **581 tests / 54 suites**.

## Out of Scope

- `CHIE` (`hex_`, 1 byte, `0x08`) forces the machine to *discharge* while on adapter power. That is a different feature from a charge limit and this plan does not touch it.
- Converting the daemon's sleep/wake notifications to `IORegisterForSystemPower`. The app's wake push already drives `reassertHardwareState()` through `configureBattery`.
- Any change to `SMCControlConnection`. The measurement above proved it already writes a 4-byte `ui32` correctly.

---

## File Structure

**Modify:**
- `FanControlShared/BatteryControlKeys.swift` — gains `BatteryControlRegisterSet`, a probe order, and multi-byte payloads. Remains pure and fully unit-tested; this is where the fix lives.
- `FanControlShared/BatteryControlEngine.swift` — `BatteryControlHardwareProtocol` swaps `isAppleSilicon: Bool` for `registerSet`; the engine short-circuits when the Mac has no register rather than burning its write budget.
- `FanControlShared/BatteryControlProtocol.swift` — status gains `isHardwareSupported: Bool?`, the permanent-capability signal the settings screen needs.
- `FanControlShared/BatteryControlPolicy.swift` — `shouldReapply` stops re-pushing at hardware that can never accept the configuration.
- `WattlyFanDaemon/BatteryControlHardware.swift` — detects the generation with a read-only `keyInfo` probe at init and executes multi-byte writes.
- `Wattly/Views/Settings/SettingsBatterySection.swift` — disables the toggle and explains why when the Mac is unsupported.
- `Wattly/Views/BatteryControlBridge.swift` — the reconcile loop stops instead of re-checking a Mac that can never change its answer.
- Tests: `WattlyTests/BatteryControlKeysTests.swift`, `WattlyTests/BatteryControlEngineTests.swift`, `WattlyTests/BatteryControlProtocolTests.swift`, `WattlyTests/BatteryControlPolicyTests.swift`.

**Create:** nothing. No new files, so no `project.pbxproj` change should appear in any commit.

---

## Task 1: Teach the register table about generations

Fixes the root defect. The table stops taking `isAppleSilicon: Bool` and starts taking a `BatteryControlRegisterSet` that the daemon probes from the hardware.

The protocol member, the daemon's implementation and the test mock all change in this one task **on purpose**: `isAppleSilicon` has exactly three implementors and splitting them across tasks would leave a commit that does not compile.

**Files:**
- Modify: `FanControlShared/BatteryControlKeys.swift` (whole file)
- Modify: `FanControlShared/BatteryControlEngine.swift:3-6` (protocol declaration only)
- Modify: `WattlyFanDaemon/BatteryControlHardware.swift` (whole file)
- Test: `WattlyTests/BatteryControlKeysTests.swift` (whole file), `WattlyTests/BatteryControlEngineTests.swift:6` and `:69` (mock member and one test line)

**Interfaces:**
- Consumes: `SMCControlConnection.keyInfo(_:) -> (type: String, size: Int)?` and `.write(_:bytes:) -> (kernel: kern_return_t, smcResult: UInt8)?`, both already present in the daemon.
- Produces:
  - `BatteryControlRegisterSet` — `.modern` / `.legacy` / `.intel` / `.unsupported`, `String`-backed `Codable`
  - `BatteryControlKeyWrite(key: String, bytes: [UInt8], isRequired: Bool)` — note `bytes`, replacing the old single `byte`
  - `BatteryControlKeys.probeOrder: [(registerSet: BatteryControlRegisterSet, key: String)]`
  - `BatteryControlKeys.writes(inhibited: Bool, registerSet: BatteryControlRegisterSet, targetLimit: Int) -> [BatteryControlKeyWrite]`
  - `BatteryControlHardwareProtocol.registerSet: BatteryControlRegisterSet` — replaces `isAppleSilicon`

- [ ] **Step 1: Replace the tests**

Replace the entire contents of `WattlyTests/BatteryControlKeysTests.swift` with:

```swift
import Foundation
import Testing
@testable import Wattly

@Suite struct BatteryControlKeysTests {
    @Test func modernMacsWriteTheFourByteCHTEFlag() {
        let inhibit = BatteryControlKeys.writes(inhibited: true, registerSet: .modern, targetLimit: 85)
        #expect(inhibit == [BatteryControlKeyWrite(key: "CHTE",
                                                   bytes: [0x01, 0x00, 0x00, 0x00],
                                                   isRequired: true)])

        let release = BatteryControlKeys.writes(inhibited: false, registerSet: .modern, targetLimit: 85)
        #expect(release == [BatteryControlKeyWrite(key: "CHTE",
                                                   bytes: [0x00, 0x00, 0x00, 0x00],
                                                   isRequired: true)])
    }

    @Test func theModernFlagIgnoresTheTargetBecauseChargingIsBinary() {
        // CHTE is a gate, not a ceiling. The engine holds the target by flipping the gate at the
        // threshold — if this row ever encoded the percentage it would be lying about the hardware.
        let at80 = BatteryControlKeys.writes(inhibited: true, registerSet: .modern, targetLimit: 80)
        let at95 = BatteryControlKeys.writes(inhibited: true, registerSet: .modern, targetLimit: 95)
        #expect(at80 == at95)
    }

    @Test func legacyMacsWriteBothChargerRegistersAndOnlyCH0BIsRequired() {
        let writes = BatteryControlKeys.writes(inhibited: true, registerSet: .legacy, targetLimit: 85)
        #expect(writes.count == 2)
        #expect(writes[0] == BatteryControlKeyWrite(key: "CH0B", bytes: [0x02], isRequired: true))
        #expect(writes[1] == BatteryControlKeyWrite(key: "CH0C", bytes: [0x02], isRequired: false))
        #expect(writes.filter(\.isRequired).map(\.key) == ["CH0B"])
    }

    @Test func legacyReleaseRestoresBothChargerRegisters() {
        let writes = BatteryControlKeys.writes(inhibited: false, registerSet: .legacy, targetLimit: 100)
        #expect(writes.map(\.key) == ["CH0B", "CH0C"])
        #expect(writes.allSatisfy { $0.bytes == [0x00] })
    }

    @Test func intelWritesTheCeilingItself() {
        let inhibit = BatteryControlKeys.writes(inhibited: true, registerSet: .intel, targetLimit: 85)
        #expect(inhibit == [BatteryControlKeyWrite(key: "BCLM", bytes: [85], isRequired: true)])

        let release = BatteryControlKeys.writes(inhibited: false, registerSet: .intel, targetLimit: 85)
        #expect(release == [BatteryControlKeyWrite(key: "BCLM", bytes: [100], isRequired: true)])
    }

    @Test func intelCeilingIsClampedIntoAByte() {
        let writes = BatteryControlKeys.writes(inhibited: true, registerSet: .intel, targetLimit: 4000)
        #expect(writes[0].bytes == [255])
    }

    @Test func unsupportedHardwareHasNothingToWrite() {
        #expect(BatteryControlKeys.writes(inhibited: true, registerSet: .unsupported, targetLimit: 85).isEmpty)
        #expect(BatteryControlKeys.writes(inhibited: false, registerSet: .unsupported, targetLimit: 85).isEmpty)
    }

    @Test func probeOrderPrefersTheNewerRegisterSet() {
        // An M5 exposes CHTE and not CH0B. Probing CH0B first would pick the legacy set on any Mac
        // that happens to expose both, which is the failure mode this ordering exists to prevent.
        #expect(BatteryControlKeys.probeOrder.map(\.key) == ["CHTE", "CH0B", "BCLM"])
        #expect(BatteryControlKeys.probeOrder.map(\.registerSet) == [.modern, .legacy, .intel])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlKeysTests 2>&1 | tail -30
```

Expected: compile failure — `cannot infer contextual base in reference to member 'modern'` and `extra argument 'bytes' in call`.

- [ ] **Step 3: Rewrite the register table**

Replace the entire contents of `FanControlShared/BatteryControlKeys.swift` with:

```swift
import Foundation

/// Which generation of charge-control registers a Mac exposes.
///
/// Apple changed the register set on Apple Silicon around 2023: the `CH0B`/`CH0C` pair that M1–M3
/// machines honour simply does not exist on newer models, where a single `CHTE` flag took over.
/// Inferring the answer from `#if arch(arm64)` is what made the limit fail silently on an M5 — the
/// daemon wrote a key that was not there and had no way to tell that apart from a rejected write.
public enum BatteryControlRegisterSet: String, Codable, Equatable, Sendable {
    /// Apple Silicon, roughly 2023 and newer (macOS Sequoia / Tahoe): a single `CHTE` `ui32`.
    case modern
    /// Apple Silicon M1–M3: the `CH0B` / `CH0C` charger-control pair.
    case legacy
    /// Intel: `BCLM` stores the ceiling percentage itself.
    case intel
    /// None of the above are present. The charge limit cannot work on this Mac at all.
    case unsupported
}

/// One SMC register write that a charge-limit transition needs.
public struct BatteryControlKeyWrite: Equatable, Sendable {
    public let key: String
    /// The payload, sized for the key: `CHTE` is a 4-byte `ui32`, the others are one byte.
    public let bytes: [UInt8]
    /// `false` for a register only some models expose. A failed optional write must not fail the
    /// transition, or the engine would report a failure on hardware that actually works.
    public let isRequired: Bool

    public init(key: String, bytes: [UInt8], isRequired: Bool) {
        self.key = key
        self.bytes = bytes
        self.isRequired = isRequired
    }
}

/// Picks the SMC registers for a charge-limit transition. This lives in `FanControlShared` rather
/// than beside the hardware because the `WattlyFanDaemon` target has no test host — keeping the
/// register table here is what makes it verifiable at all.
public enum BatteryControlKeys {
    /// Probed in this order at daemon startup; the first key that answers a `keyInfo` call decides
    /// the generation. Newest first, so a Mac exposing more than one set gets the current one.
    public static let probeOrder: [(registerSet: BatteryControlRegisterSet, key: String)] = [
        (.modern, "CHTE"),
        (.legacy, "CH0B"),
        (.intel, "BCLM")
    ]

    public static func writes(inhibited: Bool,
                              registerSet: BatteryControlRegisterSet,
                              targetLimit: Int) -> [BatteryControlKeyWrite] {
        switch registerSet {
        case .modern:
            // `CHTE` is a 4-byte gate flag: 1 stops charging, 0 allows it. Measured on an M5 — the
            // battery current falls from ~2500 mA to 0 mA within ~3 s while the charger keeps
            // powering the system, which is the adapter pass-through this feature is for.
            return [BatteryControlKeyWrite(key: "CHTE",
                                           bytes: [inhibited ? 0x01 : 0x00, 0x00, 0x00, 0x00],
                                           isRequired: true)]
        case .legacy:
            // M1–M3 inhibit through the charger-control registers. Models differ in which one they
            // honour, so both are written; only `CH0B` decides success.
            let byte: UInt8 = inhibited ? 0x02 : 0x00
            return [
                BatteryControlKeyWrite(key: "CH0B", bytes: [byte], isRequired: true),
                BatteryControlKeyWrite(key: "CH0C", bytes: [byte], isRequired: false)
            ]
        case .intel:
            // Intel stores the ceiling itself: the target percentage while limiting, 100 when off.
            return [BatteryControlKeyWrite(key: "BCLM",
                                           bytes: [UInt8(clamping: inhibited ? targetLimit : 100)],
                                           isRequired: true)]
        case .unsupported:
            // Nothing to write. Returning an empty list rather than a doomed write keeps "this Mac
            // cannot do it" a fact of the table instead of a special case at every call site.
            return []
        }
    }
}
```

- [ ] **Step 4: Swap the protocol member**

In `FanControlShared/BatteryControlEngine.swift`, replace the protocol at the top of the file:

```swift
public protocol BatteryControlHardwareProtocol: Sendable {
    /// Which charge-control register generation this Mac exposes, probed from the hardware rather
    /// than inferred from the architecture.
    var registerSet: BatteryControlRegisterSet { get }
    func setChargingInhibited(_ inhibited: Bool, targetLimit: Int) -> Bool
}
```

Nothing else in that file changes in this task.

- [ ] **Step 5: Detect the generation in the daemon**

Replace the entire contents of `WattlyFanDaemon/BatteryControlHardware.swift` with:

```swift
import Foundation
import IOKit

public final class SMCBatteryControlHardware: BatteryControlHardwareProtocol, @unchecked Sendable {
    private let smc: SMCControlConnection
    public let registerSet: BatteryControlRegisterSet

    init(smc: SMCControlConnection) {
        self.smc = smc
        // Ask the hardware which generation it is instead of inferring it from the architecture.
        // A `keyInfo` probe is read-only and costs at most three calls, once per process — and a
        // key that does not answer here is a key that could only ever fail to be written.
        self.registerSet = BatteryControlKeys.probeOrder
            .first { smc.keyInfo($0.key) != nil }?
            .registerSet ?? .unsupported
    }

    public func setChargingInhibited(_ inhibited: Bool, targetLimit: Int) -> Bool {
        let writes = BatteryControlKeys.writes(inhibited: inhibited,
                                               registerSet: registerSet,
                                               targetLimit: targetLimit)
        // No register means no write can succeed. Report that rather than returning a vacuous
        // "all zero required writes succeeded" true.
        guard !writes.isEmpty else { return false }

        var requiredWritesSucceeded = true
        for write in writes {
            let reply = smc.write(write.key, bytes: write.bytes)
            let succeeded = reply?.kernel == KERN_SUCCESS && reply?.smcResult == 0
            // An absent optional register reports a non-zero SMC result; that is expected on the
            // models that only implement one of a pair, so it must not fail the transition.
            if !succeeded && write.isRequired { requiredWritesSucceeded = false }
        }
        return requiredWritesSucceeded
    }
}
```

- [ ] **Step 6: Update the test mock**

In `WattlyTests/BatteryControlEngineTests.swift`, in `MockBatteryHardware`, replace the line

```swift
    var isAppleSilicon: Bool = true
```

with

```swift
    var registerSet: BatteryControlRegisterSet = .modern
```

and in `intelMacReceivesCustomTargetLimit`, replace

```swift
        mockHW.isAppleSilicon = false
```

with

```swift
        mockHW.registerSet = .intel
```

Change nothing else in that file — the mock does not consult the register table, so every other test is unaffected. Verify that rather than assuming it.

- [ ] **Step 7: Run the tests and the build**

```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlKeysTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 8 tests.

```bash
xcodebuild build -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **` — this is what compiles the daemon target.

```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 | tail -8
```

Expected: `** TEST SUCCEEDED **`, 584 tests in 54 suites (581 + 3).

- [ ] **Step 8: Commit**

```bash
git add FanControlShared/BatteryControlKeys.swift FanControlShared/BatteryControlEngine.swift WattlyFanDaemon/BatteryControlHardware.swift WattlyTests/BatteryControlKeysTests.swift WattlyTests/BatteryControlEngineTests.swift && git commit -m "fix(battery): pick the charge register set by probing the hardware"
```

---

## Task 2: Report unsupported hardware as a permanent fact

Without this the engine treats "this Mac has no register" identically to "the write failed" — it spends its 3-write budget discovering the same thing three times, reports a retryable-looking failure, and the app's reconcile pass re-pushes forever. All three are wrong for a permanent hardware fact.

**Files:**
- Modify: `FanControlShared/BatteryControlProtocol.swift` (the `BatteryControlServiceStatus` struct)
- Modify: `FanControlShared/BatteryControlEngine.swift` (`needsSampling`, `update`, `detailText`, `status`)
- Modify: `FanControlShared/BatteryControlPolicy.swift` (`shouldReapply`)
- Test: `WattlyTests/BatteryControlProtocolTests.swift`, `WattlyTests/BatteryControlEngineTests.swift`, `WattlyTests/BatteryControlPolicyTests.swift`

**Interfaces:**
- Consumes: `BatteryControlHardwareProtocol.registerSet` and `BatteryControlRegisterSet.unsupported` (Task 1).
- Produces: `BatteryControlServiceStatus.isHardwareSupported: Bool?` — `false` means the Mac can never do it, `nil` means the helper is too old to say. Task 3 reads it.

- [ ] **Step 1: Write the failing tests**

Append to `struct BatteryControlProtocolTests` in `WattlyTests/BatteryControlProtocolTests.swift`:

```swift
    @Test func statusRoundTripsHardwareSupport() throws {
        let status = BatteryControlServiceStatus(
            mode: .unsupported,
            currentPercentage: 70,
            isPowerAdapterConnected: true,
            detail: "이 Mac은 충전 제어를 지원하지 않습니다",
            updatedAt: 1.0,
            appliedLimitPercentage: nil,
            isHardwareSupported: false
        )
        let decoded = try BatteryControlCodec.decode(
            BatteryControlServiceStatus.self,
            from: try BatteryControlCodec.encode(status)
        )
        #expect(decoded == status)
        #expect(decoded.isHardwareSupported == false)
    }

    @Test func statusFromOlderHelperLeavesHardwareSupportUnknown() throws {
        // A helper predating this field says nothing about capability, which must decode as nil —
        // "unknown", not "unsupported". The settings screen keys its toggle off exactly this.
        let legacy = Data("""
        {"mode":"charging","currentPercentage":70,"isPowerAdapterConnected":true,"detail":"충전 중","updatedAt":1.0}
        """.utf8)
        let decoded = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: legacy)
        #expect(decoded.isHardwareSupported == nil)
    }
```

Append to `struct BatteryControlEngineTests` in `WattlyTests/BatteryControlEngineTests.swift`:

```swift
    @Test func hardwareWithNoRegisterIsReportedAsPermanentlyUnsupported() {
        let mockHW = MockBatteryHardware()
        mockHW.registerSet = .unsupported
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))

        let status = engine.update(currentSoC: 90, isPluggedIn: true)
        #expect(status.mode == .unsupported)
        #expect(status.isHardwareSupported == false)
        #expect(status.detail == "이 Mac은 충전 제어를 지원하지 않습니다")
        #expect(status.appliedLimitPercentage == nil)
    }

    @Test func unsupportedHardwareSpendsNoWriteBudgetAtAll() {
        // "No register" is a permanent fact, not a transient failure. Discovering it three times
        // over would be pure waste, and would report a retryable-looking state.
        let mockHW = MockBatteryHardware()
        mockHW.registerSet = .unsupported
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))

        for _ in 0..<6 { _ = engine.update(currentSoC: 90, isPluggedIn: true) }
        #expect(mockHW.writeCount == 0)
        #expect(!engine.needsSampling)
    }

    @Test func supportedHardwareStillReportsItsCapability() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))
        #expect(engine.update(currentSoC: 70, isPluggedIn: true).isHardwareSupported == true)
    }
```

Append to `@Suite struct BatteryControlPolicyTests` in `WattlyTests/BatteryControlPolicyTests.swift`:

```swift
    @Test func doNotReapplyIntoHardwareThatCanNeverAcceptIt() {
        let noRegister = BatteryControlServiceStatus(
            mode: .unsupported,
            currentPercentage: 70,
            isPowerAdapterConnected: true,
            detail: "이 Mac은 충전 제어를 지원하지 않습니다",
            updatedAt: 0,
            appliedLimitPercentage: nil,
            isHardwareSupported: false
        )
        #expect(!BatteryControlPolicy.shouldReapply(enabled: true, limitPercentage: 85, status: noRegister))
    }

    @Test func stillReapplyWhenCapabilityIsUnknown() {
        // An older helper reports nil. That is "unknown", and giving up on it would strand a
        // perfectly capable Mac behind a field its helper is simply too old to send.
        let olderHelper = BatteryControlServiceStatus(
            mode: .unsupported,
            currentPercentage: 70,
            isPowerAdapterConnected: true,
            detail: "이 Mac에서 충전 제어를 적용하지 못했습니다",
            updatedAt: 0,
            appliedLimitPercentage: nil,
            isHardwareSupported: nil
        )
        #expect(BatteryControlPolicy.shouldReapply(enabled: true, limitPercentage: 85, status: olderHelper))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlEngineTests -only-testing:WattlyTests/BatteryControlPolicyTests -only-testing:WattlyTests/BatteryControlProtocolTests 2>&1 | tail -30
```

Expected: compile failure — `extra argument 'isHardwareSupported' in call`.

- [ ] **Step 3: Add the status field**

In `FanControlShared/BatteryControlProtocol.swift`, add the property to `BatteryControlServiceStatus` immediately after `appliedLimitPercentage`:

```swift
    /// Whether this Mac exposes a charge-control register at all. `nil` from a helper too old to
    /// report it — "unknown", not "unsupported". `false` means the limit can never work here, which
    /// is a different thing from a write that failed: the settings screen disables its toggle
    /// instead of showing a state that looks like it is still retrying.
    public var isHardwareSupported: Bool?
```

and add the matching trailing initializer parameter and assignment:

```swift
        appliedLimitPercentage: Int? = nil,
        isHardwareSupported: Bool? = nil
    ) {
```

```swift
        self.appliedLimitPercentage = appliedLimitPercentage
        self.isHardwareSupported = isHardwareSupported
    }
```

- [ ] **Step 4: Short-circuit the engine**

In `FanControlShared/BatteryControlEngine.swift`, add this computed property immediately after `hasActionableFailure`:

```swift
    /// A permanent fact about the Mac, not a state the engine can retry its way out of.
    private var isHardwareSupported: Bool {
        hardware.registerSet != .unsupported
    }
```

Replace `needsSampling` with:

```swift
    public var needsSampling: Bool {
        // A Mac with no charge-control register cannot act on any reading, so it should never ask
        // the daemon for one. The XPC status path forces a sample regardless, so the settings
        // screen still gets a fresh answer to show.
        guard isHardwareSupported else { return false }
        return config.enabled || isCurrentlyInhibited || (!hasInitializedState && !isWriteLatched)
    }
```

Add a guard as the first statement of `update(currentSoC:isPluggedIn:)`, above the existing `normalizeOnFirstUpdate()` guard:

```swift
        // No register means no write can ever succeed. Short-circuit before the normalization gate
        // so the budget is not spent proving a permanent fact three times over.
        guard isHardwareSupported else {
            return status(currentSoC: currentSoC, isPluggedIn: isPluggedIn,
                          target: config.clampedLimitPercentage)
        }
```

In `detailText(isPluggedIn:target:)`, add as the first statement:

```swift
        if !isHardwareSupported { return "이 Mac은 충전 제어를 지원하지 않습니다" }
```

In `status(currentSoC:isPluggedIn:target:)`, change the mode branch and both trailing arguments:

```swift
        let mode: BatteryControlServiceMode
        if !isHardwareSupported || hasActionableFailure {
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
            detail: detailText(isPluggedIn: isPluggedIn, target: target),
            updatedAt: Date().timeIntervalSince1970,
            // Report the limit actually being enforced. A failed write means nothing is, and so
            // does a Mac with no register — reporting `nil` is what makes the app's reconcile pass
            // re-push and clear the latch in the one of those two cases that can recover.
            appliedLimitPercentage: (isHardwareSupported && config.enabled && !hasActionableFailure)
                ? config.clampedLimitPercentage : nil,
            isHardwareSupported: isHardwareSupported
        )
```

- [ ] **Step 5: Stop the reconcile pass re-pushing at it**

In `FanControlShared/BatteryControlPolicy.swift`, add a guard to `shouldReapply` between the existing guard and the comparison:

```swift
        guard enabled, status.mode != .unavailable else { return false }
        // Hardware with no charge-control register will never accept the configuration, so
        // re-pushing is not a recovery there — just traffic. `nil` is "unknown" and still retries.
        guard status.isHardwareSupported != false else { return false }
        return status.appliedLimitPercentage != limitPercentage
```

- [ ] **Step 6: Run the tests**

```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlEngineTests -only-testing:WattlyTests/BatteryControlPolicyTests -only-testing:WattlyTests/BatteryControlProtocolTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **` — 29 engine tests (26 + 3), 11 policy tests (9 + 2), 10 protocol tests (8 + 2).

```bash
xcodebuild build -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. (`xcodebuild test` already builds the daemon — its scheme entry has `buildForTesting = "YES"` — so this is a belt-and-braces check, not a second gate.)

```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 | tail -8
```

Expected: `** TEST SUCCEEDED **`, 591 tests in 54 suites (584 + 7).

- [ ] **Step 7: Commit**

```bash
git add FanControlShared/BatteryControlProtocol.swift FanControlShared/BatteryControlEngine.swift FanControlShared/BatteryControlPolicy.swift WattlyTests/BatteryControlProtocolTests.swift WattlyTests/BatteryControlEngineTests.swift WattlyTests/BatteryControlPolicyTests.swift && git commit -m "fix(battery): treat a missing charge register as permanent, not as a failed write"
```

---

## Task 3: Disable the toggle on unsupported hardware

Closes the whole-branch review's Minor 10 — today an unsupported Mac shows the toggle switched ON with a faint grey dot and no explanation, which reads as a broken feature rather than an unavailable one.

This task adds no unit tests: SwiftUI views are not unit-testable in this project, and the decision it renders (`isHardwareSupported == false`) is covered by Task 2. Its gate is a clean build, the suite staying at 591, and the manual check below.

**Files:**
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift`
- Modify: `Wattly/Views/BatteryControlBridge.swift` (the reconcile loop's exit condition)

**Interfaces:**
- Consumes: `BatteryControlServiceStatus.isHardwareSupported: Bool?` (Task 2), `BatteryControlClient.refreshStatus()`, `BatteryControlClient.reconcile(enabled:limitPercentage:)`, `BatteryControlPolicy.statusPollInterval`.
- Produces: nothing.

- [ ] **Step 1: Add the capability check**

In `Wattly/Views/Settings/SettingsBatterySection.swift`, add this computed property immediately above `statusDotColor`:

```swift
    /// Only an explicit `false` disables the control. `nil` means the helper has not answered yet —
    /// or is too old to say — and a Mac must never be declared incapable on a missing answer.
    private var isHardwareUnsupported: Bool {
        batteryControl.status.isHardwareSupported == false
    }
```

- [ ] **Step 2: Make the first status read unconditional**

The toggle cannot know it should be disabled until the helper has answered, and today the poll only runs while the opt-in is already on. Replace the polling `.task(id:)` modifier with:

```swift
            .task(id: batteryLimitEnabled) {
                // One read regardless of the opt-in: a Mac with no charge register has to disable
                // its toggle before the user ever reaches for it.
                await batteryControl.refreshStatus()
                guard batteryLimitEnabled else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(BatteryControlPolicy.statusPollInterval))
                    guard !Task.isCancelled else { return }
                    await batteryControl.refreshStatus()
                }
            }
```

- [ ] **Step 3: Disable and explain the toggle**

Replace the `SettingsToggleRow` block and the `if batteryLimitEnabled` condition that follows it:

```swift
                SettingsToggleRow(isOn: $batteryLimitEnabled,
                                  divider: batteryLimitEnabled && !isHardwareUnsupported) {
                    VStack(alignment: .leading, spacing: 2) {
                        SettingsRowTitle("배터리 충전 제한")
                        Text(isHardwareUnsupported
                             ? "이 Mac은 충전 제어를 지원하지 않습니다. 이 기능이 사용하는 SMC 레지스터가 없습니다."
                             : "설정한 한도에 도달하면 충전을 멈추고 전원 어댑터로만 작동하여 배터리 수명을 보호합니다.")
                            .font(WattlyFont.at(10.5, weight: .regular))
                            .foregroundStyle(t.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // Leave the stored value alone. Flipping it off would look like the app undoing the
                // user's choice, and it would be wrong the moment the same preferences reach a Mac
                // that does support the limit.
                .disabled(isHardwareUnsupported)
                .opacity(isHardwareUnsupported ? 0.55 : 1)

                if batteryLimitEnabled && !isHardwareUnsupported {
```

Change nothing else in the file — the preset selector, status indicator, install button and advisory banner all live inside that `if` and are correctly hidden by it.

- [ ] **Step 4: Let the reconcile loop go quiet on unsupported hardware**

Without this the bridge settles at its 900 s backoff floor and re-checks forever. It costs no SMC
traffic — the engine short-circuits before any hardware call — but it is one XPC round-trip every
15 minutes, permanently, to re-confirm a fact that cannot change while the process lives.

In `Wattly/Views/BatteryControlBridge.swift`, add an exit at the end of the reconcile loop body,
immediately after the `consecutiveUnsupported` assignment:

```swift
                    consecutiveUnsupported = client.status.mode == .unsupported
                        ? consecutiveUnsupported + 1
                        : 0
                    // A Mac with no charge-control register will report the same thing forever, and
                    // the register set is probed once per helper process. Stop rather than back off.
                    if client.status.isHardwareSupported == false { return }
```

Change nothing else in that file.

- [ ] **Step 5: Build and run the full suite**

```bash
xcodegen generate && xcodebuild build -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 | tail -8
```

Expected: `** TEST SUCCEEDED **`, 591 tests in 54 suites — unchanged, this task adds no tests.

- [ ] **Step 6: Commit**

```bash
git add Wattly/Views/Settings/SettingsBatterySection.swift Wattly/Views/BatteryControlBridge.swift && git commit -m "fix(battery): disable the limit toggle on Macs without a charge register"
```

---

## Verification Plan

### Automated

```bash
xcodegen generate && xcodebuild build -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'
```

Baseline before Task 1 is 581 tests / 54 suites. Task 1 adds 3, Task 2 adds 7, Task 3 adds none — **591 tests / 54 suites**, all passing.

### Manual, on-device — required before merge

The development machine is an M5 (`.modern`), so it exercises the row this plan exists for. The `.legacy` and `.intel` rows cannot be exercised here and remain covered by unit tests only — say so in the PR rather than implying they were tried.

1. **Detection.** Install the helper, open Settings → 배터리 충전 제어. The toggle must be **enabled** and the status must not say 지원하지 않습니다. (Before this plan it said "이 Mac에서 충전 제어를 적용하지 못했습니다".)
2. **The limit engages.** Plug in below the limit, set 85%, and charge past it. Status must read "충전 제한 85% 도달 (전원 어댑터 바이패스 구동)".
3. **It really stops — measure, do not trust the label.** `pmset -g batt` still reports `charging` near a full battery even when nothing is entering the cell, which is what made the first diagnosis ambiguous. Confirm with the battery current instead:
   ```bash
   sudo /private/tmp/claude-501/-Users-hyunjun-macbook-pro-Documents-Project-project-wattly/cdc9265a-a281-4c50-9199-1b254e973d1c/scratchpad/chte2/chte2
   ```
   `B0AC` must sit at ~0 mA while inhibited, and `BC1I` must stay non-zero — that combination is the adapter pass-through. Expect ~3 s of latency after each transition.
4. **Hysteresis.** Let it drift to 84% under an 85% limit and sit for several minutes. It must not re-engage charging, and `powermetrics` must show `PerfPowerServices` under 1%.
5. **Sleep.** Close the lid plugged in at ≥ 85% for at least 30 minutes. On wake the battery must still be held at the limit — and per the branch's earlier work, the app's wake push re-asserts the register through `configureBattery`.
6. **Release on uninstall.** With the limit engaged, run the in-app 완전 삭제 and confirm `pmset -g batt` shows charging resumed.
7. **Unsupported rendering.** This cannot be produced on real hardware here. Verify it by temporarily returning `.unsupported` from `SMCBatteryControlHardware.registerSet`, launching, and confirming the toggle is greyed out with the 지원하지 않습니다 copy — then revert the edit. Do not commit it.

## Traceability

| Finding | Task |
|---|---|
| `CH0B`/`CH0C`/`BCLM` absent on M5 → every write fails | 1 |
| Generation inferred from `#if arch(arm64)` instead of probed | 1 |
| `CHTE` is 4 bytes; `BatteryControlKeyWrite` only carried one | 1 |
| Missing register burns the 3-write budget as if it were transient | 2 |
| Permanent incapability indistinguishable from a failed write | 2 |
| Reconcile re-pushes forever at hardware that can never accept it | 2 |
| Whole-branch review Minor 10 — `.unsupported` leaves the toggle on with no explanation | 3 |
| Reconcile loop re-checks unsupported hardware forever at its backoff floor | 3 |
