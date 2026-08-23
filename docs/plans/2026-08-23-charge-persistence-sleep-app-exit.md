# Charge Persistence Across App Exit, Sleep, and Helper Restart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the user-selected battery charge policy active across normal Wattly exit, sleep/wake, logout, fast user switching, and helper restart, while proving that disable, uninstall, and managed helper termination restore charging before control disappears.

**Architecture:** The root LaunchDaemon becomes the durable owner of the last configuration accepted from its installer UID. A testable `BatteryControlCoordinator` in `FanControlShared` commits configuration to a root-owned atomic JSON store before changing hardware, hydrates the engine from generation-specific SMC readback on startup/wake, and publishes structured maintenance evidence over the existing XPC status. A concrete `IORegisterForSystemPower` observer replaces the unreliable system-domain `NSWorkspace` observer, while app code remains the UI/command surface and never becomes necessary for sleep or helper-restart recovery.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, Foundation, AppKit, IOKit power management, AppleSMC, NSXPCConnection, launchd, XcodeGen

## Global Constraints

- Deployment target remains macOS 14.0 and Swift language mode remains Swift 6.
- Add no third-party dependency.
- Every SMC read/write stays inside `WattlyFanDaemon`; the app receives only Codable status over XPC.
- Normal Wattly exit always keeps the charge policy. Do not add an “앱 종료 시 해제” preference or termination hook.
- The helper installer UID is the single policy owner across logout and fast user switching. Another UID may not change policy until the user explicitly transfers ownership by reinstalling the helper.
- Persist exactly schema version, owner UID, normalized configuration, and update time at `/Library/Application Support/Wattly/battery-control-v1.json`; do not persist a guessed runtime inhibit flag.
- Commit a requested configuration durably before applying it to hardware. If persistence fails, leave the prior desired configuration and hardware policy in place.
- Treat SMC readback as authoritative at startup and wake. Never infer a charge-register generation from model, architecture, or macOS version.
- Keep the existing maximum of three consecutive routine SMC write failures. A new retry budget opens only on configure, helper startup, completed wake, or adapter transition; never re-arm from a flat timer forever.
- Battery sleep policy and fan sleep policy remain separate decisions even though one power observer delivers both events.
- `kIOMessageCanSystemSleep` and `kIOMessageSystemWillSleep` must always be acknowledged; Wattly never vetoes sleep.
- Disable, full uninstall, and managed helper termination complete only after actual readback says charging is allowed.
- New XPC status fields are optional and unknown enum values decode leniently, so current apps and already-installed helpers remain interoperable.
- A passing source test suite is not physical acceptance. Report sleep/wake, SIGKILL recovery, and generation-specific SMC verification separately.
- Preserve unrelated dirty-tree changes. Use target-scoped `git diff --check`; do not reset, delete, or rewrite user work.

---

## Scope and fixed product decisions

This is one cross-boundary safety feature, not three independent sub-projects. Persistence without hardware readback can restore the wrong belief; wake handling without persistence still fails after an app-less helper restart; uninstall safety depends on the same verified gate state. The tasks therefore land one tested vertical chain.

Fixed decisions from the design grill:

1. Normal app exit keeps the selected policy with no separate preference.
2. One installer UID owns the system-wide helper policy. A second user is blocked until an explicit ownership-transfer reinstall.
3. Missing, corrupt, wrong-owner, or unsupported-version persistence fails safe to a disabled desired policy and an attempted verified release.
4. The app may issue a newer configuration, but the helper store owns it while the app is absent and actual SMC readback owns claims about hardware.

## File structure

### Create

- `FanControlShared/BatteryPolicyPersistence.swift` — persisted schema, store protocol, atomic root-file implementation, and persistence errors.
- `FanControlShared/BatteryControlCoordinator.swift` — durable configure/restore/reconcile transaction and maintenance-record ownership.
- `FanControlShared/SystemPowerEvent.swift` — pure sleep/wake event vocabulary and separate fan/battery actions.
- `WattlyFanDaemon/SystemPowerObserver.swift` — `IORegisterForSystemPower` registration, acknowledgement, and typed event delivery.
- `WattlyTests/BatteryPolicyPersistenceTests.swift` — schema, atomic replacement, corruption, and permission tests.
- `WattlyTests/BatteryControlCoordinatorTests.swift` — commit ordering, startup restore, owner mismatch, failure, and termination-release tests.
- `WattlyTests/SystemPowerEventPolicyTests.swift` — pure power-event routing/acknowledgement decisions.

### Modify

- `FanControlShared/BatteryControlProtocol.swift` — capabilities, actual gate, maintenance record, desired configuration, and backward-compatible status fields.
- `FanControlShared/BatteryControlStatusReason.swift` — structured persistence/readback/ownership failure reasons.
- `FanControlShared/BatteryControlKeys.swift` — pure generation-specific readback parser.
- `FanControlShared/BatteryControlEngine.swift` — hardware read API, state hydration, boundary-scoped retry reset, and verified release.
- `FanControlShared/BatteryControlPolicy.swift` — full-configuration reconciliation and helper-capability decisions.
- `WattlyFanDaemon/BatteryControlHardware.swift` — read actual `CHTE`, `CH0B`, or `BCLM` state.
- `WattlyFanDaemon/SMCControlConnection.swift` — reject non-zero SMC result bytes on reads.
- `WattlyFanDaemon/FanControlDaemon.swift` — coordinator integration, startup restore, power events, status, and termination gating.
- `WattlyFanDaemon/main.swift` — construct the store/coordinator/power observer dependencies.
- `Wattly/Control/BatteryControlClient.swift` — status-returning apply, capability check, verified disable, and ownership/update failures.
- `Wattly/Control/FanHelperInstaller.swift` — installed-owner inspection, explicit transfer, and persisted-file removal during uninstall.
- `Wattly/Control/PrivilegedHelperInstallSession.swift` — pass explicit ownership transfer through the existing authenticated install session.
- `scripts/install-fan-helper.sh` — enforce ownership and verified-release gates before replacement.
- `scripts/uninstall-fan-helper.sh` — verify charging safety and remove the persisted policy.
- `Wattly/Views/BatteryControlBridge.swift` — new-helper status-first reconcile and legacy wake fallback; no app-exit release.
- `Wattly/Core/BatterySectionPresentation.swift` — pure maintenance/update/ownership presentation.
- `Wattly/Views/Settings/SettingsBatterySection.swift` — last maintenance row, retry/update/transfer actions.
- `Wattly/Core/AppUninstaller.swift` — verified release gate and throwing cleanup.
- `Wattly/Views/SettingsView.swift` — surface uninstall failure instead of swallowing it.
- `Wattly/Resources/Localizable.xcstrings` — exact maintenance, helper-update, ownership, and uninstall-failure strings.
- `Resources/com.dev.jjundev.WattlyFanDaemon.plist` and `Wattly/Control/FanHelperInstaller.swift` embedded template — keep `WATTLY_ALLOWED_UID` aligned.
- `project.yml` — no new target; verify all new files are included by directory sources.
- `docs/features/battery-management/06-charge-persistence-sleep-app-exit.md` — replace draft/open decisions with implemented behavior and explicit physical-verification limits.

### Existing tests to extend

- `WattlyTests/BatteryControlProtocolTests.swift`
- `WattlyTests/BatteryControlKeysTests.swift`
- `WattlyTests/BatteryControlEngineTests.swift`
- `WattlyTests/BatteryControlPolicyTests.swift`
- `WattlyTests/BatteryControlClientTests.swift`
- `WattlyTests/BatterySectionPresentationTests.swift`
- `WattlyTests/AppUninstallerTests.swift`
- `WattlyTests/FanControlProtocolTests.swift`
- `WattlyTests/LocalizationTests.swift`

## Validation command used throughout

This repository uses Swift Testing `@Test`; focused XCTest selectors have previously produced zero executed tests. Every red/green gate below therefore uses the full suite:

```bash
xcodegen generate
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
```

For an intentional red step, the expected result names the new failing assertion or missing symbol. For each green step, expected result is `** TEST SUCCEEDED **` with no zero-test claim.

---

### Task 1: Extend the Codable contract without breaking installed helpers

**Files:**
- Modify: `FanControlShared/BatteryControlProtocol.swift:3-112`
- Modify: `FanControlShared/BatteryControlStatusReason.swift:15-121`
- Modify: `WattlyTests/BatteryControlProtocolTests.swift`
- Modify: `WattlyTests/LocalizationTests.swift`

**Interfaces:**
- Consumes: existing `BatteryControlConfiguration`, `BatteryControlServiceStatus`, and lenient reason decoding.
- Produces: `BatteryControlCapability`, `BatteryHardwareGate`, `BatteryMaintenanceTrigger`, `BatteryMaintenanceResult`, `BatteryMaintenanceRecord`, and four optional status fields used by every later task.

- [ ] **Step 1: Add red protocol tests**

Append tests that round-trip every new field and decode a literal legacy payload with none of them:

```swift
@Test func persistenceMaintenanceFieldsRoundTrip() throws {
    let desired = BatteryControlConfiguration(
        enabled: true, limitPercentage: 85, lowerHysteresisDelta: 5)
    let maintenance = BatteryMaintenanceRecord(
        trigger: .wake,
        result: .verified,
        occurredAt: 1234,
        reason: nil)
    let input = BatteryControlServiceStatus(
        mode: .inhibited,
        currentPercentage: 85,
        isPowerAdapterConnected: true,
        detail: "충전 제한 85% 도달 (전원 어댑터 바이패스 구동)",
        updatedAt: 1234,
        appliedLimitPercentage: 85,
        isHardwareSupported: true,
        detailReason: .init(kind: .inhibitedAtLimit, limitPercentage: 85),
        activity: .holdingAtLimit,
        desiredConfiguration: desired,
        actualGate: .inhibited(appliedLimitPercentage: nil),
        lastMaintenance: maintenance,
        capabilities: [.persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1])

    let decoded = try BatteryControlCodec.decode(
        BatteryControlServiceStatus.self,
        from: BatteryControlCodec.encode(input))

    #expect(decoded.desiredConfiguration == desired)
    #expect(decoded.actualGate == .inhibited(appliedLimitPercentage: nil))
    #expect(decoded.lastMaintenance == maintenance)
    #expect(decoded.capabilities == [
        .persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1
    ])
}

@Test func currentAppDecodesLegacyHelperStatusWithoutPersistenceFields() throws {
    let legacy = Data(#"""
    {
      "mode":"charging",
      "currentPercentage":70,
      "isPowerAdapterConnected":true,
      "detail":"목표치(80%)까지 충전 중",
      "updatedAt":1
    }
    """#.utf8)

    let decoded = try BatteryControlCodec.decode(
        BatteryControlServiceStatus.self, from: legacy)

    #expect(decoded.desiredConfiguration == nil)
    #expect(decoded.actualGate == nil)
    #expect(decoded.lastMaintenance == nil)
    #expect(decoded.capabilities == nil)
}

@Test func unknownCapabilityDoesNotBreakTheWholeStatus() throws {
    let payload = Data(#"""
    {
      "mode":"charging",
      "currentPercentage":70,
      "isPowerAdapterConnected":true,
      "detail":"OK",
      "updatedAt":1,
      "capabilities":["future-capability"]
    }
    """#.utf8)
    let decoded = try BatteryControlCodec.decode(
        BatteryControlServiceStatus.self, from: payload)
    #expect(decoded.capabilities == [.unrecognized])
}
```

- [ ] **Step 2: Run the full suite and verify the red compile**

Run the validation command.

Expected: FAIL because `BatteryMaintenanceRecord`, `BatteryHardwareGate`, and the new status initializer arguments do not exist.

- [ ] **Step 3: Add the exact shared types and optional status fields**

Add these definitions above `BatteryControlServiceStatus`:

```swift
public enum BatteryControlCapability: String, Codable, Equatable, Sendable {
    case persistedPolicyV1 = "persisted-policy-v1"
    case hardwareGateReadbackV1 = "hardware-gate-readback-v1"
    case systemPowerEventsV1 = "system-power-events-v1"
    case unrecognized

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unrecognized
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct BatteryHardwareGate: Codable, Equatable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
        case allowed
        case inhibited
        case unreadable
        case unrecognized

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: raw) ?? .unrecognized
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public var state: State
    public var appliedLimitPercentage: Int?

    public static let allowed = Self(state: .allowed, appliedLimitPercentage: nil)
    public static let unreadable = Self(state: .unreadable, appliedLimitPercentage: nil)

    public static func inhibited(appliedLimitPercentage: Int?) -> Self {
        Self(state: .inhibited, appliedLimitPercentage: appliedLimitPercentage)
    }
}

public enum BatteryMaintenanceTrigger: String, Codable, Equatable, Sendable {
    case startup
    case wake
    case clientConfiguration
    case adapterTransition
    case termination
    case unrecognized

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unrecognized
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum BatteryMaintenanceResult: String, Codable, Equatable, Sendable {
    case verified
    case applied
    case released
    case failed
    case skipped
    case unrecognized

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unrecognized
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum BatteryReleaseVerdict: String, Codable, Equatable, Sendable {
    case verifiedAllowed
    case notControllable
    case failed
    case unrecognized

    public var isSafeToRemove: Bool {
        self == .verifiedAllowed || self == .notControllable
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unrecognized
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct BatteryMaintenanceRecord: Codable, Equatable, Sendable {
    public var trigger: BatteryMaintenanceTrigger
    public var result: BatteryMaintenanceResult
    public var occurredAt: TimeInterval
    public var reason: BatteryControlStatusReason?

    public init(
        trigger: BatteryMaintenanceTrigger,
        result: BatteryMaintenanceResult,
        occurredAt: TimeInterval,
        reason: BatteryControlStatusReason?
    ) {
        self.trigger = trigger
        self.result = result
        self.occurredAt = occurredAt
        self.reason = reason
    }
}
```

Add these optional properties and defaulted initializer arguments to `BatteryControlServiceStatus`:

```swift
public var desiredConfiguration: BatteryControlConfiguration?
public var actualGate: BatteryHardwareGate?
public var releaseVerdict: BatteryReleaseVerdict?
public var lastMaintenance: BatteryMaintenanceRecord?
public var capabilities: [BatteryControlCapability]?
```

Use synthesized Codable for the containing structs; optional fields decode as `nil` when an old helper omitted them. Add a payload test with future `actualGate.state`, release verdict, maintenance trigger, and maintenance result strings; it must decode the whole status and map each to `.unrecognized`. Engine/UI switches treat unrecognized safety values as failure, never as success.

Add these reason kinds and exact legacy Korean text:

```swift
case persistenceReadFailed
case persistenceWriteFailed
case policyOwnerMismatch
case hardwareReadbackFailed
```

```swift
case .persistenceReadFailed: return "저장된 충전 정책을 읽지 못해 충전 허용 상태로 복구합니다"
case .persistenceWriteFailed: return "충전 정책을 안전하게 저장하지 못했습니다"
case .policyOwnerMismatch: return "다른 사용자가 이 Mac의 충전 정책을 관리하고 있습니다"
case .hardwareReadbackFailed: return "충전 제어 하드웨어 상태를 확인하지 못했습니다"
```

- [ ] **Step 4: Extend localization coverage and run green**

Add the four exact Korean strings above as String Catalog keys, with these English values:

```text
Stored charge policy could not be read; charging will be restored
Charge policy could not be saved safely
Another user manages this Mac's charge policy
Charge-control hardware state could not be verified
```

Extend `LocalizationTests.batteryStatusReasonTranslations` to cover the new kinds. Run the validation command.

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit the protocol slice**

```bash
git add FanControlShared/BatteryControlProtocol.swift \
  FanControlShared/BatteryControlStatusReason.swift \
  Wattly/Resources/Localizable.xcstrings \
  WattlyTests/BatteryControlProtocolTests.swift \
  WattlyTests/LocalizationTests.swift
git commit -m "feat(battery): define persistent policy status contract"
```

---

### Task 2: Add the root-owned atomic policy store

**Files:**
- Create: `FanControlShared/BatteryPolicyPersistence.swift`
- Create: `WattlyTests/BatteryPolicyPersistenceTests.swift`

**Interfaces:**
- Consumes: normalized `BatteryControlConfiguration`.
- Produces: `PersistedBatteryPolicy`, `BatteryPolicyStoring.load()`, `save(_:)`, `remove()`, and `BatteryPolicyFileStore.defaultURL`.

- [ ] **Step 1: Write red schema and filesystem tests**

Create tests with one temporary directory per test:

```swift
import Darwin
import Foundation
import Testing
@testable import Wattly

@Suite struct BatteryPolicyPersistenceTests {
    private func temporaryStore() throws -> (
        directory: URL, store: BatteryPolicyFileStore
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wattly-policy-\(UUID().uuidString)")
        return (directory, BatteryPolicyFileStore(
            fileURL: directory.appendingPathComponent("battery-control-v1.json")))
    }

    @Test func roundTripNormalizesConfigurationAndKeepsOwner() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.save(.init(
            ownerUID: 501,
            configuration: .init(
                enabled: true, limitPercentage: 110, lowerHysteresisDelta: 20),
            updatedAt: 10))

        let loaded = try #require(store.load())
        #expect(loaded.schemaVersion == 1)
        #expect(loaded.ownerUID == 501)
        #expect(loaded.configuration.limitPercentage == 100)
        #expect(loaded.configuration.lowerHysteresisDelta == 10)
    }

    @Test func savedFileIsOwnerReadWriteOnly() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.save(.init(ownerUID: 501, configuration: .init(), updatedAt: 10))

        let attributes = try FileManager.default.attributesOfItem(
            atPath: store.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func secondSaveAtomicallyReplacesTheFirstPayload() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.save(.init(
            ownerUID: 501,
            configuration: .init(enabled: true, limitPercentage: 80),
            updatedAt: 1))
        try store.save(.init(
            ownerUID: 501,
            configuration: .init(enabled: false, limitPercentage: 100),
            updatedAt: 2))

        let loaded = try #require(store.load())
        #expect(loaded.updatedAt == 2)
        #expect(loaded.configuration.enabled == false)
        #expect(try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil).count == 1)
    }

    @Test func corruptPayloadThrowsInsteadOfPretendingThereIsNoPolicy() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: store.fileURL)

        #expect(throws: BatteryPolicyStoreError.self) {
            _ = try store.load()
        }
    }
}
```

- [ ] **Step 2: Run the full suite and verify red**

Expected: FAIL because `BatteryPolicyFileStore`, `PersistedBatteryPolicy`, and `BatteryPolicyStoreError` do not exist.

- [ ] **Step 3: Implement the schema and store protocol**

Create:

```swift
import Darwin
import Foundation

public struct PersistedBatteryPolicy: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var ownerUID: UInt32
    public var configuration: BatteryControlConfiguration
    public var updatedAt: TimeInterval

    public init(
        ownerUID: UInt32,
        configuration: BatteryControlConfiguration,
        updatedAt: TimeInterval
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.ownerUID = ownerUID
        self.configuration = configuration.normalized
        self.updatedAt = updatedAt
    }
}

public enum BatteryPolicyStoreError: Error, Equatable {
    case unsupportedSchema(Int)
    case unreadablePayload
    case fileOperation(errno: Int32)
    case rollbackFailed(errno: Int32)
}

public protocol BatteryPolicyStoring: Sendable {
    func load() throws -> PersistedBatteryPolicy?
    func save(_ policy: PersistedBatteryPolicy) throws
    func remove() throws
}
```

- [ ] **Step 4: Implement atomic same-directory replacement**

Implement `BatteryPolicyFileStore` with these exact invariants:

```swift
public final class BatteryPolicyFileStore: BatteryPolicyStoring, @unchecked Sendable {
    public static let defaultURL = URL(
        fileURLWithPath: "/Library/Application Support/Wattly",
        isDirectory: true
    ).appendingPathComponent("battery-control-v1.json")

    public let fileURL: URL
    private let fileManager: FileManager
    private let synchronizeDirectory: @Sendable (URL) throws -> Void

    public init(
        fileURL: URL = Self.defaultURL,
        fileManager: FileManager = .default,
        synchronizeDirectory: @escaping @Sendable (URL) throws -> Void
            = Self.fsyncDirectory
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.synchronizeDirectory = synchronizeDirectory
    }

    public func load() throws -> PersistedBatteryPolicy? {
        let previousURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".battery-control.previous")
        if fileManager.fileExists(atPath: previousURL.path) {
            guard rename(previousURL.path, fileURL.path) == 0 else {
                throw BatteryPolicyStoreError.rollbackFailed(errno: errno)
            }
            try synchronizeDirectory(fileURL.deletingLastPathComponent())
        }
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let policy = try JSONDecoder().decode(
                PersistedBatteryPolicy.self,
                from: Data(contentsOf: fileURL))
            guard policy.schemaVersion == PersistedBatteryPolicy.currentSchemaVersion else {
                throw BatteryPolicyStoreError.unsupportedSchema(policy.schemaVersion)
            }
            return policy
        } catch let error as BatteryPolicyStoreError {
            throw error
        } catch {
            throw BatteryPolicyStoreError.unreadablePayload
        }
    }

    public func save(_ policy: PersistedBatteryPolicy) throws {
        let normalized = PersistedBatteryPolicy(
            ownerUID: policy.ownerUID,
            configuration: policy.configuration,
            updatedAt: policy.updatedAt)
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        guard chmod(directory.path, 0o755) == 0 else {
            throw BatteryPolicyStoreError.fileOperation(errno: errno)
        }
        try synchronizeDirectory(directory)

        let temporaryURL = directory.appendingPathComponent(
            ".battery-control-\(UUID().uuidString).tmp")
        let data = try JSONEncoder().encode(normalized)
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600])
        else {
            throw BatteryPolicyStoreError.fileOperation(errno: errno)
        }

        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard chmod(temporaryURL.path, 0o600) == 0 else {
                throw BatteryPolicyStoreError.fileOperation(errno: errno)
            }
            try replaceDurably(
                temporaryURL: temporaryURL,
                directory: directory)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    public func remove() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
        try synchronizeDirectory(fileURL.deletingLastPathComponent())
    }

    private static func fsyncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw BatteryPolicyStoreError.fileOperation(errno: errno)
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw BatteryPolicyStoreError.fileOperation(errno: errno)
        }
    }

    private func replaceDurably(
        temporaryURL: URL,
        directory: URL
    ) throws {
        let previousURL = directory.appendingPathComponent(
            ".battery-control.previous")
        try? fileManager.removeItem(at: previousURL)
        let hadPrevious = fileManager.fileExists(atPath: fileURL.path)
        if hadPrevious {
            guard link(fileURL.path, previousURL.path) == 0 else {
                throw BatteryPolicyStoreError.fileOperation(errno: errno)
            }
            try synchronizeDirectory(directory)
        }
        guard rename(temporaryURL.path, fileURL.path) == 0 else {
            try? fileManager.removeItem(at: previousURL)
            throw BatteryPolicyStoreError.fileOperation(errno: errno)
        }
        do {
            try synchronizeDirectory(directory)
        } catch {
            if hadPrevious {
                guard rename(previousURL.path, fileURL.path) == 0 else {
                    throw BatteryPolicyStoreError.rollbackFailed(errno: errno)
                }
            } else {
                try fileManager.removeItem(at: fileURL)
            }
            try synchronizeDirectory(directory)
            throw error
        }
        try? fileManager.removeItem(at: previousURL)
    }
}
```

Inject a directory-sync closure that succeeds for setup/backup and throws only on the post-rename call. With a prior 80% file and a requested 90% file, assert `save` throws and `load()` still returns 80%. Repeat with no prior file and assert the canonical path is absent after failure. Simulate a crash with both canonical and `.battery-control.previous`; `load()` must restore/decode the previous file before considering canonical. In `BatteryControlCoordinatorTests`, inject that store and assert engine configuration/hardware remain unchanged. A rollback failure is a distinct fatal `BatteryPolicyStoreError.rollbackFailed`; coordinator performs verified release, marks itself unsafe to serve, and `FanControlDaemon` exits before accepting another XPC request so launchd startup can recover the previous file.

- [ ] **Step 5: Run green and inspect file scope**

Run the validation command, then:

```bash
git diff --check -- FanControlShared/BatteryPolicyPersistence.swift \
  WattlyTests/BatteryPolicyPersistenceTests.swift
```

Expected: tests succeed and `git diff --check` prints nothing.

- [ ] **Step 6: Commit the persistence store**

```bash
git add FanControlShared/BatteryPolicyPersistence.swift \
  WattlyTests/BatteryPolicyPersistenceTests.swift
git commit -m "feat(battery): add atomic helper policy store"
```

---

### Task 3: Hydrate the engine from actual gate state and verify release

**Files:**
- Modify: `FanControlShared/BatteryControlEngine.swift:3-248`
- Modify: `WattlyTests/BatteryControlEngineTests.swift`

**Interfaces:**
- Consumes: `BatteryHardwareGate`.
- Produces: `BatteryControlHardwareProtocol.readChargingGate(targetLimit:)`, `BatteryControlEngine.beginRecoveryWindow()`, `hydrateHardwareState()`, `verifyAndUpdate(currentSoC:isPluggedIn:)`, `releaseVerified()`, and `configuration`.

- [ ] **Step 1: Extend the mock and add red behavior tests**

Extend `MockBatteryHardware`:

```swift
var reportedGate: BatteryHardwareGate = .allowed

func readChargingGate(targetLimit: Int) -> BatteryHardwareGate {
    reportedGate
}
```

Add tests:

```swift
@Test func wakeHydratesAnExistingHoldAndKeepsItInsideTheBand() {
    let hardware = MockBatteryHardware()
    hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
    hardware.chargingInhibited = true
    let engine = BatteryControlEngine(
        hardware: hardware,
        initialConfig: .init(
            enabled: true, limitPercentage: 85, lowerHysteresisDelta: 2))

    let status = engine.verifyAndUpdate(currentSoC: 84, isPluggedIn: true)

    #expect(status.mode == .inhibited)
    #expect(hardware.writeCount == 0)
    #expect(status.actualGate == .inhibited(appliedLimitPercentage: nil))
}

@Test func wakeHydratesAllowedGateAndDoesNotInventAHoldInsideTheBand() {
    let hardware = MockBatteryHardware()
    hardware.reportedGate = .allowed
    let engine = BatteryControlEngine(
        hardware: hardware,
        initialConfig: .init(
            enabled: true, limitPercentage: 85, lowerHysteresisDelta: 2))

    let status = engine.verifyAndUpdate(currentSoC: 84, isPluggedIn: true)

    #expect(status.mode == .charging)
    #expect(hardware.writeCount == 0)
}

@Test func unreadableGateBuildsAKnownAllowedBaselineBeforeEvaluation() {
    let hardware = MockBatteryHardware()
    hardware.reportedGate = .unreadable
    let engine = BatteryControlEngine(
        hardware: hardware,
        initialConfig: .init(enabled: true, limitPercentage: 85))

    _ = engine.verifyAndUpdate(currentSoC: 80, isPluggedIn: true)

    #expect(hardware.writeCount == 1)
    #expect(hardware.chargingInhibited == false)
}

@Test func verifiedReleaseReturnsFailedWhenReadbackStillSaysInhibited() {
    let hardware = MockBatteryHardware()
    hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
    hardware.releaseVerdict = .failed
    let engine = BatteryControlEngine(hardware: hardware)

    #expect(engine.releaseVerified() == .failed)
}
```

Make the mock count reads, expose a write hook for ordering tests, and update readback only after successful writes:

```swift
var readCount = 0
var onWrite: (() -> Void)?
var holdReportedGateAfterWrite = false

func readChargingGate(targetLimit: Int) -> BatteryHardwareGate {
    readCount += 1
    return reportedGate
}

func setChargingInhibited(_ inhibited: Bool, targetLimit: Int) -> Bool {
    writeCount += 1
    onWrite?()
    if writeShouldFail { return false }
    chargingInhibited = inhibited
    appliedLimit = targetLimit
    if !holdReportedGateAfterWrite {
        reportedGate = inhibited
            ? .inhibited(appliedLimitPercentage:
                registerSet == .intel ? targetLimit : nil)
            : .allowed
    }
    return true
}
```

- [ ] **Step 2: Run the suite and verify red**

Expected: FAIL because the hardware read method and new engine methods do not exist.

- [ ] **Step 3: Add readback to the hardware protocol and expose configuration**

```swift
public protocol BatteryControlHardwareProtocol: Sendable {
    var registerSet: BatteryControlRegisterSet { get }
    func readChargingGate(targetLimit: Int) -> BatteryHardwareGate
    func setChargingInhibited(_ inhibited: Bool, targetLimit: Int) -> Bool
    func releaseChargingControlAndVerify() -> BatteryReleaseVerdict
}
```

Inside the engine:

```swift
public var configuration: BatteryControlConfiguration { config }

public func beginRecoveryWindow() {
    consecutiveWriteFailures = 0
    lastWriteFailed = false
}
```

Replace the duplicated latch reset at the start of `configure` with `beginRecoveryWindow()`.

Remove the eager release write currently inside `configure` when enabled changes to false. `configure` becomes a pure desired-state update plus one recovery-window reset; `update` performs ordinary transitions and the coordinator’s disabled command path calls `releaseVerified()`. This prevents one unverified eager write plus another verified release from exceeding the three-write window.

- [ ] **Step 4: Implement verified hydration and release**

Add `private var lastVerifiedGate: BatteryHardwareGate?`. Every successful SMC transition must be followed by matching readback inside `attemptWrite`; a write acknowledgement alone is not proof:

```swift
private func gateMatches(
    _ gate: BatteryHardwareGate,
    inhibited: Bool,
    targetLimit: Int
) -> Bool {
    if inhibited {
        guard gate.state == .inhibited else { return false }
        return gate.appliedLimitPercentage.map { $0 == targetLimit } ?? true
    }
    return gate.state == .allowed
}

private func attemptWrite(inhibited: Bool, targetLimit: Int) -> Bool {
    guard !isWriteLatched else { return false }
    guard hardware.setChargingInhibited(
        inhibited, targetLimit: targetLimit)
    else {
        consecutiveWriteFailures += 1
        lastWriteFailed = true
        return false
    }
    let verified = hardware.readChargingGate(targetLimit: targetLimit)
    guard gateMatches(
        verified,
        inhibited: inhibited,
        targetLimit: targetLimit)
    else {
        consecutiveWriteFailures += 1
        lastWriteFailed = true
        lastVerifiedGate = verified
        return false
    }
    lastVerifiedGate = verified
    consecutiveWriteFailures = 0
    lastWriteFailed = false
    return true
}
```

Then add:

```swift
public func verifyAndUpdate(
    currentSoC: Int,
    isPluggedIn: Bool
) -> BatteryControlServiceStatus {
    let gate = hardware.readChargingGate(
        targetLimit: config.clampedLimitPercentage)
    lastVerifiedGate = gate

    switch gate.state {
    case .allowed:
        isCurrentlyInhibited = false
        hasInitializedState = true
    case .inhibited:
        let staleIntelLimit = gate.appliedLimitPercentage.map {
            $0 != config.clampedLimitPercentage
        } ?? false
        if staleIntelLimit {
            guard attemptWrite(inhibited: false, targetLimit: 100) else {
                hasInitializedState = false
                return status(
                    currentSoC: currentSoC,
                    isPluggedIn: isPluggedIn,
                    target: config.clampedLimitPercentage,
                    actualGate: gate)
            }
            isCurrentlyInhibited = false
        } else {
            isCurrentlyInhibited = true
        }
        hasInitializedState = true
    case .unreadable, .unrecognized:
        guard attemptWrite(inhibited: false, targetLimit: 100) else {
            hasInitializedState = false
            return verificationFailureStatus(
                currentSoC: currentSoC,
                isPluggedIn: isPluggedIn)
        }
        isCurrentlyInhibited = false
        hasInitializedState = true
    }

    return update(currentSoC: currentSoC, isPluggedIn: isPluggedIn)
}

public func releaseVerified() -> BatteryReleaseVerdict {
    guard !isWriteLatched else { return .failed }
    let verdict = hardware.releaseChargingControlAndVerify()
    guard verdict.isSafeToRemove else {
        consecutiveWriteFailures += 1
        lastWriteFailed = true
        return verdict
    }
    isCurrentlyInhibited = false
    hasInitializedState = true
    beginRecoveryWindow()
    lastVerifiedGate = verdict == .verifiedAllowed ? .allowed : .unreadable
    return verdict
}
```

Add `verificationFailureStatus` that returns `.unsupported`, `appliedLimitPercentage: nil`, `detailReason: .hardwareReadbackFailed`, and `actualGate: lastVerifiedGate ?? .unreadable`. Extend the normal private `status` builder to publish only `lastVerifiedGate`; never synthesize `actualGate` from `isCurrentlyInhibited`. Because `attemptWrite` verifies every transition, a successful routine update refreshes `lastVerifiedGate` before status publication.

Also extract the read/switch portion of `verifyAndUpdate` into:

```swift
@discardableResult
public func hydrateHardwareState() -> BatteryHardwareGate {
    let gate = hardware.readChargingGate(
        targetLimit: config.clampedLimitPercentage)
    lastVerifiedGate = gate
    switch gate.state {
    case .allowed:
        isCurrentlyInhibited = false
        hasInitializedState = true
    case .inhibited:
        isCurrentlyInhibited = true
        hasInitializedState = true
    case .unreadable, .unrecognized:
        if attemptWrite(inhibited: false, targetLimit: 100) {
            isCurrentlyInhibited = false
            hasInitializedState = true
        } else {
            hasInitializedState = false
        }
    }
    return lastVerifiedGate ?? .unreadable
}
```

`verifyAndUpdate` calls this first, then handles a stale Intel limit and evaluates SoC. This separate method is required for helper startup when IOKit has not produced a power-source reading yet: it can preserve a readable active hold without pretending the battery is at 0% and unplugged.

Extend the mock:

```swift
var releaseVerdict: BatteryReleaseVerdict = .verifiedAllowed
var releaseAttemptCount = 0

func releaseChargingControlAndVerify() -> BatteryReleaseVerdict {
    releaseAttemptCount += 1
    if releaseVerdict.isSafeToRemove {
        chargingInhibited = false
        appliedLimit = 100
        reportedGate = releaseVerdict == .verifiedAllowed
            ? .allowed : .unreadable
    }
    return releaseVerdict
}
```

Tests cover `.verifiedAllowed`, `.notControllable`, and `.failed`; only the first two may let coordinator termination or uninstall proceed.

- [ ] **Step 5: Run all engine regressions green**

Run the validation command.

Expected: `** TEST SUCCEEDED **`, including unchanged hysteresis, unsupported-hardware, and three-write-latch tests.

- [ ] **Step 6: Commit the engine seam**

```bash
git add FanControlShared/BatteryControlEngine.swift \
  WattlyTests/BatteryControlEngineTests.swift
git commit -m "feat(battery): hydrate control from hardware readback"
```

---

### Task 4: Parse and read every supported charge-register generation

**Files:**
- Modify: `FanControlShared/BatteryControlKeys.swift:84-205`
- Modify: `WattlyFanDaemon/BatteryControlHardware.swift:4-62`
- Modify: `WattlyFanDaemon/SMCControlConnection.swift:51-65`
- Modify: `WattlyTests/BatteryControlKeysTests.swift`

**Interfaces:**
- Consumes: `BatteryHardwareGate` and existing runtime-probed `BatteryControlRegisterSet`.
- Produces: `BatteryControlKeys.readGate(registerSet:read:)` and production `readChargingGate(targetLimit:)`.

- [ ] **Step 1: Add red table tests for modern, legacy, Intel, and malformed replies**

```swift
@Test func modernReadbackUsesTheFourByteCHTEGate() {
    let gate = BatteryControlKeys.readGate(registerSet: .modern) { key in
        key == "CHTE" ? (type: "ui32", bytes: [1, 0, 0, 0]) : nil
    }
    #expect(gate == .inhibited(appliedLimitPercentage: nil))
}

@Test func legacyReadbackUsesCH0BAndRejectsUnknownBytes() {
    let allowed = BatteryControlKeys.readGate(registerSet: .legacy) { _ in
        (type: "ui8 ", bytes: [0])
    }
    let malformed = BatteryControlKeys.readGate(registerSet: .legacy) { _ in
        (type: "ui8 ", bytes: [7])
    }
    #expect(allowed == .allowed)
    #expect(malformed == .unreadable)
}

@Test func intelReadbackCarriesTheAppliedBCLMLimit() {
    let gate = BatteryControlKeys.readGate(registerSet: .intel) { _ in
        (type: "ui8 ", bytes: [85])
    }
    #expect(gate == .inhibited(appliedLimitPercentage: 85))
}

@Test func handsOffRegisterSetsHaveNoReadableGate() {
    for registerSet: BatteryControlRegisterSet in [.firmwareManaged, .unsupported] {
        #expect(BatteryControlKeys.readGate(registerSet: registerSet) { _ in nil }
                == .unreadable)
    }
}
```

- [ ] **Step 2: Run the suite and verify red**

Expected: FAIL because `BatteryControlKeys.readGate` does not exist.

- [ ] **Step 3: Implement the pure parser**

```swift
public static func readGate(
    registerSet: BatteryControlRegisterSet,
    read: (String) -> (type: String, bytes: [UInt8])?
) -> BatteryHardwareGate {
    switch registerSet {
    case .modern:
        guard let raw = read("CHTE"), raw.bytes.count == 4 else {
            return .unreadable
        }
        switch raw.bytes[0] {
        case 0: return .allowed
        case 1: return .inhibited(appliedLimitPercentage: nil)
        default: return .unreadable
        }
    case .legacy:
        guard let byte = read("CH0B")?.bytes.first else {
            return .unreadable
        }
        switch byte {
        case 0: return .allowed
        case 2: return .inhibited(appliedLimitPercentage: nil)
        default: return .unreadable
        }
    case .intel:
        guard let byte = read("BCLM")?.bytes.first else {
            return .unreadable
        }
        if byte == 100 { return .allowed }
        guard (50...99).contains(Int(byte)) else { return .unreadable }
        return .inhibited(appliedLimitPercentage: Int(byte))
    case .firmwareManaged, .unsupported:
        return .unreadable
    }
}
```

- [ ] **Step 4: Wire production hardware to the parser**

First tighten the shared raw SMC read primitive. Replace its read-reply guard with:

```swift
let readReply = callStruct(&request)
guard readReply.kernel == KERN_SUCCESS,
      readReply.output.result == 0
else { return nil }
```

This applies to every daemon SMC read, not only battery keys; kernel success with a non-zero SMC result is a failed read and must never become zero-filled `.allowed`.

Add to `SMCBatteryControlHardware`:

```swift
public func readChargingGate(targetLimit: Int) -> BatteryHardwareGate {
    BatteryControlKeys.readGate(registerSet: registerSet) { [smc] key in
        smc.read(key)
    }
}
```

`targetLimit` intentionally does not influence parsing; Intel returns the actual stored ceiling so the engine can compare it.

Store the drivable register discovered beneath `.firmwareManaged` as `private let safetyReleaseRegisterSet` instead of discarding it after init. Implement the removal verdict:

```swift
public func releaseChargingControlAndVerify() -> BatteryReleaseVerdict {
    let releaseRegisterSet: BatteryControlRegisterSet
    switch registerSet {
    case .modern, .legacy, .intel:
        releaseRegisterSet = registerSet
    case .firmwareManaged:
        releaseRegisterSet = safetyReleaseRegisterSet
    case .unsupported:
        return .notControllable
    }
    guard releaseRegisterSet.canDriveCharging else {
        return .notControllable
    }
    let writes = BatteryControlKeys.writes(
        inhibited: false,
        registerSet: releaseRegisterSet,
        targetLimit: 100)
    for write in writes {
        let reply = smc.write(write.key, bytes: write.bytes)
        let succeeded = reply?.kernel == KERN_SUCCESS
            && reply?.smcResult == 0
        if write.isRequired && !succeeded { return .failed }
    }
    let gate = BatteryControlKeys.readGate(
        registerSet: releaseRegisterSet,
        read: { [smc] key in smc.read(key) })
    return gate.state == .allowed ? .verifiedAllowed : .failed
}
```

For `.firmwareManaged`, this replaces the current ignored one-shot result with a reusable verified safe-release path. `.notControllable` is allowed only when no drivable register exists; a present register with failed write/readback returns `.failed`.

- [ ] **Step 5: Regenerate, build both targets, and run tests**

Run the validation command.

Expected: app, daemon, and tests compile; suite ends with `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit generation readback**

```bash
git add FanControlShared/BatteryControlKeys.swift WattlyFanDaemon/BatteryControlHardware.swift WattlyFanDaemon/SMCControlConnection.swift WattlyTests/BatteryControlKeysTests.swift
git commit -m "feat(battery): read back charge gate generations"
```

---

### Task 5: Add the durable battery-control coordinator

**Files:**
- Create: `FanControlShared/BatteryControlCoordinator.swift`
- Create: `WattlyTests/BatteryControlCoordinatorTests.swift`

**Interfaces:**
- Consumes: `BatteryPolicyStoring`, `BatteryControlEngine`, installer UID, clock, current SoC, adapter state.
- Produces: `restore(currentSoC:isPluggedIn:)`, `restoreWithoutPowerReading()`, `configure(_:trigger:currentSoC:isPluggedIn:)`, `configureWithoutPowerReading(_:trigger:)`, `sample(currentSoC:isPluggedIn:)`, `reconcile(trigger:currentSoC:isPluggedIn:)`, `releaseForTermination()`, `needsSampling`, and `latestStatus`.

- [ ] **Step 1: Create spies and red transaction tests**

Use synchronous test doubles because the daemon already serializes coordinator calls:

```swift
final class PolicyStoreSpy: BatteryPolicyStoring, @unchecked Sendable {
    var stored: PersistedBatteryPolicy?
    var events: [String] = []
    var saveError: Error?
    var loadError: Error?
    var onSave: (() -> Void)?

    func load() throws -> PersistedBatteryPolicy? {
        if let loadError { throw loadError }
        events.append("load")
        return stored
    }

    func save(_ policy: PersistedBatteryPolicy) throws {
        events.append("save")
        onSave?()
        if let saveError { throw saveError }
        stored = policy
    }

    func remove() throws {
        events.append("remove")
        stored = nil
    }
}
```

Add these tests:

```swift
@Test func configurePersistsBeforeTheFirstHardwareWrite() {
    final class OrderedEvents: @unchecked Sendable {
        var values: [String] = []
    }
    let ordered = OrderedEvents()
    let hardware = MockBatteryHardware()
    hardware.onWrite = { ordered.values.append("write") }
    let store = PolicyStoreSpy()
    store.onSave = { ordered.values.append("save") }
    let coordinator = BatteryControlCoordinator(
        ownerUID: 501,
        store: store,
        engine: BatteryControlEngine(hardware: hardware),
        now: { 100 })

    _ = coordinator.configure(
        .init(enabled: true, limitPercentage: 80),
        trigger: .clientConfiguration,
        currentSoC: 80,
        isPluggedIn: true)

    #expect(Array(ordered.values.prefix(2)) == ["save", "write"])
}

@Test func saveFailureLeavesTheOldConfigurationAndHardwareAlone() {
    let hardware = MockBatteryHardware()
    let store = PolicyStoreSpy()
    store.saveError = BatteryPolicyStoreError.fileOperation(errno: EIO)
    let engine = BatteryControlEngine(hardware: hardware)
    let coordinator = BatteryControlCoordinator(
        ownerUID: 501, store: store, engine: engine, now: { 100 })

    let status = coordinator.configure(
        .init(enabled: true, limitPercentage: 80),
        trigger: .clientConfiguration,
        currentSoC: 80,
        isPluggedIn: true)

    #expect(engine.configuration.enabled == false)
    #expect(hardware.writeCount == 0)
    #expect(status.lastMaintenance?.reason?.kind == .persistenceWriteFailed)
}

@Test func startupRestoresMatchingOwnerPolicyWithoutTheApp() {
    let hardware = MockBatteryHardware()
    hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
    let store = PolicyStoreSpy()
    store.stored = .init(
        ownerUID: 501,
        configuration: .init(enabled: true, limitPercentage: 85),
        updatedAt: 10)
    let coordinator = BatteryControlCoordinator(
        ownerUID: 501,
        store: store,
        engine: BatteryControlEngine(hardware: hardware),
        now: { 100 })

    let status = coordinator.restore(currentSoC: 84, isPluggedIn: true)

    #expect(status.desiredConfiguration?.enabled == true)
    #expect(status.mode == .inhibited)
    #expect(status.lastMaintenance?.trigger == .startup)
}

@Test func wrongOwnerFailsSafeToDisabledAndVerifiedRelease() {
    let hardware = MockBatteryHardware()
    hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
    let store = PolicyStoreSpy()
    store.stored = .init(
        ownerUID: 502,
        configuration: .init(enabled: true, limitPercentage: 80),
        updatedAt: 10)
    let coordinator = BatteryControlCoordinator(
        ownerUID: 501,
        store: store,
        engine: BatteryControlEngine(hardware: hardware),
        now: { 100 })

    let status = coordinator.restore(currentSoC: 80, isPluggedIn: true)

    #expect(status.desiredConfiguration?.enabled == false)
    #expect(status.lastMaintenance?.reason?.kind == .policyOwnerMismatch)
    #expect(hardware.chargingInhibited == false)
}

@Test func startupWithoutPowerReadingPreservesAReadableEnabledHold() {
    let hardware = MockBatteryHardware()
    hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
    hardware.chargingInhibited = true
    let store = PolicyStoreSpy()
    store.stored = .init(
        ownerUID: 501,
        configuration: .init(enabled: true, limitPercentage: 85),
        updatedAt: 10)
    let coordinator = BatteryControlCoordinator(
        ownerUID: 501,
        store: store,
        engine: BatteryControlEngine(hardware: hardware),
        now: { 100 })

    let status = coordinator.restoreWithoutPowerReading()

    #expect(status.desiredConfiguration?.enabled == true)
    #expect(status.actualGate?.state == .inhibited)
    #expect(hardware.writeCount == 0)
    #expect(status.detailReason?.kind == .powerSourceUnreadable)
}
```

- [ ] **Step 2: Run the suite and verify red**

Expected: FAIL because `BatteryControlCoordinator` does not exist.

- [ ] **Step 3: Implement coordinator construction and status decoration**

Create the class with immutable dependencies and the advertised capabilities:

```swift
import Foundation

public final class BatteryControlCoordinator: @unchecked Sendable {
    public static let capabilities: [BatteryControlCapability] = [
        .persistedPolicyV1,
        .hardwareGateReadbackV1,
        .systemPowerEventsV1,
    ]

    private let ownerUID: UInt32
    private let store: any BatteryPolicyStoring
    private let engine: BatteryControlEngine
    private let now: @Sendable () -> TimeInterval

    public private(set) var latestStatus: BatteryControlServiceStatus
    public private(set) var isSafeToServe = true

    public var needsSampling: Bool {
        engine.needsSampling
            || latestStatus.releaseVerdict == .failed
            || latestStatus.actualGate?.state == .inhibited
    }

    public init(
        ownerUID: UInt32,
        store: any BatteryPolicyStoring,
        engine: BatteryControlEngine,
        now: @escaping @Sendable () -> TimeInterval
    ) {
        self.ownerUID = ownerUID
        self.store = store
        self.engine = engine
        self.now = now
        self.latestStatus = BatteryControlServiceStatus(
            mode: .unavailable,
            currentPercentage: 0,
            isPowerAdapterConnected: false,
            detail: BatteryControlStatusReason(kind: .initializing).legacyKoreanDetail,
            updatedAt: 0,
            detailReason: .init(kind: .initializing),
            capabilities: Self.capabilities)
    }
}
```

Add a single `publish(_:trigger:result:reason:)` helper that fills `desiredConfiguration`, `lastMaintenance`, and `capabilities` on a copy of the engine status. Do not persist maintenance history. When store save/load throws `.rollbackFailed`, set `isSafeToServe = false`, perform `releaseForTermination()`, and publish persistence failure. Ordinary decode/schema/write failures remain recoverable and do not flip this fatal flag.

- [ ] **Step 4: Implement restore and persist-before-apply configure**

Use this control flow:

```swift
public func restore(
    currentSoC: Int,
    isPluggedIn: Bool
) -> BatteryControlServiceStatus {
    do {
        let stored = try store.load()
        let desired: BatteryControlConfiguration
        var failure: BatteryControlStatusReason?
        if let stored, stored.ownerUID != ownerUID {
            desired = .init(enabled: false)
            failure = .init(kind: .policyOwnerMismatch)
        } else {
            desired = stored?.configuration ?? .init(enabled: false)
            failure = nil
        }
        engine.configure(desired)
        let status = engine.verifyAndUpdate(
            currentSoC: currentSoC, isPluggedIn: isPluggedIn)
        let resolvedFailure = failure ?? hardwareFailureReason(in: status)
        return publish(
            status,
            trigger: .startup,
            result: resolvedFailure == nil ? .verified : .failed,
            reason: resolvedFailure)
    } catch {
        engine.configure(.init(enabled: false))
        let status = engine.verifyAndUpdate(
            currentSoC: currentSoC, isPluggedIn: isPluggedIn)
        return publish(
            status,
            trigger: .startup,
            result: .failed,
            reason: .init(kind: .persistenceReadFailed))
    }
}

public func configure(
    _ requested: BatteryControlConfiguration,
    trigger: BatteryMaintenanceTrigger,
    currentSoC: Int,
    isPluggedIn: Bool
) -> BatteryControlServiceStatus {
    let normalized = requested.normalized
    do {
        try store.save(.init(
            ownerUID: ownerUID,
            configuration: normalized,
            updatedAt: now()))
    } catch {
        return publish(
            latestStatus,
            trigger: trigger,
            result: .failed,
            reason: .init(kind: .persistenceWriteFailed))
    }

    engine.configure(normalized)
    if !normalized.enabled {
        let verdict = engine.releaseVerified()
        var status = engine.statusForCurrentBelief(
            currentSoC: currentSoC,
            isPluggedIn: isPluggedIn)
        status.releaseVerdict = verdict
        if verdict == .verifiedAllowed { status.actualGate = .allowed }
        return publish(
            status,
            trigger: trigger,
            result: verdict.isSafeToRemove ? .released : .failed,
            reason: verdict.isSafeToRemove
                ? nil : .init(kind: .releaseFailed))
    }
    let status = engine.verifyAndUpdate(
        currentSoC: currentSoC, isPluggedIn: isPluggedIn)
    let failure = hardwareFailureReason(in: status)
    return publish(
        status,
        trigger: trigger,
        result: failure == nil ? .applied : .failed,
        reason: failure)
}
```

`statusForCurrentBelief` is an internal engine snapshot builder; it does not perform I/O and never fabricates an allowed gate. The explicit release verdict is the only removal-safety input for a disabled request.

Define the shared classifier rather than duplicating partial checks:

```swift
private func hardwareFailureReason(
    in status: BatteryControlServiceStatus
) -> BatteryControlStatusReason? {
    switch status.detailReason?.kind {
    case .applyFailed, .releaseFailed, .hardwareReadbackFailed:
        return status.detailReason
    default:
        break
    }
    guard status.actualGate?.state != .unreadable,
          status.actualGate?.state != .unrecognized
    else {
        return .init(kind: .hardwareReadbackFailed)
    }
    return nil
}
```

The startup record is `.verified` only when persistence/ownership resolution and hardware verification both succeeded. Add a red regression where store load succeeds but readback remains unreadable; expect `.startup/.failed/.hardwareReadbackFailed`, never `.verified`.

Implement `restoreWithoutPowerReading()` with the same store/schema/owner resolution as `restore`, then call `engine.hydrateHardwareState()` instead of `verifyAndUpdate`. If the resolved desired configuration is disabled, call `releaseVerified()`; if it is enabled and the gate is readable, preserve that gate until the first real power sample. Publish `.powerSourceUnreadable` as the current `detailReason` while keeping a separate startup maintenance record for persistence/ownership failure. The first later daemon sample evaluates SoC normally.

Implement the corresponding command path; it must still commit the user edit:

```swift
public func configureWithoutPowerReading(
    _ requested: BatteryControlConfiguration,
    trigger: BatteryMaintenanceTrigger
) -> BatteryControlServiceStatus {
    let normalized = requested.normalized
    do {
        try store.save(.init(
            ownerUID: ownerUID,
            configuration: normalized,
            updatedAt: now()))
    } catch {
        return publish(
            latestStatus,
            trigger: trigger,
            result: .failed,
            reason: .init(kind: .persistenceWriteFailed))
    }
    engine.configure(normalized)
    let gate = engine.hydrateHardwareState()
    if !normalized.enabled {
        let releaseVerdict = engine.releaseVerified()
        return publish(
            statusForMissingPowerSource(
                actualGate: releaseVerdict == .verifiedAllowed ? .allowed : gate,
                releaseVerdict: releaseVerdict),
            trigger: trigger,
            result: releaseVerdict.isSafeToRemove ? .released : .failed,
            reason: releaseVerdict.isSafeToRemove
                ? nil : .init(kind: .releaseFailed))
    }
    return publish(
        statusForMissingPowerSource(actualGate: gate),
        trigger: trigger,
        result: .skipped,
        reason: .init(kind: .powerSourceUnreadable))
}
```

`statusForMissingPowerSource` publishes desired configuration, actual gate, `.powerSourceUnreadable`, and current time without pretending SoC/adapter values were sampled. Add tests proving an enabled edit with no power reading is stored, an enabled existing hold is preserved, and a disabled edit still requires verified release.

`sample` never reads the gate or opens a recovery window:

```swift
public func sample(
    currentSoC: Int,
    isPluggedIn: Bool
) -> BatteryControlServiceStatus {
    var status = engine.update(
        currentSoC: currentSoC,
        isPluggedIn: isPluggedIn)
    status.desiredConfiguration = engine.configuration
    status.lastMaintenance = latestStatus.lastMaintenance
    status.capabilities = Self.capabilities
    latestStatus = status
    return status
}
```

`engine.configure` opens the configure/startup recovery window itself; the coordinator must not call `beginRecoveryWindow()` again after it. `reconcile` calls `engine.beginRecoveryWindow()` only for `.wake` and `.adapterTransition`, then `verifyAndUpdate`. `releaseVerified()` uses the same `consecutiveWriteFailures` latch as ordinary transitions, so one failed disable plus later samples still totals at most three writes. `releaseForTermination()` opens exactly one termination recovery window before its loop, calls `engine.releaseVerified()` at most three times, stops immediately on `verdict.isSafeToRemove`, stores the final verdict, records `.termination/.released` only for a safe verdict, and returns that Boolean. Add regression tests that disabled configure, later forced samples, and termination never exceed three combined attempts per window.

- [ ] **Step 5: Add corruption, adapter-boundary, and termination tests**

```swift
@Test func corruptStoreReleasesAndReportsPersistenceReadFailure() {
    let hardware = MockBatteryHardware()
    hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
    let store = PolicyStoreSpy()
    store.loadError = BatteryPolicyStoreError.unreadablePayload
    let coordinator = BatteryControlCoordinator(
        ownerUID: 501,
        store: store,
        engine: BatteryControlEngine(hardware: hardware),
        now: { 100 })

    let status = coordinator.restore(currentSoC: 80, isPluggedIn: true)

    #expect(status.desiredConfiguration?.enabled == false)
    #expect(status.actualGate?.state == .allowed)
    #expect(status.lastMaintenance == .init(
        trigger: .startup,
        result: .failed,
        occurredAt: 100,
        reason: .init(kind: .persistenceReadFailed)))
}

@Test func adapterTransitionOpensANewThreeWriteRecoveryWindow() {
    let hardware = MockBatteryHardware()
    hardware.writeShouldFail = true
    let coordinator = BatteryControlCoordinator(
        ownerUID: 501,
        store: PolicyStoreSpy(),
        engine: BatteryControlEngine(hardware: hardware),
        now: { 100 })
    _ = coordinator.configure(
        .init(enabled: true, limitPercentage: 80),
        trigger: .clientConfiguration,
        currentSoC: 80,
        isPluggedIn: true)
    for _ in 0..<10 {
        _ = coordinator.sample(currentSoC: 80, isPluggedIn: true)
    }
    #expect(hardware.writeCount == BatteryControlEngine.maxConsecutiveWriteFailures)

    _ = coordinator.reconcile(
        trigger: .adapterTransition,
        currentSoC: 80,
        isPluggedIn: true)
    #expect(hardware.writeCount
            == BatteryControlEngine.maxConsecutiveWriteFailures + 1)
}

@Test func ordinaryStatusReadDoesNotOpenANewRecoveryWindow() {
    let hardware = MockBatteryHardware()
    hardware.writeShouldFail = true
    let coordinator = BatteryControlCoordinator(
        ownerUID: 501,
        store: PolicyStoreSpy(),
        engine: BatteryControlEngine(hardware: hardware),
        now: { 100 })
    _ = coordinator.configure(
        .init(enabled: true, limitPercentage: 80),
        trigger: .clientConfiguration,
        currentSoC: 80,
        isPluggedIn: true)
    let count = hardware.writeCount
    for _ in 0..<10 {
        _ = coordinator.sample(currentSoC: 80, isPluggedIn: true)
    }
    #expect(hardware.writeCount
            == max(count, BatteryControlEngine.maxConsecutiveWriteFailures))
}

@Test func releaseForTerminationRequiresAllowedReadback() {
    let hardware = MockBatteryHardware()
    hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
    hardware.releaseVerdict = .failed
    let coordinator = BatteryControlCoordinator(
        ownerUID: 501,
        store: PolicyStoreSpy(),
        engine: BatteryControlEngine(hardware: hardware),
        now: { 100 })

    #expect(coordinator.releaseForTermination() == false)
    #expect(coordinator.latestStatus.lastMaintenance?.trigger == .termination)
    #expect(coordinator.latestStatus.lastMaintenance?.result == .failed)
}
```

Add `holdReportedGateAfterWrite` to `MockBatteryHardware`; when true, successful writes update the mock’s logical fields but deliberately leave `reportedGate` unchanged. This is the exact seam used by both verified-release failure tests.

- [ ] **Step 6: Run green and commit the coordinator**

Run the validation command.

Expected: `** TEST SUCCEEDED **`.

```bash
git add FanControlShared/BatteryControlCoordinator.swift \
  WattlyTests/BatteryControlCoordinatorTests.swift \
  WattlyTests/BatteryControlEngineTests.swift
git commit -m "feat(battery): coordinate durable policy transitions"
```

---

### Task 6: Make the daemon restore and transact through the coordinator

**Files:**
- Modify: `WattlyFanDaemon/FanControlDaemon.swift:7-341`
- Modify: `WattlyFanDaemon/main.swift:1-24`
- Modify: `WattlyTests/FanControlProtocolTests.swift`
- Modify: `WattlyTests/BatteryControlCoordinatorTests.swift`

**Interfaces:**
- Consumes: `BatteryControlCoordinator`, power-source samples, and existing serialized daemon queue.
- Produces: app-independent startup restore, persist-before-hardware `configureBattery`, status sampling that does not re-arm failures, and adapter-transition recovery.

- [ ] **Step 1: Replace the daemon’s direct battery engine with the coordinator**

Change stored dependencies:

```swift
private let batteryCoordinator: BatteryControlCoordinator
private var latestBatteryStatus: BatteryControlServiceStatus {
    batteryCoordinator.latestStatus
}
```

Change the initializer:

```swift
init(
    allowedUID: uid_t,
    hardware: any FanControlHardware,
    batteryCoordinator: BatteryControlCoordinator
) {
    self.allowedUID = allowedUID
    self.engine = FanControlEngine(hardware: hardware)
    self.batteryCoordinator = batteryCoordinator
    self.listener = NSXPCListener(machServiceName: FanControlXPC.machService)
    super.init()
}
```

In `main.swift`, dispatch the one-shot mode before `WATTLY_ALLOWED_UID` validation, then construct the long-running graph:

```swift
if CommandLine.arguments.contains("--verify-battery-release") {
    guard let verifierSMC = SMCControlConnection() else { exit(74) }
    let verifierHardware = SMCBatteryControlHardware(smc: verifierSMC)
    let verdict = verifierHardware.releaseChargingControlAndVerify()
    exit(verdict.isSafeToRemove ? 0 : 74)
}

let rawUID = ProcessInfo.processInfo.environment["WATTLY_ALLOWED_UID"] ?? ""
guard let uid = UInt32(rawUID), uid > 0 else {
    fputs("WATTLY_ALLOWED_UID is required\n", stderr)
    exit(78)
}
guard let smc = SMCControlConnection() else {
    fputs("Unable to open SMC control connection\n", stderr)
    exit(69)
}
guard let hardware = SMCFanControlHardware(smc: smc) else {
    fputs("Unable to open SMC fan control hardware\n", stderr)
    exit(69)
}
let batteryHardware = SMCBatteryControlHardware(smc: smc)
let batteryEngine = BatteryControlEngine(hardware: batteryHardware)
let batteryStore = BatteryPolicyFileStore()
let batteryCoordinator = BatteryControlCoordinator(
    ownerUID: uid,
    store: batteryStore,
    engine: batteryEngine,
    now: { Date().timeIntervalSince1970 })

let daemon = FanControlDaemon(
    allowedUID: uid_t(uid),
    hardware: hardware,
    batteryCoordinator: batteryCoordinator)
```

The one-shot branch deliberately needs no UID environment because it exposes no XPC listener and only writes the safe release direction. It is the privileged installer/uninstaller preflight: exit 0 means `.verifiedAllowed` or `.notControllable`; exit 74 means release/readback failed. Add a source-order test proving argument dispatch precedes the UID guard, plus a build smoke check that the binary recognizes the argument; do not run the real mode outside the explicit privileged manual matrix.

- [ ] **Step 2: Restore before listener exposure**

Replace startup `sampleBatteryAndEvaluate(force: true)` with an explicit first reading:

```swift
queue.sync { [self] in
    engine.resetAllFansToAutomatic(now: now())
    if let reading = readPowerSourceState() {
        lastPowerReading = reading
        _ = batteryCoordinator.restore(
            currentSoC: reading.soc,
            isPluggedIn: reading.plugged)
    } else {
        _ = batteryCoordinator.restoreWithoutPowerReading()
    }
    resumeListenerIfSafe()
}
```

The no-reading path does not invent “0%, unplugged.” A valid enabled policy preserves a readable gate until the first watchdog power sample; missing/corrupt/wrong-owner state resolves disabled and attempts verified release. Its current reason is `.powerSourceUnreadable`, while persistence/ownership failure remains in `lastMaintenance`.

Extend the existing listener gate:

```swift
private func resumeListenerIfSafe() {
    guard !listenerResumed,
          engine.isSafeToAcceptClients,
          batteryCoordinator.isSafeToServe
    else { return }
    listener.resume()
    listenerResumed = true
}
```

If startup recovery leaves `isSafeToServe == false`, exit 74 after the verified release attempt rather than entering the run loop.

- [ ] **Step 3: Route configure, status, and timer samples**

Inside `configureBattery`, keep the in-process generation guard, then:

```swift
guard let reading = readPowerSourceState() ?? lastPowerReading else {
    let status = batteryCoordinator.configureWithoutPowerReading(
        request.configuration,
        trigger: .clientConfiguration)
    reply.send((try BatteryControlCodec.encode(status), nil))
    return
}
lastPowerReading = reading
let status = batteryCoordinator.configure(
    request.configuration,
    trigger: .clientConfiguration,
    currentSoC: reading.soc,
    isPluggedIn: reading.plugged)
reply.send((try BatteryControlCodec.encode(status), nil))
```

Replace timer/status sampling with:

```swift
private func sampleBatteryAndEvaluate(force: Bool = false) {
    guard force || batteryCoordinator.needsSampling else {
        return
    }
    guard let reading = readPowerSourceState() ?? lastPowerReading else {
        return
    }
    let adapterChanged = lastPowerReading?.plugged != reading.plugged
    lastPowerReading = reading
    if adapterChanged {
        _ = batteryCoordinator.reconcile(
            trigger: .adapterTransition,
            currentSoC: reading.soc,
            isPluggedIn: reading.plugged)
    } else {
        _ = batteryCoordinator.sample(
            currentSoC: reading.soc,
            isPluggedIn: reading.plugged)
    }
}
```

`batteryStatus` calls this with `force: true` and encodes `batteryCoordinator.latestStatus`. Delete daemon-owned `lastReassertAt`; boundary-scoped coordinator recovery replaces time throttling.

Add a coordinator test and an XPC-level serialization test that send an enabled configuration while both current and cached power readings are absent. Expected: store contains the normalized request, maintenance is `.clientConfiguration/.skipped/.powerSourceUnreadable`, and no SoC-dependent inhibit/release decision is invented.

Add a regression where desired configuration is disabled, release verdict is `.failed`, and actual gate remains inhibited. `needsSampling` must stay true; after an adapter transition, daemon calls `reconcile(trigger: .adapterTransition,...)` and receives a fresh three-attempt boundary.

- [ ] **Step 4: Make managed termination require battery and fan safety**

Change `releaseSynchronously`:

```swift
private func releaseSynchronously(
    reason: String,
    releaseBattery: Bool
) -> Bool {
    queue.sync { [self] in
        let batterySafe = !releaseBattery
            || batteryCoordinator.releaseForTermination()
        engine.release(now: now(), reason: reason)
        let deadline = now() + FanControlPolicy.modeRetryDeadline
        while true {
            let fansSafe = engine.recoverAutomaticSynchronously(now: now())
            if batterySafe && fansSafe { return true }
            guard now() < deadline else { return false }
            Thread.sleep(forTimeInterval: FanControlPolicy.modeRetryDelay)
        }
    }
}
```

Do not delete the persisted enabled policy on SIGTERM: a KeepAlive restart must restore it. Only explicit disable/uninstall writes disabled.

- [ ] **Step 5: Regenerate and run the full suite**

Run the validation command.

Expected: `** TEST SUCCEEDED **`; both `Wattly` and `WattlyFanDaemon` link.

- [ ] **Step 6: Commit daemon coordinator integration**

```bash
git add WattlyFanDaemon/FanControlDaemon.swift \
  WattlyFanDaemon/main.swift \
  FanControlShared/BatteryControlCoordinator.swift \
  WattlyTests/BatteryControlCoordinatorTests.swift \
  WattlyTests/FanControlProtocolTests.swift
git commit -m "feat(battery): restore durable policy in helper"
```

---

### Task 7: Replace daemon NSWorkspace power notifications with IOKit

**Files:**
- Create: `FanControlShared/SystemPowerEvent.swift`
- Create: `WattlyFanDaemon/SystemPowerObserver.swift`
- Create: `WattlyTests/SystemPowerEventPolicyTests.swift`
- Modify: `WattlyFanDaemon/FanControlDaemon.swift:20-21,68-69,245-271`
- Modify: `WattlyFanDaemon/main.swift`

**Interfaces:**
- Consumes: coordinator `reconcile(trigger:.wake,...)` and existing fan sleep recovery.
- Produces: `SystemPowerEvent`, `SystemPowerEventPolicy.action(for:)`, and concrete `SystemPowerObserver.start()`.

- [ ] **Step 1: Write red pure routing tests**

```swift
import Testing
@testable import Wattly

@Suite struct SystemPowerEventPolicyTests {
    @Test func canSleepIsImmediatelyAllowedWithoutWork() {
        #expect(SystemPowerEventPolicy.action(for: .canSleep)
                == .init(releaseFans: false, reconcileBattery: false, acknowledge: true))
    }

    @Test func willSleepReleasesOnlyFansAndAcknowledges() {
        #expect(SystemPowerEventPolicy.action(for: .willSleep)
                == .init(releaseFans: true, reconcileBattery: false, acknowledge: true))
    }

    @Test func earlyWakeDoesNotTouchUnavailableHardware() {
        #expect(SystemPowerEventPolicy.action(for: .willPowerOn)
                == .init(releaseFans: false, reconcileBattery: false, acknowledge: false))
    }

    @Test func completedWakeReconcilesOnlyBattery() {
        #expect(SystemPowerEventPolicy.action(for: .hasPoweredOn)
                == .init(releaseFans: false, reconcileBattery: true, acknowledge: false))
    }
}
```

- [ ] **Step 2: Run the suite and verify red**

Expected: FAIL because `SystemPowerEventPolicy` does not exist.

- [ ] **Step 3: Implement the pure event vocabulary**

```swift
public enum SystemPowerEvent: Equatable, Sendable {
    case canSleep
    case willSleep
    case willPowerOn
    case hasPoweredOn
}

public struct SystemPowerEventAction: Equatable, Sendable {
    public var releaseFans: Bool
    public var reconcileBattery: Bool
    public var acknowledge: Bool

    public init(
        releaseFans: Bool,
        reconcileBattery: Bool,
        acknowledge: Bool
    ) {
        self.releaseFans = releaseFans
        self.reconcileBattery = reconcileBattery
        self.acknowledge = acknowledge
    }
}

public enum SystemPowerEventPolicy {
    public static func action(
        for event: SystemPowerEvent
    ) -> SystemPowerEventAction {
        switch event {
        case .canSleep:
            .init(releaseFans: false, reconcileBattery: false, acknowledge: true)
        case .willSleep:
            .init(releaseFans: true, reconcileBattery: false, acknowledge: true)
        case .willPowerOn:
            .init(releaseFans: false, reconcileBattery: false, acknowledge: false)
        case .hasPoweredOn:
            .init(releaseFans: false, reconcileBattery: true, acknowledge: false)
        }
    }
}
```

- [ ] **Step 4: Implement the concrete IOKit observer**

Create a run-loop-owned observer. The callback must always acknowledge both sleep messages, even when the daemon handler fails:

```swift
import Foundation
import IOKit
import IOKit.pwr_mgt

final class SystemPowerObserver {
    enum RegistrationError: Error { case unavailable }

    private let onEvent: @Sendable (SystemPowerEvent) -> Void
    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init(onEvent: @escaping @Sendable (SystemPowerEvent) -> Void) {
        self.onEvent = onEvent
    }

    func start() throws {
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(
            context,
            &notificationPort,
            { context, _, messageType, messageArgument in
                guard let context else { return }
                let observer = Unmanaged<SystemPowerObserver>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                observer.receive(
                    messageType: messageType,
                    messageArgument: messageArgument)
            },
            &notifier)
        guard rootPort != 0, let notificationPort else {
            throw RegistrationError.unavailable
        }
        let source = IONotificationPortGetRunLoopSource(notificationPort)
            .takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func receive(
        messageType: UInt32,
        messageArgument: UnsafeMutableRawPointer?
    ) {
        let notificationID = Int(bitPattern: messageArgument)
        switch messageType {
        case UInt32(kIOMessageCanSystemSleep):
            onEvent(.canSleep)
            IOAllowPowerChange(rootPort, notificationID)
        case UInt32(kIOMessageSystemWillSleep):
            defer { IOAllowPowerChange(rootPort, notificationID) }
            onEvent(.willSleep)
        case UInt32(kIOMessageSystemWillPowerOn):
            onEvent(.willPowerOn)
        case UInt32(kIOMessageSystemHasPoweredOn):
            onEvent(.hasPoweredOn)
        default:
            break
        }
    }

    deinit {
        if notifier != 0 {
            _ = IODeregisterForSystemPower(&notifier)
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
        }
        if rootPort != 0 { IOServiceClose(rootPort) }
    }
}
```

`IODeregisterForSystemPower` must run before notification-port destruction and root-port close; do not substitute a bare `IOObjectRelease` for the registration teardown.

- [ ] **Step 5: Inject and handle power events in the daemon**

Store the observer strongly in `FanControlDaemon`; delete `sleepObserver`, `wakeObserver`, and `observeSleep()`. Add:

```swift
func handlePowerEvent(_ event: SystemPowerEvent) {
    let action = SystemPowerEventPolicy.action(for: event)
    if action.releaseFans {
        _ = releaseSynchronously(reason: "system sleep", releaseBattery: false)
    }
    if action.reconcileBattery {
        queue.async { [weak self] in
            guard let self,
                  let reading = readPowerSourceState() ?? lastPowerReading
            else { return }
            lastPowerReading = reading
            _ = batteryCoordinator.reconcile(
                trigger: .wake,
                currentSoC: reading.soc,
                isPluggedIn: reading.plugged)
        }
    }
}
```

Add a daemon-owned startup method so the observer lifetime equals the daemon lifetime:

```swift
private var powerObserver: SystemPowerObserver?

func startPowerObservation() throws {
    let observer = SystemPowerObserver { [weak self] event in
        self?.handlePowerEvent(event)
    }
    try observer.start()
    powerObserver = observer
}
```

In `main.swift`, start it with an explicit error path:

```swift
daemon.run()
do {
    try daemon.startPowerObservation()
} catch {
    fputs("Unable to register system power notifications\n", stderr)
    exit(71)
}
RunLoop.main.run()
```

If registration fails, exit with `EX_OSERR` value 71; do not silently fall back to the known-unreliable `NSWorkspace` path.

- [ ] **Step 6: Run tests and daemon build**

Run the validation command.

Expected: `** TEST SUCCEEDED **`; no `NSWorkspace.willSleepNotification` or `didWakeNotification` remains in `WattlyFanDaemon`.

Check:

```bash
rg -n 'NSWorkspace\\.(willSleep|didWake)|observeSleep' WattlyFanDaemon
```

Expected: no matches.

- [ ] **Step 7: Commit the power observer**

```bash
git add FanControlShared/SystemPowerEvent.swift \
  WattlyFanDaemon/SystemPowerObserver.swift \
  WattlyFanDaemon/FanControlDaemon.swift \
  WattlyFanDaemon/main.swift \
  WattlyTests/SystemPowerEventPolicyTests.swift
git commit -m "feat(battery): reconcile from IOKit power events"
```

---

### Task 8: Reconcile full configuration and expose helper ownership/capabilities

**Files:**
- Modify: `FanControlShared/BatteryControlPolicy.swift:7-63`
- Modify: `Wattly/Control/BatteryControlClient.swift:6-174`
- Modify: `Wattly/Views/BatteryControlBridge.swift:4-67`
- Modify: `Wattly/Control/FanHelperInstaller.swift:12-128`
- Modify: `Wattly/Control/PrivilegedHelperInstallSession.swift:14-59`
- Modify: `scripts/install-fan-helper.sh`
- Modify: `WattlyTests/BatteryControlPolicyTests.swift`
- Modify: `WattlyTests/BatteryControlClientTests.swift`

**Interfaces:**
- Consumes: optional capabilities, desired configuration, actual gate, installed LaunchDaemon plist.
- Produces: `BatteryControlPolicy.shouldReapply(configuration:status:)`, `supportsPersistentPolicy(status:)`, status-returning `apply`, `disableAndConfirm`, `FanHelperInstaller.installedOwnership()`, explicit `install(transferringOwnership:privilegedRunner:)`, and transfer-aware `installAndApply`.

- [ ] **Step 1: Add red policy tests for full configuration**

```swift
@Test func reapplyWhenPersistedHysteresisDiffers() {
    let requested = BatteryControlConfiguration(
        enabled: true, limitPercentage: 85, lowerHysteresisDelta: 5)
    let status = BatteryControlServiceStatus(
        mode: .charging,
        currentPercentage: 80,
        isPowerAdapterConnected: true,
        detail: "OK",
        updatedAt: 1,
        desiredConfiguration: .init(
            enabled: true, limitPercentage: 85, lowerHysteresisDelta: 2),
        capabilities: [.persistedPolicyV1])
    #expect(BatteryControlPolicy.shouldReapply(
        configuration: requested, status: status))
}

@Test func persistentHelperWithExactConfigurationNeedsOnlyStatusRead() {
    let requested = BatteryControlConfiguration(
        enabled: true, limitPercentage: 85, lowerHysteresisDelta: 5)
    let status = BatteryControlServiceStatus(
        mode: .inhibited,
        currentPercentage: 85,
        isPowerAdapterConnected: true,
        detail: "OK",
        updatedAt: 1,
        desiredConfiguration: requested,
        capabilities: [.persistedPolicyV1])
    #expect(!BatteryControlPolicy.shouldReapply(
        configuration: requested, status: status))
}

@Test func legacyHelperFallsBackToAppliedLimitComparison() {
    let requested = BatteryControlConfiguration(
        enabled: true, limitPercentage: 85, lowerHysteresisDelta: 5)
    let legacy = status(mode: .charging, applied: 85)
    #expect(!BatteryControlPolicy.shouldReapply(
        configuration: requested, status: legacy))
}
```

- [ ] **Step 2: Run and verify red**

Expected: FAIL because the full-configuration policy signature does not exist.

- [ ] **Step 3: Implement capability-aware policy**

```swift
public static func supportsPersistentPolicy(
    status: BatteryControlServiceStatus
) -> Bool {
    status.capabilities?.contains(.persistedPolicyV1) == true
        && status.capabilities?.contains(.hardwareGateReadbackV1) == true
        && status.capabilities?.contains(.systemPowerEventsV1) == true
}

public static func shouldReapply(
    configuration: BatteryControlConfiguration,
    status: BatteryControlServiceStatus
) -> Bool {
    let requested = configuration.normalized
    guard status.mode != .unavailable else { return false }
    guard status.isHardwareSupported != false else { return false }
    if supportsPersistentPolicy(status: status),
       let desired = status.desiredConfiguration {
        return desired.normalized != requested
    }
    if requested.enabled {
        return status.appliedLimitPercentage != requested.clampedLimitPercentage
    }
    return status.appliedLimitPercentage != nil || status.mode == .inhibited
}
```

Update every caller and existing test. Replace the old “do not reapply when opted out” expectation with two cases: a settled disabled helper is silent, while a persistent helper whose desired configuration is still enabled receives the disabled request. Remove the old two-scalar signature.

- [ ] **Step 4: Make client apply return the acknowledged status**

Change:

```swift
@discardableResult
public func apply(
    enabled: Bool,
    limitPercentage: Int,
    lowerHysteresisDelta: Int = 2
) async -> BatteryControlServiceStatus? {
    commandGeneration &+= 1
    let config = BatteryControlConfiguration(
        enabled: enabled,
        limitPercentage: limitPercentage,
        lowerHysteresisDelta: lowerHysteresisDelta)
    let request = BatteryControlConfigurationRequest(
        configuration: config,
        generation: commandGeneration)
    guard let data = try? BatteryControlCodec.encode(request) else {
        updateUnavailable("충전 제한 설정을 인코딩할 수 없음")
        return nil
    }
    return await send(.configure(data))
}
```

Add:

```swift
public enum DisableFailure: Error, Equatable {
    case helperUnavailable
    case persistenceRejected
    case releaseUnverified
}

public func disableAndConfirm() async -> DisableFailure? {
    guard let acknowledged = await apply(
        enabled: false, limitPercentage: 100)
    else { return .helperUnavailable }
    guard acknowledged.desiredConfiguration?.enabled == false else {
        return .persistenceRejected
    }
    let safe = acknowledged.actualGate?.state == .allowed
        || acknowledged.releaseVerdict?.isSafeToRemove == true
    guard safe else {
        return .releaseUnverified
    }
    return nil
}
```

Tests must cover all three failures and success. Add one acceptance predicate used by install/update:

```swift
public static func accepted(
    configuration: BatteryControlConfiguration,
    by status: BatteryControlServiceStatus
) -> Bool {
    guard status.desiredConfiguration?.normalized
            == configuration.normalized,
          status.lastMaintenance?.result != .failed
    else { return false }
    if !configuration.enabled {
        return status.actualGate?.state == .allowed
            || status.releaseVerdict?.isSafeToRemove == true
    }
    return status.actualGate?.state != .unreadable
        && status.actualGate?.state != .unrecognized
}
```

After `installAndApply` receives the post-install status, require `BatteryControlPolicy.accepted(configuration:by:)`; otherwise return `.configureRejected`. “Any mode other than unavailable” is not success.

- [ ] **Step 5: Make the bridge status-first and keep legacy wake fallback**

Build one local configuration value from the four `@AppStorage` fields. Initial task:

```swift
.task {
    await client.refreshStatus()
    let configuration = BatteryControlConfiguration(
        enabled: enabled,
        limitPercentage: limit,
        lowerHysteresisDelta: effectiveDelta)
    if BatteryControlPolicy.shouldReapply(
        configuration: configuration,
        status: client.status) {
        if configuration.enabled {
            await client.apply(
                enabled: true,
                limitPercentage: configuration.limitPercentage,
                lowerHysteresisDelta: configuration.lowerHysteresisDelta)
        } else {
            _ = await client.disableAndConfirm()
        }
    }
}
```

Wake behavior:

```swift
.onReceive(NSWorkspace.shared.notificationCenter.publisher(
    for: NSWorkspace.didWakeNotification)) { _ in
    Task {
        if BatteryControlPolicy.supportsPersistentPolicy(status: client.status) {
            await client.refreshStatus()
        } else {
            await client.apply(
                enabled: enabled,
                limitPercentage: limit,
                lowerHysteresisDelta: effectiveDelta)
        }
    }
}
```

The periodic loop remains as a compatibility/reachability monitor, but compares the full configuration and uses the same enabled/apply versus disabled/disableAndConfirm split. It never writes when a new helper’s durable desired configuration matches.

Change the bridge’s existing enabled observer so normal toggle-off uses verified disable:

```swift
.onChange(of: enabled) { _, value in
    Task {
        if value {
            await client.apply(
                enabled: true,
                limitPercentage: limit,
                lowerHysteresisDelta: effectiveDelta)
        } else {
            _ = await client.disableAndConfirm()
        }
    }
}
```

The local preference stays false if release fails—the durable desired policy is disabled—but `client.status` remains a failure with `.releaseFailed`, and the maintenance row offers retry. Add a client/bridge policy test proving toggle-off cannot render a settled inactive state unless `actualGate == .allowed`.

- [ ] **Step 6: Detect installed owner and require explicit transfer**

Add:

```swift
enum InstalledOwnership: Equatable {
    case notInstalled
    case owner(UInt32)
    case invalidMetadata
}

enum OwnershipError: LocalizedError, Equatable {
    case ownedByDifferentUser(UInt32)
    case invalidInstalledMetadata

    var errorDescription: String? {
        switch self {
        case .ownedByDifferentUser:
            "다른 사용자가 이 Mac의 충전 정책을 관리하고 있습니다."
        case .invalidInstalledMetadata:
            "설치된 도우미의 소유자 정보를 확인할 수 없습니다."
        }
    }
}

static func installedOwnership(
    plistURL: URL = URL(
        fileURLWithPath: "/Library/LaunchDaemons/\(label).plist")
) -> InstalledOwnership {
    guard FileManager.default.fileExists(atPath: plistURL.path) else {
        return .notInstalled
    }
    guard let data = try? Data(contentsOf: plistURL),
          let plist = try? PropertyListSerialization.propertyList(
            from: data, format: nil) as? [String: Any],
          let environment = plist["EnvironmentVariables"] as? [String: String],
          let raw = environment["WATTLY_ALLOWED_UID"],
          let uid = UInt32(raw),
          uid > 0
    else { return .invalidMetadata }
    return .owner(uid)
}
```

Change installer signature and expose only an internal test-runner seam:

```swift
typealias PrivilegedRunner = @Sendable (String) async throws -> Void

static func validateOwnership(
    installedOwnership: InstalledOwnership,
    currentUID: UInt32,
    transferringOwnership: Bool
) throws {
    switch installedOwnership {
    case .notInstalled:
        return
    case .owner(let uid) where uid == currentUID:
        return
    case .owner(let uid):
        guard transferringOwnership else {
            throw OwnershipError.ownedByDifferentUser(uid)
        }
    case .invalidMetadata:
        guard transferringOwnership else {
            throw OwnershipError.invalidInstalledMetadata
        }
    }
}

static func install(
    transferringOwnership: Bool = false,
    daemonURL: URL = bundledDaemonURL,
    installedPlistURL: URL = URL(
        fileURLWithPath: "/Library/LaunchDaemons/\(label).plist"),
    currentUID: UInt32 = UInt32(getuid()),
    privilegedRunner: PrivilegedRunner? = nil
) async throws {
    try validateOwnership(
        installedOwnership: installedOwnership(plistURL: installedPlistURL),
        currentUID: currentUID,
        transferringOwnership: transferringOwnership)
    guard FileManager.default.isExecutableFile(atPath: daemonURL.path) else {
        throw InstallError.daemonMissing
    }
    let plist = plistTemplate.replacingOccurrences(
        of: "__WATTLY_ALLOWED_UID__",
        with: "\(currentUID)")
    let plistPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label).plist")
    do {
        try plist.write(to: plistPath, atomically: true, encoding: .utf8)
    } catch {
        throw InstallError.scriptWriteFailed
    }
    let script = makeInstallScript(
        daemonPath: daemonURL.path,
        plistPath: plistPath.path)
    try await (privilegedRunner ?? runPrivileged)(script)
}

static func makeInstallScript(
    daemonPath: String,
    plistPath: String
) -> String {
    """
    set -eu
    '\(daemonPath)' --verify-battery-release
    was_running=false
    if launchctl print system/\(label) >/dev/null 2>&1; then
      was_running=true
      launchctl bootout system/\(label)
    fi
    if ! '\(daemonPath)' --verify-battery-release; then
      if $was_running; then
        launchctl bootstrap system '/Library/LaunchDaemons/\(label).plist'
      fi
      exit 74
    fi
    install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools /Library/LaunchDaemons
    install -o root -g wheel -m 755 '\(daemonPath)' '/Library/PrivilegedHelperTools/\(label)'
    install -o root -g wheel -m 644 '\(plistPath)' '/Library/LaunchDaemons/\(label).plist'
    launchctl bootstrap system '/Library/LaunchDaemons/\(label).plist'
    launchctl kickstart -k system/\(label)
    """
}
```

In `PrivilegedHelperInstallSession.run`, change the signature from:

```swift
static func run(
    window: NSWindow?,
    transferringOwnership: Bool = false,
    postInstall: @MainActor () async -> Void
) async -> Error?
```

Inside that existing method, replace its one installer call with:

```swift
try await FanHelperInstaller.install(
    transferringOwnership: transferringOwnership)
```

Change `BatteryControlClient.installAndApply` to accept `transferringOwnership: Bool = false` before `window`, and replace its existing shared-session call with:

```swift
if let failure = await PrivilegedHelperInstallSession.run(
    window: window,
    transferringOwnership: transferringOwnership,
    postInstall: {
        await self.apply(
            enabled: enabled,
            limitPercentage: limitPercentage,
            lowerHysteresisDelta: lowerHysteresisDelta)
    }) {
    return .install(failure)
}
```

Add concrete ownership tests:

```swift
@Test func differentInstalledOwnerIsBlockedWithoutTransfer() throws {
    #expect(throws: FanHelperInstaller.OwnershipError.self) {
        try FanHelperInstaller.validateOwnership(
            installedOwnership: .owner(UInt32(getuid()) + 1),
            currentUID: UInt32(getuid()),
            transferringOwnership: false)
    }
}

@Test func explicitTransferAllowsTheNewOwner() throws {
    try FanHelperInstaller.validateOwnership(
        installedOwnership: .owner(UInt32(getuid()) + 1),
        currentUID: UInt32(getuid()),
        transferringOwnership: true)
}

@Test func installedOwnershipReadsTheLaunchDaemonEnvironment() throws {
    let fixture = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).plist")
    defer { try? FileManager.default.removeItem(at: fixture) }
    let object: [String: Any] = [
        "EnvironmentVariables": ["WATTLY_ALLOWED_UID": "502"]
    ]
    let data = try PropertyListSerialization.data(
        fromPropertyList: object, format: .xml, options: 0)
    try data.write(to: fixture)
    #expect(FanHelperInstaller.installedOwnership(plistURL: fixture)
            == .owner(502))
}

@Test func malformedInstalledPlistRequiresExplicitTransfer() throws {
    #expect(throws: FanHelperInstaller.OwnershipError.self) {
        try FanHelperInstaller.validateOwnership(
            installedOwnership: .invalidMetadata,
            currentUID: 501,
            transferringOwnership: false)
    }
    try FanHelperInstaller.validateOwnership(
        installedOwnership: .invalidMetadata,
        currentUID: 501,
        transferringOwnership: true)
}

@Test func injectedRunnerReceivesTheCompleteInstallScript() async throws {
    let recorder = ScriptRecorder()
    let executable = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(
        atPath: executable.path,
        contents: Data(),
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: executable) }
    try await FanHelperInstaller.install(
        transferringOwnership: true,
        daemonURL: executable,
        installedPlistURL: executable
            .deletingLastPathComponent()
            .appendingPathComponent("missing-\(UUID().uuidString).plist"),
        currentUID: 501,
        privilegedRunner: { script in await recorder.record(script) })
    let script = await recorder.value
    #expect(script.contains("launchctl bootstrap system"))
    #expect(script.contains("launchctl kickstart -k"))
    #expect(script.contains("--verify-battery-release"))
    #expect(!script.contains("bootout system/\(FanHelperInstaller.label) 2>/dev/null || true"))
}
```

Define `ScriptRecorder` as a test-local actor with `record(_:) async` and a read-only `value` property. The production defaults remain the current bundle paths, and no test invokes an admin prompt.

Update `scripts/install-fan-helper.sh` with the same two gates. Before any bootout, parse `WATTLY_ALLOWED_UID` from an existing plist; a different or malformed owner exits 65 unless the sole argument is `--transfer-ownership`:

```bash
transfer_ownership=false
if [[ "$#" -gt 1 ]] || { [[ "$#" -eq 1 ]] && [[ "$1" != "--transfer-ownership" ]]; }; then
  print -u2 "Usage: $0 [--transfer-ownership]"
  exit 64
fi
[[ "$#" -eq 1 ]] && transfer_ownership=true

if [[ -e "$plist" ]]; then
  installed_uid=$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:WATTLY_ALLOWED_UID' "$plist" 2>/dev/null) || installed_uid=""
  if [[ "$installed_uid" != <-> ]] || [[ "$installed_uid" -le 0 ]]; then
    $transfer_ownership || {
      print -u2 "Installed helper owner metadata is invalid; rerun with --transfer-ownership."
      exit 65
    }
  elif [[ "$installed_uid" -ne "$uid" ]]; then
    $transfer_ownership || {
      print -u2 "Helper is owned by UID $installed_uid; rerun with --transfer-ownership."
      exit 65
    }
  fi
fi
```

Then use:

```bash
sudo "$dir/WattlyFanDaemon" --verify-battery-release
was_running=false
if sudo launchctl print "system/$label" >/dev/null 2>&1; then
  was_running=true
  sudo launchctl bootout "system/$label"
fi
if ! sudo "$dir/WattlyFanDaemon" --verify-battery-release; then
  $was_running && sudo launchctl bootstrap system "$plist"
  exit 74
fi
```

Only after the preflight verifier exits 0 may the script boot out anything. A second verifier runs after bootout; if it fails, the old plist is still present and the script re-bootstraps it before exiting. Only post-bootout verification may unlock file replacement. Add a shell syntax gate `zsh -n scripts/install-fan-helper.sh` and source assertions for preflight → bootout → postflight → first `install -o root` ordering.

- [ ] **Step 7: Run the full suite and commit**

Expected: `** TEST SUCCEEDED **`.

```bash
git add FanControlShared/BatteryControlPolicy.swift Wattly/Control/BatteryControlClient.swift Wattly/Views/BatteryControlBridge.swift Wattly/Control/FanHelperInstaller.swift Wattly/Control/PrivilegedHelperInstallSession.swift WattlyTests/BatteryControlPolicyTests.swift WattlyTests/BatteryControlClientTests.swift scripts/install-fan-helper.sh
git commit -m "feat(battery): reconcile persistent helper ownership"
```

---

### Task 9: Gate disable and full uninstall on verified charging release

**Files:**
- Modify: `Wattly/Core/AppUninstaller.swift:42-116`
- Modify: `Wattly/Control/BatteryControlClient.swift`
- Modify: `Wattly/Control/FanHelperInstaller.swift:54-60`
- Modify: `Wattly/Views/SettingsView.swift:48-65`
- Modify: `scripts/uninstall-fan-helper.sh`
- Modify: `WattlyTests/AppUninstallerTests.swift`

**Interfaces:**
- Consumes: `BatteryControlClient.disableAndConfirm()`, transfer-aware helper update path, and policy store path.
- Produces: `BatteryControlClient.prepareForRemoval(window:)`, throwing `AppUninstaller.cleanUserData`, `AppUninstaller.UninstallError`, safe helper/store removal, and visible uninstall failure.

- [ ] **Step 1: Replace void spies with ordered throwing spies and add red tests**

```swift
@Test @MainActor func releaseFailureStopsBeforeHelperOrUserDataRemoval() async {
    let events = EventRecorder()
    let suiteName = "test.uninstall.blocked.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(true, forKey: "stillHere")

    await #expect(throws: AppUninstaller.UninstallError.releaseUnverified) {
        try await AppUninstaller.cleanUserData(
            userDefaults: defaults,
            loginItem: MockLoginItem(),
            homeDirectory: FileManager.default.temporaryDirectory,
            bundleID: suiteName,
            releaseBatteryLimit: {
                await events.record("release")
                throw AppUninstaller.UninstallError.releaseUnverified
            },
            removeHelper: {
                await events.record("remove")
            })
    }

    #expect(await events.values == ["release"])
    #expect(defaults.bool(forKey: "stillHere"))
}

@Test @MainActor func successfulCleanupOrdersReleaseBeforeHelperRemoval() async throws {
    let events = EventRecorder()
    try await AppUninstaller.cleanUserData(
        userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
        loginItem: MockLoginItem(),
        homeDirectory: FileManager.default.temporaryDirectory,
        bundleID: UUID().uuidString,
        releaseBatteryLimit: { await events.record("release") },
        removeHelper: { await events.record("remove") })

    #expect(await events.values.prefix(2) == ["release", "remove"])
}
```

- [ ] **Step 2: Run and verify red**

Expected: FAIL because cleanup is non-throwing and its injected closures cannot throw.

- [ ] **Step 3: Make cleanup transactional and throwing**

```swift
enum UninstallError: LocalizedError, Equatable {
    case helperUnavailable
    case persistenceRejected
    case releaseUnverified
    case helperRemovalFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            "도우미에 연결할 수 없어 충전 허용 상태를 확인하지 못했습니다."
        case .persistenceRejected:
            "충전 제한 비활성화 설정을 저장하지 못했습니다."
        case .releaseUnverified:
            "충전 허용 상태를 확인하지 못해 Wattly 삭제를 중단했습니다."
        case .helperRemovalFailed(let detail):
            "도우미를 제거하지 못했습니다: \(detail)"
        }
    }
}
```

Change injected closures to:

```swift
releaseBatteryLimit: @MainActor () async throws -> Void
removeHelper: @MainActor () async throws -> Void
```

Add a client preparation method. Missing/legacy helpers are replaced with the bundled current helper only because the user explicitly requested full uninstall; a different-owner helper remains blocked instead of silently transferring:

```swift
public func prepareForRemoval(window: NSWindow?) async -> DisableFailure? {
    await refreshStatus()
    if !BatteryControlPolicy.supportsPersistentPolicy(status: status) {
        if await installAndApply(
            enabled: false,
            limitPercentage: 100,
            lowerHysteresisDelta: 2,
            transferringOwnership: false,
            window: window) != nil {
            return .helperUnavailable
        }
    }
    return await disableAndConfirm()
}
```

Default release maps the result exactly:

```swift
releaseBatteryLimit: @MainActor () async throws -> Void = {
    let client = BatteryControlClient()
    switch await client.prepareForRemoval(window: NSApp.keyWindow) {
    case nil:
        return
    case .helperUnavailable?:
        throw UninstallError.helperUnavailable
    case .persistenceRejected?:
        throw UninstallError.persistenceRejected
    case .releaseUnverified?:
        throw UninstallError.releaseUnverified
    }
}
```

The function order is: unregister login item, verified release, helper removal, defaults removal, user files. Any throw stops immediately.

- [ ] **Step 4: Remove the root policy only after bootout succeeds**

Change the privileged uninstall script and use the bundled current helper as the verifier:

```swift
static func uninstall() async throws {
    let verifier = bundledDaemonURL
    guard FileManager.default.isExecutableFile(atPath: verifier.path) else {
        throw InstallError.daemonMissing
    }
    try await runPrivileged("""
    set -eu
    '\(verifier.path)' --verify-battery-release
    was_running=false
    if launchctl print system/\(label) >/dev/null 2>&1; then
      was_running=true
      launchctl bootout system/\(label)
    fi
    if ! '\(verifier.path)' --verify-battery-release; then
      if $was_running; then
        launchctl bootstrap system '/Library/LaunchDaemons/\(label).plist'
      fi
      exit 74
    fi
    rm -f '/Library/PrivilegedHelperTools/\(label)' \
      '/Library/LaunchDaemons/\(label).plist' \
      '/Library/Application Support/Wattly/battery-control-v1.json'
    rmdir '/Library/Application Support/Wattly' 2>/dev/null || true
    """)
}
```

Do not retain the old `2>/dev/null || true` around `bootout`; verified release is meaningless if helper shutdown/removal silently fails. Add a generated-script test proving `set -eu`, conditional bootout, verifier, then removal ordering.

Replace `scripts/uninstall-fan-helper.sh` with the same gate. Resolve a current verifier from the Debug build product produced by `xcodebuild -showBuildSettings`; if it is absent, exit non-zero rather than using a possibly old installed helper. Then:

```bash
sudo "$verifier" --verify-battery-release
was_running=false
if sudo launchctl print "system/$label" >/dev/null 2>&1; then
  was_running=true
  sudo launchctl bootout "system/$label"
fi
if ! sudo "$verifier" --verify-battery-release; then
  $was_running && sudo launchctl bootstrap system "/Library/LaunchDaemons/$label.plist"
  exit 74
fi
sudo rm -f "/Library/PrivilegedHelperTools/$label" "/Library/LaunchDaemons/$label.plist" "/Library/Application Support/Wattly/battery-control-v1.json"
sudo rmdir "/Library/Application Support/Wattly" 2>/dev/null || true
```

Add `zsh -n scripts/uninstall-fan-helper.sh` and source-order assertions proving preflight → bootout → postflight → removals. A post-bootout verifier failure re-bootstraps the untouched old plist before exit, so direct callers never leave a previously loaded helper unloaded after an unverified release.

- [ ] **Step 5: Surface uninstall error in Settings**

Add `@State private var uninstallErrorMessage: String?`. Replace `try?`:

```swift
Task {
    do {
        try await AppUninstaller.uninstall()
    } catch {
        uninstallErrorMessage = error.localizedDescription
    }
}
```

Add an error alert bound to whether `uninstallErrorMessage != nil`, with title `"Wattly 삭제 중단"`, an `"확인"` button, and the verbatim error message.

- [ ] **Step 6: Run green and commit**

Run the validation command.

Expected: `** TEST SUCCEEDED **`; tests prove release failure never reaches helper removal or defaults deletion.

```bash
git add Wattly/Core/AppUninstaller.swift Wattly/Control/BatteryControlClient.swift Wattly/Control/FanHelperInstaller.swift Wattly/Views/SettingsView.swift WattlyTests/AppUninstallerTests.swift scripts/uninstall-fan-helper.sh
git commit -m "fix(battery): verify charging before helper removal"
```

---

### Task 10: Present maintenance evidence, helper update, and ownership transfer

**Files:**
- Modify: `Wattly/Core/BatterySectionPresentation.swift:10-238`
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift:6-390`
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Modify: `WattlyTests/BatterySectionPresentationTests.swift`
- Modify: `WattlyTests/LocalizationTests.swift`

**Interfaces:**
- Consumes: capabilities, `lastMaintenance`, `actualGate`, installer ownership error, and explicit transfer install.
- Produces: pure `MaintenanceStatus`, one compact UI row, retry/update/transfer actions, and exact localized copy.

- [ ] **Step 1: Add red presentation-table tests**

Add:

```swift
@Test func persistentHelperShowsLastWakeVerification() {
    let record = BatteryMaintenanceRecord(
        trigger: .wake, result: .verified, occurredAt: 100, reason: nil)
    let status = BatterySectionPresentation.maintenanceStatus(
        ownership: .owner(UInt32(getuid())),
        currentUID: UInt32(getuid()),
        capabilities: [.persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1],
        record: record,
        locale: Locale(identifier: "ko"),
        timestampText: { _ in "21:04" })
    #expect(status == .init(
        tone: .faint,
        text: "마지막 확인: Wake · 성공 · 21:04",
        action: nil))
}

@Test func missingCapabilitiesOfferHelperUpdate() {
    let status = BatterySectionPresentation.maintenanceStatus(
        ownership: .owner(UInt32(getuid())),
        currentUID: UInt32(getuid()),
        capabilities: nil,
        record: nil,
        locale: Locale(identifier: "ko"),
        timestampText: { _ in "21:04" })
    #expect(status?.action == .updateHelper)
    #expect(status?.text == "앱 종료·Sleep 유지를 사용하려면 도우미 업데이트가 필요합니다.")
}

@Test func failedMaintenanceOffersRetry() {
    let record = BatteryMaintenanceRecord(
        trigger: .wake,
        result: .failed,
        occurredAt: 100,
        reason: .init(kind: .hardwareReadbackFailed))
    let status = BatterySectionPresentation.maintenanceStatus(
        ownership: .owner(UInt32(getuid())),
        currentUID: UInt32(getuid()),
        capabilities: BatteryControlCoordinator.capabilities,
        record: record,
        locale: Locale(identifier: "ko"),
        timestampText: { _ in "21:04" })
    #expect(status?.tone == .red)
    #expect(status?.action == .retry)
}
```

The production default `timestampText` closure uses one `DateFormatter` configured with the passed locale, `.autoupdatingCurrent` time zone, and `.short` date/time styles. Tests inject the literal closure above, so they never depend on the machine time zone.

- [ ] **Step 2: Run and verify red**

Expected: FAIL because `MaintenanceStatus` and `maintenanceStatus` do not exist.

- [ ] **Step 3: Implement the pure maintenance presentation**

```swift
enum MaintenanceAction: Equatable {
    case retry
    case updateHelper
    case transferOwnership
}

struct MaintenanceStatus: Equatable {
    let tone: Tone
    let text: String
    let action: MaintenanceAction?
}
```

Resolution order:

1. Explicit different-owner state → red, ownership text, `.transferOwnership`.
2. Missing any of the three required capabilities → orange, helper-update text, `.updateHelper`.
3. Failed record → red for release/readback/persistence failure, reason-localized text, `.retry`.
4. Successful record → faint timestamp, no action.
5. No record on a capable helper → faint `"충전 정책 확인 전"`, no action.

Use this exact signature so ownership is testable even when XPC is rejected:

```swift
static func maintenanceStatus(
    ownership: FanHelperInstaller.InstalledOwnership,
    currentUID: UInt32,
    capabilities: [BatteryControlCapability]?,
    record: BatteryMaintenanceRecord?,
    locale: Locale,
    timestampText: (Date) -> String = defaultMaintenanceTimestamp
) -> MaintenanceStatus?
```

Map triggers exactly:

```text
startup → 시작
wake → Wake
clientConfiguration → 설정 변경
adapterTransition → 전원 전환
termination → 종료
unrecognized → 알 수 없음
```

`BatteryMaintenanceResult.unrecognized` renders as failure with the existing generic unknown text; it never enters the successful-record branch.

- [ ] **Step 4: Add the compact row and actions**

Render below `batteryStatusIndicator`, inside the same padded VStack:

```swift
if let maintenance = resolvedMaintenanceStatus {
    HStack(spacing: 8) {
        Image(systemName: maintenance.tone == .red
              ? "exclamationmark.triangle.fill"
              : "clock.arrow.circlepath")
            .accessibilityHidden(true)
        Text(verbatim: maintenance.text)
            .font(WattlyFont.at(10.5, weight: .regular))
            .foregroundStyle(statusColor(for: maintenance.tone))
            .fixedSize(horizontal: false, vertical: true)
        Spacer()
        maintenanceActionButton(maintenance.action)
    }
    .accessibilityElement(children: .combine)
}
```

Actions:

- `.retry`: call `apply` with the current full configuration.
- `.updateHelper`: call existing `installAndApply` with `transferringOwnership: false`.
- `.transferOwnership`: show a destructive confirmation that states the other user’s policy will be released, then call installer with `transferringOwnership: true` and apply this user’s configuration.

Never start an admin prompt from polling, wake, or app launch; only explicit button actions may install or transfer.

Add `@State private var installedOwnership = FanHelperInstaller.InstalledOwnership.notInstalled` to the view and set it from `FanHelperInstaller.installedOwnership()` in the existing initial `.task` after the first status refresh. Pass that value and `UInt32(getuid())` to the pure presentation function. Both `.owner(otherUID)` and `.invalidMetadata` map to the transfer action; refresh the state after helper update or ownership transfer.

- [ ] **Step 5: Add exact String Catalog keys and localization tests**

Add these Korean source keys and English translations:

```text
마지막 확인: %@ · 성공 · %@ = Last check: %@ · succeeded · %@
충전 정책 확인 전 = Charge policy not checked yet
앱 종료·Sleep 유지를 사용하려면 도우미 업데이트가 필요합니다. = Update the helper to keep charge control active after app exit and during sleep.
도우미 업데이트 = Update Helper
다시 확인 = Check Again
다른 사용자의 충전 정책을 해제하고 이 사용자로 소유권을 이전합니다. = Release the other user's charge policy and transfer ownership to this user.
소유권 이전 = Transfer Ownership
Wattly 삭제 중단 = Wattly Removal Stopped
```

Extend localization key-existence tests and VoiceOver assertions for each action button.

- [ ] **Step 6: Run green and commit UI**

Run the validation command.

Expected: `** TEST SUCCEEDED **`.

```bash
git add Wattly/Core/BatterySectionPresentation.swift \
  Wattly/Views/Settings/SettingsBatterySection.swift \
  Wattly/Resources/Localizable.xcstrings \
  WattlyTests/BatterySectionPresentationTests.swift \
  WattlyTests/LocalizationTests.swift
git commit -m "feat(battery): show persistence maintenance status"
```

---

### Task 11: Run full integration gates and close the feature document

**Files:**
- Modify: `docs/features/battery-management/06-charge-persistence-sleep-app-exit.md:3-53`
- Verify: `project.yml`
- Verify: `Resources/com.dev.jjundev.WattlyFanDaemon.plist`
- Verify: every file touched by Tasks 1–10

**Interfaces:**
- Consumes: the complete implementation.
- Produces: regenerated project, full automated evidence, explicit manual matrix, and source-of-truth feature documentation.

- [ ] **Step 1: Regenerate and run the entire automated gate from a clean DerivedData path**

```bash
WATTLY_PERSISTENCE_DD=/private/tmp/wattly-charge-persistence-derived-data
xcodegen generate
xcodebuild -project Wattly.xcodeproj \
  -scheme Wattly \
  -destination 'platform=macOS' \
  -derivedDataPath "$WATTLY_PERSISTENCE_DD" \
  test
```

Expected: `** TEST SUCCEEDED **`; no suite/test count is copied from an older run.

- [ ] **Step 2: Validate project and launchd artifacts**

```bash
plutil -lint Resources/com.dev.jjundev.WattlyFanDaemon.plist
zsh -n scripts/install-fan-helper.sh
zsh -n scripts/uninstall-fan-helper.sh
xcodebuild -project Wattly.xcodeproj -scheme Wattly \
  -configuration Debug -destination 'platform=macOS' build
WATTLY_PRODUCTS=$(xcodebuild -project Wattly.xcodeproj -scheme Wattly \
  -configuration Debug -showBuildSettings |
  awk -F ' = ' '/TARGET_BUILD_DIR/ {print $2; exit}')
test -x "$WATTLY_PRODUCTS/Wattly.app/Contents/Helpers/WattlyFanDaemon"
```

Expected: plist reports `OK`, both shell syntax checks exit 0, build reports `** BUILD SUCCEEDED **`, embedded helper test exits 0.

- [ ] **Step 3: Install the current helper and verify owner/store metadata**

Run from the logged-in owner account:

```bash
./scripts/install-fan-helper.sh
launchctl print system/dev.jjundev.WattlyFanDaemon
sudo plutil -p /Library/LaunchDaemons/dev.jjundev.WattlyFanDaemon.plist
```

Expected: helper is running and `WATTLY_ALLOWED_UID` equals `id -u`. Enable an 80% limit once in Settings, then:

```bash
sudo stat -f '%Su %Sg %Lp' \
  '/Library/Application Support/Wattly/battery-control-v1.json'
sudo plutil -p \
  '/Library/Application Support/Wattly/battery-control-v1.json'
```

Expected: `root wheel 600`; JSON reports schema 1, the owner UID, enabled true, and the selected normalized values.

- [ ] **Step 4: Execute the modern-register app-exit/restart matrix**

On the measured `CHTE` Mac, record battery percentage, adapter state, `CHTE` readback, UI maintenance record, and outcome for each row:

```text
1. Enable 80%, quit Wattly normally, keep helper running.
2. Relaunch Wattly; confirm status-first reconcile causes no redundant SMC write.
3. Quit Wattly, SIGTERM the helper, observe KeepAlive restart and startup restore.
4. Quit Wattly, SIGKILL the helper, observe KeepAlive restart and startup restore.
5. Sleep with the gate inhibited, then wake; confirm completed-wake readback and one reconcile.
6. Repeat with SoC inside the hysteresis band for both pre-sleep allowed and inhibited gates.
7. Disconnect and reconnect the adapter; confirm one new recovery window.
8. Disable the limit; confirm desired enabled=false and actual gate=allowed.
```

Use:

```bash
osascript -e 'quit app "Wattly"'
pgrep -x WattlyFanDaemon
sudo kill -TERM "$(pgrep -x WattlyFanDaemon)"
sudo kill -KILL "$(pgrep -x WattlyFanDaemon)"
pmset sleepnow
```

Expected: the app process is not required for rows 1, 3, 4, or 5; no row exceeds three consecutive routine failed writes.

- [ ] **Step 5: Execute ownership and uninstall safety matrix**

```text
1. Fast-switch to a second non-root macOS user and launch Wattly.
2. Confirm XPC policy mutation is rejected and Settings offers explicit ownership transfer.
3. Cancel transfer; confirm the original owner policy remains.
4. Accept transfer with admin authentication; confirm plist/store owner UID changes and the new policy is applied only after durable save.
5. Force readback failure and request full uninstall; confirm deletion stops before helper/store/default removal.
6. Restore readback, disable, and run full uninstall; confirm gate allowed before helper/store disappear.
```

Do not claim fast-user-switch support until both accounts have been exercised on the same Mac.

- [ ] **Step 6: Record generation-specific evidence without overclaiming**

Run the same readback/apply/release subset on available `CH0B/CH0C` and `BCLM` hardware. In the feature doc, use one of these exact labels per generation:

```text
자동 테스트 통과 · 실기 검증 완료
자동 테스트 통과 · 해당 세대 실기 미검증
지원하지 않음 · firmware-managed hands-off
```

Never infer legacy/Intel success from the modern Mac.

- [ ] **Step 7: Update the feature document**

Replace “기능 정의 초안” and the three open decisions with:

```markdown
- 단계: 구현 및 자동 검증 완료
- 앱 정상 종료: 정책 유지(별도 옵션 없음)
- 사용자 전환: helper 설치 UID 단일 소유, 명시적 재설치로만 이전
- Sleep/Wake: LaunchDaemon의 IORegisterForSystemPower 완료-wake 이벤트에서 실제 레지스터 재확인
- Helper 재시작: root 소유 원자적 정책 파일을 읽어 앱 없이 복원
- 비활성화/제거: 실제 충전 허용 readback 확인 전에는 완료하지 않음
```

If any physical row remains unverified, set the first line instead to:

```markdown
- 단계: 구현 및 자동 검증 완료 · 실기 검증 진행 중
```

Document the exact generation evidence labels from Step 6 and the hard limitation that manual root deletion/SIGKILL with launchd also removed cannot be recovered by absent user-space code; Wattly covers managed disable, uninstall, termination, and KeepAlive restart paths.

- [ ] **Step 8: Run final static hygiene**

```bash
git diff --check -- \
  FanControlShared \
  WattlyFanDaemon \
  Wattly \
  WattlyTests \
  scripts/install-fan-helper.sh \
  scripts/uninstall-fan-helper.sh \
  Resources/com.dev.jjundev.WattlyFanDaemon.plist \
  project.yml \
  docs/features/battery-management/06-charge-persistence-sleep-app-exit.md
rg -n 'T[B]D|T[O]DO|implement l[a]ter|fill in d[e]tails' \
  docs/features/battery-management/06-charge-persistence-sleep-app-exit.md
git status --short
```

Expected: `git diff --check` and placeholder scan print nothing; status contains only this feature’s intended files plus pre-existing user changes.

- [ ] **Step 9: Commit validation documentation**

```bash
git add docs/features/battery-management/06-charge-persistence-sleep-app-exit.md \
  project.yml Wattly.xcodeproj
git commit -m "docs(battery): record persistence validation boundaries"
```

## Final acceptance checklist

- [ ] Normal app exit sends no release and helper keeps the durable policy.
- [ ] Helper startup restores matching-owner policy before serving XPC.
- [ ] Corrupt/missing/wrong-owner store fails safe and attempts verified charging release.
- [ ] Every configure saves before the first hardware write.
- [ ] CHTE, CH0B, and BCLM readback parsers reject malformed payloads.
- [ ] Wake work happens only at `kIOMessageSystemHasPoweredOn`.
- [ ] Sleep is always acknowledged and battery is never released merely because sleep begins.
- [ ] Ordinary sampling/status polling does not re-arm write failures.
- [ ] Retry windows open only on the four named boundaries.
- [ ] New helper compares the full desired configuration; legacy helper fallback remains decodable.
- [ ] A second UID cannot silently take ownership.
- [ ] App and shell helper replacement/removal paths run the current one-shot release verifier before replacing or deleting files.
- [ ] Disable and uninstall require `actualGate.state == .allowed`.
- [ ] Managed SIGTERM requires both battery release and fan automatic recovery.
- [ ] Settings shows capability/update, ownership, last maintenance, and failure recovery without background auth prompts.
- [ ] Full Swift Testing suite passes after `xcodegen generate`.
- [ ] Physical evidence is labeled separately for modern, legacy, Intel, and firmware-managed hardware.
