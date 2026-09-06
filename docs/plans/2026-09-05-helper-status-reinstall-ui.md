# Helper Status & Reinstall UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide a dedicated "시스템 도우미" (Privileged Helper) health status check and one-click reinstall/recovery UI in the "일반" (General) tab of Wattly's Settings window.

**Architecture:** 
- A pure domain/presentation model `HelperHealthStatus` evaluates multi-source health signals (LaunchDaemon plist ownership, XPC responsiveness from `BatteryControlClient` and `FanControlClient`, and bundle vs installed binary match) into an actionable `HelperHealthState`.
- `HelperHealthCoordinator` coordinates asynchronous health polling, binary inspection, and privileged reinstall sessions via `PrivilegedHelperInstallSession.run`, followed by immediate settings re-application.
- `SettingsHelperRow` renders the status badge, info popover (with diagnostic details), and contextual action buttons (Install / Update / Recover / Reinstall...) embedded in `SettingsView`'s general card below Software Update.

**Tech Stack:** Swift 6.0 (Strict Concurrency), SwiftUI, AppKit, Swift Testing (`import Testing`), macOS 14.0+ on Apple Silicon (arm64).

## Global Constraints

- Swift 6 language mode with complete concurrency checking (`SWIFT_VERSION: "6.0"`).
- Target platform: macOS 14.0+ on Apple Silicon (arm64).
- Ad-hoc code signing (`CODE_SIGN_IDENTITY: "-"`).
- Pure logic must be separated from SwiftUI views and covered with unit tests using Swift Testing (`#expect`, `@Suite`, `@Test`).
- No modifications to the root daemon (`WattlyFanDaemon`) or XPC protocol; all detection and reinstallation relies on existing IPC endpoints, `PrivilegedHelperInstallSession`, and file system attributes.
- Maintain existing visual rhythm and design tokens (`Tokens.cardRadius`, `t.line`, `t.rowBg`, `t.segTrack`, `WattlyFont`).
- Source language for strings is Korean (`ko`).

---

### Task 1: Domain Model and Pure Health Evaluation Logic

**Files:**
- Create: `Wattly/Control/HelperHealthStatus.swift`
- Modify: `Wattly.xcodeproj/project.pbxproj` (add `HelperHealthStatus.swift` and `HelperHealthStatusTests.swift`)
- Test: `WattlyTests/HelperHealthStatusTests.swift`

**Interfaces:**
- Produces:
  - `enum HelperHealthState: Equatable, Sendable`: `.checking`, `.notInstalled`, `.running`, `.updateAvailable(reason: String)`, `.unavailable(detail: String)`, `.ownershipMismatch(ownerUID: UInt32)`, `.installing`
  - `struct HelperDiagnosticDetails: Equatable, Sendable`: contains `installedOwnership`, `currentUID`, `batteryMode`, `fanMode`, `installedBinaryExists`, `bundledBinaryExists`, `binaryMatch`, `missingCapabilities`
  - `enum HelperHealthStatus`:
    `static func resolve(ownership: FanHelperInstaller.InstalledOwnership, currentUID: UInt32, batteryMode: BatteryControlServiceMode, fanMode: FanControlServiceMode, bundledBinaryExists: Bool, installedBinaryExists: Bool, binaryMatch: Bool?, capabilities: [BatteryControlCapability]?) -> HelperHealthState`

- [ ] **Step 1: Write the failing unit tests for `HelperHealthStatus`**

Create `WattlyTests/HelperHealthStatusTests.swift`:

```swift
import Testing
import Foundation
@testable import Wattly

@Suite("HelperHealthStatusTests")
struct HelperHealthStatusTests {
    private let currentUID: UInt32 = 501
    private let requiredCapabilities: [BatteryControlCapability] = [
        .persistedPolicyV1,
        .hardwareGateReadbackV1,
        .systemPowerEventsV1
    ]

    @Test func resolvesNotInstalledWhenPlistOrBinaryMissing() {
        // Plist not installed
        let state1 = HelperHealthStatus.resolve(
            ownership: .notInstalled,
            currentUID: currentUID,
            batteryMode: .unavailable,
            fanMode: .unavailable,
            bundledBinaryExists: true,
            installedBinaryExists: false,
            binaryMatch: nil,
            capabilities: nil
        )
        #expect(state1 == .notInstalled)

        // Plist exists but installed binary missing
        let state2 = HelperHealthStatus.resolve(
            ownership: .owner(currentUID),
            currentUID: currentUID,
            batteryMode: .unavailable,
            fanMode: .unavailable,
            bundledBinaryExists: true,
            installedBinaryExists: false,
            binaryMatch: nil,
            capabilities: nil
        )
        #expect(state2 == .notInstalled)
    }

    @Test func resolvesOwnershipMismatchWhenOwnerUIDDiffers() {
        let otherUID: UInt32 = 502
        let state = HelperHealthStatus.resolve(
            ownership: .owner(otherUID),
            currentUID: currentUID,
            batteryMode: .charging,
            fanMode: .controlling,
            bundledBinaryExists: true,
            installedBinaryExists: true,
            binaryMatch: true,
            capabilities: requiredCapabilities
        )
        #expect(state == .ownershipMismatch(ownerUID: otherUID))
    }

    @Test func resolvesUnavailableWhenProcessNotResponding() {
        let state = HelperHealthStatus.resolve(
            ownership: .owner(currentUID),
            currentUID: currentUID,
            batteryMode: .unavailable,
            fanMode: .unavailable,
            bundledBinaryExists: true,
            installedBinaryExists: true,
            binaryMatch: true,
            capabilities: nil
        )
        #expect(state == .unavailable(detail: "도우미에 연결되지 않음"))
    }

    @Test func resolvesUpdateAvailableWhenCapabilitiesMissing() {
        let state = HelperHealthStatus.resolve(
            ownership: .owner(currentUID),
            currentUID: currentUID,
            batteryMode: .charging,
            fanMode: .controlling,
            bundledBinaryExists: true,
            installedBinaryExists: true,
            binaryMatch: true,
            capabilities: [.persistedPolicyV1] // missing 2 capabilities
        )
        #expect(state == .updateAvailable(reason: "필수 기능(하드웨어 게이트 / 시스템 전원 감지) 업데이트 필요"))
    }

    @Test func resolvesUpdateAvailableWhenBinaryMismatch() {
        let state = HelperHealthStatus.resolve(
            ownership: .owner(currentUID),
            currentUID: currentUID,
            batteryMode: .charging,
            fanMode: .controlling,
            bundledBinaryExists: true,
            installedBinaryExists: true,
            binaryMatch: false, // bundle binary differs from installed
            capabilities: requiredCapabilities
        )
        #expect(state == .updateAvailable(reason: "최신 앱 번들 도우미 바이너리 업데이트 사용 가능"))
    }

    @Test func resolvesRunningWhenAllHealthy() {
        let state = HelperHealthStatus.resolve(
            ownership: .owner(currentUID),
            currentUID: currentUID,
            batteryMode: .charging,
            fanMode: .controlling,
            bundledBinaryExists: true,
            installedBinaryExists: true,
            binaryMatch: true,
            capabilities: requiredCapabilities
        )
        #expect(state == .running)
    }
}
```

- [ ] **Step 2: Register files in `Wattly.xcodeproj/project.pbxproj` and run test to verify failure**

Add PBXFileReference, PBXBuildFile, and Sources build phase entries for `HelperHealthStatus.swift` in `Wattly` target, and `HelperHealthStatusTests.swift` in `WattlyTests` target.

Run:
```bash
xcodebuild -scheme Wattly -configuration Debug -derivedDataPath /tmp/WattlyDerivedData -only-testing:WattlyTests/HelperHealthStatusTests test
```
Expected: FAIL with compilation error "cannot find 'HelperHealthStatus' in scope".

- [ ] **Step 3: Implement `HelperHealthStatus.swift`**

Create `Wattly/Control/HelperHealthStatus.swift`:

```swift
import Foundation

enum HelperHealthState: Equatable, Sendable {
    case checking
    case notInstalled
    case running
    case updateAvailable(reason: String)
    case unavailable(detail: String)
    case ownershipMismatch(ownerUID: UInt32)
    case installing

    var isActionable: Bool {
        switch self {
        case .checking, .installing: false
        case .notInstalled, .running, .updateAvailable, .unavailable, .ownershipMismatch: true
        }
    }
}

struct HelperDiagnosticDetails: Equatable, Sendable {
    var installedOwnership: FanHelperInstaller.InstalledOwnership
    var currentUID: UInt32
    var batteryMode: BatteryControlServiceMode
    var fanMode: FanControlServiceMode
    var installedBinaryExists: Bool
    var bundledBinaryExists: Bool
    var binaryMatch: Bool?
    var capabilities: [BatteryControlCapability]?
    var missingCapabilities: [BatteryControlCapability]
    var checkedAt: Date

    init(
        installedOwnership: FanHelperInstaller.InstalledOwnership = .notInstalled,
        currentUID: UInt32 = UInt32(getuid()),
        batteryMode: BatteryControlServiceMode = .unavailable,
        fanMode: FanControlServiceMode = .unavailable,
        installedBinaryExists: Bool = false,
        bundledBinaryExists: Bool = false,
        binaryMatch: Bool? = nil,
        capabilities: [BatteryControlCapability]? = nil,
        missingCapabilities: [BatteryControlCapability] = [],
        checkedAt: Date = Date()
    ) {
        self.installedOwnership = installedOwnership
        self.currentUID = currentUID
        self.batteryMode = batteryMode
        self.fanMode = fanMode
        self.installedBinaryExists = installedBinaryExists
        self.bundledBinaryExists = bundledBinaryExists
        self.binaryMatch = binaryMatch
        self.capabilities = capabilities
        self.missingCapabilities = missingCapabilities
        self.checkedAt = checkedAt
    }
}

enum HelperHealthStatus {
    static let requiredCapabilities: [BatteryControlCapability] = [
        .persistedPolicyV1,
        .hardwareGateReadbackV1,
        .systemPowerEventsV1
    ]

    static func resolve(
        ownership: FanHelperInstaller.InstalledOwnership,
        currentUID: UInt32 = UInt32(getuid()),
        batteryMode: BatteryControlServiceMode,
        fanMode: FanControlServiceMode,
        bundledBinaryExists: Bool,
        installedBinaryExists: Bool,
        binaryMatch: Bool?,
        capabilities: [BatteryControlCapability]?
    ) -> HelperHealthState {
        // 1. Not installed if plist is absent or installed binary file doesn't exist
        if ownership == .notInstalled || !installedBinaryExists {
            return .notInstalled
        }

        // 2. Ownership mismatch
        switch ownership {
        case .owner(let ownerUID) where ownerUID != currentUID:
            return .ownershipMismatch(ownerUID: ownerUID)
        case .invalidMetadata:
            return .ownershipMismatch(ownerUID: 0)
        case .notInstalled, .owner:
            break
        }

        // 3. XPC Communication availability
        let isBatteryAlive = batteryMode != .unavailable
        let isFanAlive = fanMode != .unavailable
        guard isBatteryAlive || isFanAlive else {
            return .unavailable(detail: String(localized: "도우미에 연결되지 않음"))
        }

        // 4. Missing capabilities
        if let capabilities {
            let missing = requiredCapabilities.filter { !capabilities.contains($0) }
            if !missing.isEmpty {
                return .updateAvailable(reason: String(localized: "필수 기능(하드웨어 게이트 / 시스템 전원 감지) 업데이트 필요"))
            }
        } else if isBatteryAlive {
            // Battery responded but sent no capabilities -> legacy helper
            return .updateAvailable(reason: String(localized: "구버전 도우미가 설치되어 있습니다"))
        }

        // 5. Binary file difference
        if binaryMatch == false {
            return .updateAvailable(reason: String(localized: "최신 앱 번들 도우미 바이너리 업데이트 사용 가능"))
        }

        return .running
    }
}
```

- [ ] **Step 4: Run unit tests to verify they pass**

Run:
```bash
xcodebuild -scheme Wattly -configuration Debug -derivedDataPath /tmp/WattlyDerivedData -only-testing:WattlyTests/HelperHealthStatusTests test
```
Expected: PASS with 6/6 passed.

- [ ] **Step 5: Commit Task 1**

```bash
git add Wattly/Control/HelperHealthStatus.swift WattlyTests/HelperHealthStatusTests.swift Wattly.xcodeproj/project.pbxproj
git commit -m "feat: add HelperHealthStatus domain model and pure evaluation logic"
```

---

### Task 2: Helper Health Coordinator

**Files:**
- Create: `Wattly/Control/HelperHealthCoordinator.swift`
- Modify: `Wattly.xcodeproj/project.pbxproj` (add `HelperHealthCoordinator.swift` and `HelperHealthCoordinatorTests.swift`)
- Test: `WattlyTests/HelperHealthCoordinatorTests.swift`

**Interfaces:**
- Consumes:
  - `HelperHealthStatus`, `HelperHealthState`, `HelperDiagnosticDetails`
  - `FanHelperInstaller`, `PrivilegedHelperInstallSession`
  - `BatteryControlClient`, `FanControlClient`
- Produces:
  - `@Observable @MainActor final class HelperHealthCoordinator`
  - `var state: HelperHealthState { get }`
  - `var diagnostics: HelperDiagnosticDetails { get }`
  - `func checkHealth() async -> HelperHealthState`
  - `func reinstall(transferringOwnership: Bool, window: NSWindow?, reapplySettings: @escaping @MainActor () async -> Void) async throws`

- [ ] **Step 1: Write unit tests in `WattlyTests/HelperHealthCoordinatorTests.swift`**

Create `WattlyTests/HelperHealthCoordinatorTests.swift`:

```swift
import Testing
import Foundation
@testable import Wattly

@Suite("HelperHealthCoordinatorTests")
struct HelperHealthCoordinatorTests {
    @Test @MainActor func checkHealthUpdatesStateAndDiagnostics() async {
        let batteryClient = BatteryControlClient(requestHandler: { _ in
            let status = BatteryControlServiceStatus(
                mode: .charging,
                currentPercentage: 80,
                isPowerAdapterConnected: true,
                detail: "정상",
                updatedAt: Date().timeIntervalSince1970,
                capabilities: HelperHealthStatus.requiredCapabilities
            )
            let data = try? BatteryControlCodec.encode(status)
            return (data, nil)
        })
        let fanClient = FanControlClient(requestHandler: { _ in
            .success(FanControlServiceStatus(
                mode: .controlling,
                detail: "정상",
                updatedAt: Date().timeIntervalSince1970
            ))
        })

        let coordinator = HelperHealthCoordinator(
            batteryControl: batteryClient,
            fanControl: fanClient,
            installedOwnershipProvider: { .owner(UInt32(getuid())) },
            binaryInspectionProvider: { (bundledExists: true, installedExists: true, match: true) },
            installRunner: { _, _, _ in nil }
        )

        let resolved = await coordinator.checkHealth()
        #expect(resolved == .running)
        #expect(coordinator.state == .running)
        #expect(coordinator.diagnostics.installedBinaryExists == true)
        #expect(coordinator.diagnostics.batteryMode == .charging)
        #expect(coordinator.diagnostics.fanMode == .controlling)
    }

    @Test @MainActor func reinstallCallsRunnerAndReappliesSettings() async {
        var didReapply = false
        var didRunInstall = false

        let coordinator = HelperHealthCoordinator(
            batteryControl: BatteryControlClient(requestHandler: { _ in (nil, nil) }),
            fanControl: FanControlClient(requestHandler: { _ in .failure(.init(detail: "err")) }),
            installedOwnershipProvider: { .owner(UInt32(getuid())) },
            binaryInspectionProvider: { (true, true, true) },
            installRunner: { _, transferring, postInstall in
                didRunInstall = true
                await postInstall()
                return nil
            }
        )

        try? await coordinator.reinstall(transferringOwnership: false, window: nil) {
            didReapply = true
        }

        #expect(didRunInstall == true)
        #expect(didReapply == true)
    }

    @Test @MainActor func reinstallPropagatesFailureAndRefreshesHealth() async {
        struct MockError: LocalizedError {
            var errorDescription: String? { "Authorization failed" }
        }
        var healthCheckCount = 0
        let coordinator = HelperHealthCoordinator(
            batteryControl: BatteryControlClient(requestHandler: { _ in (nil, nil) }),
            fanControl: FanControlClient(requestHandler: { _ in .failure(.init(detail: "err")) }),
            installedOwnershipProvider: {
                healthCheckCount += 1
                return .notInstalled
            },
            binaryInspectionProvider: { (true, false, nil) },
            installRunner: { _, _, _ in MockError() }
        )

        do {
            try await coordinator.reinstall(transferringOwnership: false, window: nil) {}
            #expect(Bool(false), "Expected reinstall to throw")
        } catch {
            #expect(error.localizedDescription == "Authorization failed")
        }

        #expect(healthCheckCount > 0)
        #expect(coordinator.state == .notInstalled)
    }
}
```

- [ ] **Step 2: Register files in `Wattly.xcodeproj/project.pbxproj` and run test to verify failure**

Add entries for `HelperHealthCoordinator.swift` and `HelperHealthCoordinatorTests.swift`.

Run:
```bash
xcodebuild -scheme Wattly -configuration Debug -derivedDataPath /tmp/WattlyDerivedData -only-testing:WattlyTests/HelperHealthCoordinatorTests test
```
Expected: FAIL with compilation error "cannot find 'HelperHealthCoordinator' in scope".

- [ ] **Step 3: Implement `HelperHealthCoordinator.swift`**

Create `Wattly/Control/HelperHealthCoordinator.swift`:

```swift
import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class HelperHealthCoordinator {
    typealias OwnershipProvider = @Sendable () -> FanHelperInstaller.InstalledOwnership
    typealias BinaryInspectionProvider = @Sendable () -> (bundledExists: Bool, installedExists: Bool, match: Bool?)
    typealias InstallRunner = @MainActor (NSWindow?, Bool, @escaping @MainActor () async -> Void) async -> Error?

    private(set) var state: HelperHealthState = .checking
    private(set) var diagnostics: HelperDiagnosticDetails = HelperDiagnosticDetails()

    private let batteryControl: BatteryControlClient
    private let fanControl: FanControlClient
    private let ownershipProvider: OwnershipProvider
    private let binaryInspectionProvider: BinaryInspectionProvider
    private let installRunner: InstallRunner

    init(
        batteryControl: BatteryControlClient,
        fanControl: FanControlClient,
        ownershipProvider: OwnershipProvider? = nil,
        binaryInspectionProvider: BinaryInspectionProvider? = nil,
        installRunner: InstallRunner? = nil
    ) {
        self.batteryControl = batteryControl
        self.fanControl = fanControl
        self.ownershipProvider = ownershipProvider ?? { FanHelperInstaller.installedOwnership() }
        self.binaryInspectionProvider = binaryInspectionProvider ?? Self.defaultBinaryInspection
        self.installRunner = installRunner ?? { window, transferringOwnership, postInstall in
            await PrivilegedHelperInstallSession.run(
                window: window,
                transferringOwnership: transferringOwnership,
                postInstall: postInstall
            )
        }
    }

    @discardableResult
    func checkHealth() async -> HelperHealthState {
        state = .checking
        let currentUID = UInt32(getuid())
        let ownership = ownershipProvider()
        let binaryInfo = binaryInspectionProvider()

        // Probe both subsystems concurrently
        async let batteryStatus = batteryControl.refreshStatus()
        async let fanStatus = fanControl.refreshStatus()
        let (bStatus, fStatus) = await (batteryStatus, fanStatus)

        let batteryMode = bStatus?.mode ?? batteryControl.status.mode
        let fanMode = fStatus?.mode ?? fanControl.status.mode
        let capabilities = bStatus?.capabilities ?? batteryControl.status.capabilities

        let missing = HelperHealthStatus.requiredCapabilities.filter { cap in
            capabilities?.contains(cap) != true
        }

        let resolved = HelperHealthStatus.resolve(
            ownership: ownership,
            currentUID: currentUID,
            batteryMode: batteryMode,
            fanMode: fanMode,
            bundledBinaryExists: binaryInfo.bundledExists,
            installedBinaryExists: binaryInfo.installedExists,
            binaryMatch: binaryInfo.match,
            capabilities: capabilities
        )

        diagnostics = HelperDiagnosticDetails(
            installedOwnership: ownership,
            currentUID: currentUID,
            batteryMode: batteryMode,
            fanMode: fanMode,
            installedBinaryExists: binaryInfo.installedExists,
            bundledBinaryExists: binaryInfo.bundledExists,
            binaryMatch: binaryInfo.match,
            capabilities: capabilities,
            missingCapabilities: missing,
            checkedAt: Date()
        )
        state = resolved
        return resolved
    }

    func reinstall(
        transferringOwnership: Bool = false,
        window: NSWindow?,
        reapplySettings: @escaping @MainActor () async -> Void
    ) async throws {
        state = .installing
        let failure = await installRunner(window, transferringOwnership) {
            await reapplySettings()
        }
        if let failure {
            await checkHealth()
            throw failure
        }
        await checkHealth()
    }

    private static func defaultBinaryInspection() -> (bundledExists: Bool, installedExists: Bool, match: Bool?) {
        let fm = FileManager.default
        let bundledURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/WattlyFanDaemon")
        let installedURL = URL(fileURLWithPath: FanControlXPC.daemonPath)

        let bundledExists = fm.fileExists(atPath: bundledURL.path)
        let installedExists = fm.fileExists(atPath: installedURL.path)

        guard bundledExists, installedExists else {
            return (bundledExists, installedExists, nil)
        }

        // Compare file sizes first
        guard let bAttr = try? fm.attributesOfItem(atPath: bundledURL.path),
              let iAttr = try? fm.attributesOfItem(atPath: installedURL.path),
              let bSize = bAttr[.size] as? NSNumber,
              let iSize = iAttr[.size] as? NSNumber else {
            return (bundledExists, installedExists, nil)
        }

        if bSize != iSize {
            return (bundledExists, installedExists, false)
        }

        // If sizes match, compare bytes or fast hash
        if let bData = try? Data(contentsOf: bundledURL),
           let iData = try? Data(contentsOf: installedURL) {
            return (bundledExists, installedExists, bData == iData)
        }

        return (bundledExists, installedExists, nil)
    }
}
```

- [ ] **Step 4: Run unit tests to verify they pass**

Run:
```bash
xcodebuild -scheme Wattly -configuration Debug -derivedDataPath /tmp/WattlyDerivedData -only-testing:WattlyTests/HelperHealthCoordinatorTests test
```
Expected: PASS with 2/2 passed.

- [ ] **Step 5: Commit Task 2**

```bash
git add Wattly/Control/HelperHealthCoordinator.swift WattlyTests/HelperHealthCoordinatorTests.swift Wattly.xcodeproj/project.pbxproj
git commit -m "feat: add HelperHealthCoordinator for lifecycle and diagnostics orchestration"
```

---

### Task 3: Settings Helper Row, Diagnostic Popover, and Alerts

**Files:**
- Create: `Wattly/Views/Settings/SettingsHelperRow.swift`
- Modify: `Wattly.xcodeproj/project.pbxproj` (add `SettingsHelperRow.swift`)

**Interfaces:**
- Consumes:
  - `HelperHealthCoordinator`, `HelperHealthState`, `HelperDiagnosticDetails`
  - `Tokens`, `WattlyFont`, `SettingsRowTitle`, `SettingsCard`
- Produces:
  - `struct SettingsHelperRow: View`: renders the complete Settings row, popover, and alerts.

- [ ] **Step 1: Implement `SettingsHelperRow.swift`**

Create `Wattly/Views/Settings/SettingsHelperRow.swift`:

```swift
import SwiftUI
import AppKit

struct SettingsHelperRow: View {
    @Environment(\.tokens) private var t
    @Environment(\.locale) private var locale

    let coordinator: HelperHealthCoordinator
    var hasFan: Bool = true
    let onReapplySettings: @MainActor () async -> Void

    @State private var isDiagnosticsPopoverPresented = false
    @State private var isReinstallConfirmPresented = false
    @State private var isOwnershipTransferConfirmPresented = false
    @State private var errorMessage: String?

    init(
        coordinator: HelperHealthCoordinator,
        hasFan: Bool = true,
        onReapplySettings: @escaping @MainActor () async -> Void
    ) {
        self.coordinator = coordinator
        self.hasFan = hasFan
        self.onReapplySettings = onReapplySettings
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                SettingsRowTitle("시스템 도우미")
                HStack(spacing: 6) {
                    statusSymbol
                    statusLabel
                    infoButton
                }
            }

            Spacer(minLength: 8)

            actionButton
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .task {
            await coordinator.checkHealth()
        }
        .alert("시스템 도우미 재설치", isPresented: $isReinstallConfirmPresented) {
            Button("재설치", role: .none) {
                triggerReinstall(transferringOwnership: false)
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("시스템 도우미를 재설치하고 서비스를 다시 시작합니다. 관리자 암호 입력이 필요합니다.")
        }
        .alert("소유권 이전 및 재설치", isPresented: $isOwnershipTransferConfirmPresented) {
            Button("소유권 이전", role: .destructive) {
                triggerReinstall(transferringOwnership: true)
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("다른 사용자가 설치한 시스템 도우미를 현재 사용자로 이전하고 재설치합니다.")
        }
        .alert("도우미 작업 실패", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Status Badge & Labels

    @ViewBuilder
    private var statusSymbol: some View {
        switch coordinator.state {
        case .checking, .installing:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 10, height: 10)
        case .running:
            Circle().fill(Tokens.statusGreen).frame(width: 7, height: 7)
        case .updateAvailable:
            Circle().fill(Tokens.accent).frame(width: 7, height: 7)
        case .ownershipMismatch:
            Circle().fill(Tokens.statusOrange).frame(width: 7, height: 7)
        case .notInstalled, .unavailable:
            Circle().fill(Tokens.statusRed).frame(width: 7, height: 7)
        }
    }

    private var statusLabel: some View {
        Text(statusText)
            .font(WattlyFont.at(11.5, weight: .regular))
            .foregroundStyle(t.faint)
    }

    private var statusText: String {
        switch coordinator.state {
        case .checking:
            String(localized: "확인 중…")
        case .installing:
            String(localized: "도우미 설치 중…")
        case .running:
            String(localized: "정상 작동 중")
        case .updateAvailable:
            String(localized: "업데이트 필요")
        case .notInstalled:
            String(localized: "미설치")
        case .unavailable:
            String(localized: "응답 없음")
        case .ownershipMismatch:
            String(localized: "다른 사용자 소유")
        }
    }

    private var infoButton: some View {
        Button {
            isDiagnosticsPopoverPresented = true
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(t.faint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey("도우미 진단 세부 정보 보기")))
        .popover(isPresented: $isDiagnosticsPopoverPresented, arrowEdge: .bottom) {
            diagnosticsPopover
        }
    }

    // MARK: - Action Button

    @ViewBuilder
    private var actionButton: some View {
        switch coordinator.state {
        case .installing, .checking:
            EmptyView()

        case .running:
            Button {
                isReinstallConfirmPresented = true
            } label: {
                Text("재설치…")
                    .font(WattlyFont.at(12, weight: .medium))
                    .foregroundStyle(t.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.segTrack))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.rowBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)

        case .updateAvailable:
            Button {
                triggerReinstall(transferringOwnership: false)
            } label: {
                Text("도우미 업데이트")
                    .font(WattlyFont.at(12, weight: .medium))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.accent))
            }
            .buttonStyle(.plain)

        case .notInstalled:
            Button {
                triggerReinstall(transferringOwnership: false)
            } label: {
                Text("도우미 설치")
                    .font(WattlyFont.at(12, weight: .medium))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.accent))
            }
            .buttonStyle(.plain)

        case .unavailable:
            Button {
                triggerReinstall(transferringOwnership: false)
            } label: {
                Text("도우미 복구")
                    .font(WattlyFont.at(12, weight: .medium))
                    .foregroundStyle(t.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.segTrack))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.rowBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)

        case .ownershipMismatch:
            Button {
                isOwnershipTransferConfirmPresented = true
            } label: {
                Text("소유권 가져오기")
                    .font(WattlyFont.at(12, weight: .medium))
                    .foregroundStyle(t.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.segTrack))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.rowBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Diagnostics Popover

    private var diagnosticsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("시스템 도우미 진단 정보")
                .font(WattlyFont.at(13, weight: .semibold))
                .foregroundStyle(t.text)

            VStack(alignment: .leading, spacing: 6) {
                diagnosticLine(label: "Mach 서비스", value: FanControlXPC.machService)
                diagnosticLine(label: "도우미 경로", value: FanControlXPC.daemonPath)
                diagnosticLine(
                    label: "LaunchDaemon 소유자",
                    value: ownershipDescription(coordinator.diagnostics.installedOwnership)
                )
                diagnosticLine(
                    label: "배터리 XPC 상태",
                    value: coordinator.diagnostics.batteryMode.rawValue
                )
                diagnosticLine(
                    label: "팬 XPC 상태",
                    value: hasFan ? coordinator.diagnostics.fanMode.rawValue : "미지원 (팬 없음)"
                )
                diagnosticLine(
                    label: "바이너리 일치",
                    value: binaryMatchDescription(coordinator.diagnostics.binaryMatch)
                )
            }
            .font(WattlyFont.at(11, weight: .regular))

            Divider()

            HStack {
                Text("확인 시각: \(formattedDate(coordinator.diagnostics.checkedAt))")
                    .font(WattlyFont.at(10, weight: .regular))
                    .foregroundStyle(t.faint)
                Spacer()
                Button {
                    Task { await coordinator.checkHealth() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.clockwise")
                        Text("새로고침")
                    }
                    .font(WattlyFont.at(10.5, weight: .medium))
                    .foregroundStyle(t.sub)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func diagnosticLine(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .foregroundStyle(t.faint)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .foregroundStyle(t.text)
                .textSelection(.enabled)
        }
    }

    private func ownershipDescription(_ ownership: FanHelperInstaller.InstalledOwnership) -> String {
        switch ownership {
        case .notInstalled: return "미설치"
        case .owner(let uid): return "UID \(uid) (현재: \(coordinator.diagnostics.currentUID))"
        case .invalidMetadata: return "메타데이터 오류"
        }
    }

    private func binaryMatchDescription(_ match: Bool?) -> String {
        switch match {
        case true: return "최신 바이너리와 일치"
        case false: return "업데이트 필요 (불일치)"
        case nil: return "확인 불가"
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.timeStyle = .medium
        df.dateStyle = .none
        return df.string(from: date)
    }

    private func triggerReinstall(transferringOwnership: Bool) {
        let window = NSApp.keyWindow
        Task {
            do {
                try await coordinator.reinstall(
                    transferringOwnership: transferringOwnership,
                    window: window,
                    reapplySettings: onReapplySettings
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
```

- [ ] **Step 2: Register `SettingsHelperRow.swift` in `Wattly.xcodeproj/project.pbxproj`**

Add PBXFileReference and PBXBuildFile for `SettingsHelperRow.swift` in the `Wattly` target Sources.

- [ ] **Step 3: Verify build succeeds**

Run:
```bash
xcodebuild -scheme Wattly -configuration Debug -derivedDataPath /tmp/WattlyDerivedData build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit Task 3**

```bash
git add Wattly/Views/Settings/SettingsHelperRow.swift Wattly.xcodeproj/project.pbxproj
git commit -m "feat: implement SettingsHelperRow UI component with diagnostics popover and alerts"
```

---

### Task 4: Integration into `SettingsView.swift` & Verification

**Files:**
- Modify: `Wattly/Views/SettingsView.swift:178-185`

**Interfaces:**
- Consumes:
  - `SettingsHelperRow`
  - `HelperHealthCoordinator(batteryControl:fanControl:)`
  - Current stored settings bindings for reapplying after reinstall

- [ ] **Step 1: Add `HelperHealthCoordinator` state and `SettingsHelperRow` to `SettingsView.swift`**

In `Wattly/Views/SettingsView.swift`:
1. Add `@State private var helperCoordinator: HelperHealthCoordinator` and fan settings properties:
```swift
    @State private var helperCoordinator: HelperHealthCoordinator
    @AppStorage(StorageKey.fanControlEnabled) private var fanControlEnabled = Defaults.fanControlEnabled
    @AppStorage(StorageKey.fanCurve) private var fanCurve = Defaults.fanCurve
```
2. In `init(monitor:fanControl:batteryControl:scheduleCoordinator:calibrationCoordinator:)`, initialize `_helperCoordinator`:
```swift
        self.calibrationCoordinator = calibrationCoordinator
        self._helperCoordinator = State(initialValue: HelperHealthCoordinator(
            batteryControl: batteryControl,
            fanControl: fanControl
        ))
```
3. In `generalGroup`, insert `SettingsHelperRow` right below the Software Update row:
```swift
                Rectangle().fill(t.line).frame(height: 1)

                // 시스템 도우미 (상태 진단 및 재설치)
                SettingsHelperRow(
                    coordinator: helperCoordinator,
                    hasFan: monitor.isPresent(.fan),
                    onReapplySettings: {
                        await reapplyAllSettingsAfterHelperReinstall()
                    }
                )
```
4. Implement `reapplyAllSettingsAfterHelperReinstall()` reading current battery configuration via `calibrationCoordinator.currentSnapshot()` and fan configuration:
```swift
    private func reapplyAllSettingsAfterHelperReinstall() async {
        let snapshot = calibrationCoordinator.currentSnapshot()
        let delta = snapshot.sailingEnabled ? snapshot.sailingDelta : 2
        let manualTarget = BatterySectionPresentation.clampedManualDischargeTarget(snapshot.manualDischargeTarget)

        await batteryControl.apply(
            enabled: snapshot.limitEnabled,
            limitPercentage: snapshot.limitPercentage,
            lowerHysteresisDelta: delta,
            heatProtectionEnabled: snapshot.heatProtectionEnabled,
            heatProtectionThresholdCelsius: snapshot.heatProtectionThresholdCelsius,
            autoDischargeEnabled: snapshot.autoDischargeEnabled,
            manualDischargeTarget: manualTarget
        )

        if fanControlEnabled {
            await fanControl.apply(enabled: true, curve: fanCurve)
        }
    }
```

- [ ] **Step 2: Run all unit tests**

Run:
```bash
xcodebuild -scheme Wattly -configuration Debug -derivedDataPath /tmp/WattlyDerivedData -only-testing:WattlyTests/HelperHealthStatusTests -only-testing:WattlyTests/HelperHealthCoordinatorTests -only-testing:WattlyTests/BatteryControlClientTests -only-testing:WattlyTests/FanControlClientTests test
```
Expected: All test suites PASS.

- [ ] **Step 3: Commit Task 4**

```bash
git add Wattly/Views/SettingsView.swift
git commit -m "feat: integrate helper health check and reinstall row into SettingsView General tab"
```

---

## Verification Plan

### Automated Tests
- Run complete test suite:
  ```bash
  xcodebuild -scheme Wattly -configuration Debug -derivedDataPath /tmp/WattlyDerivedData test
  ```
  Expected: All unit tests in `WattlyTests` pass.

### Manual Verification
1. Open Wattly, click menu bar icon -> Settings (설정) -> "일반" (General).
2. Verify "시스템 도우미" row is displayed below "소프트웨어 업데이트".
3. Check status badge:
   - When healthy: displays 🟢 "정상 작동 중" with "재설치…" button.
   - Click ⓘ icon: verify popover opens showing service name, daemon path, UID, XPC status, and refresh button.
4. Click "재설치…": verify confirmation alert appears.
5. Click "재설치" in alert: verify administrator authentication prompt is presented, settings window remains intact, and after authentication, existing battery and fan configurations are preserved.
6. Simulate missing helper (e.g. stopped daemon): verify status updates to 🔴 "응답 없음" and button switches to "도우미 복구".
