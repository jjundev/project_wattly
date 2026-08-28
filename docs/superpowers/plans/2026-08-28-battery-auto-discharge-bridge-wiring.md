# Battery Auto-Discharge Bridge Wiring Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `BatteryControlBridge` from silently reconciling the user's auto-discharge opt-in (`batteryAutoDischargeEnabled`) and manual-discharge target (`batteryManualDischargeTarget`) back to the daemon's `false` / `80` defaults once a minute, so a Mac at 100% with an 85% limit and auto-discharge ON actually reaches `CHIE=[08]` and stays there.

**Architecture:** The bug is one of omission, not of logic. `BatteryControlBridge` reads six of the eight battery `@AppStorage` values and builds a `BatteryControlConfiguration` from them; the two discharge-related keys are never read, so the struct's own defaults (`autoDischargeEnabled: false`, `manualDischargeTarget: 80`) travel to the daemon on every one of the bridge's five write paths. `BatteryControlPolicy.shouldReapply` preserves `topUpActive` and `manualDischargeActive` from the daemon because those are *transient activity*; `autoDischargeEnabled` is a *user setting* and gets no such preservation — correctly so, which is exactly why it must be wired from `@AppStorage`. The fix adds the two `@AppStorage` properties, extracts the configuration assembly into one **pure static builder** (`BatteryControlBridge.makeConfiguration`), and routes **every** call site — initial task, six `onChange` handlers, wake, and the 60-second reconcile loop — through that single builder. Making the builder the sole choke point is what lets one unit test guard all of them: today each call site re-lists arguments by hand, which is how two of them drifted.

**Tech Stack:** Swift 6 (strict concurrency complete), SwiftUI (`@AppStorage`, `.task(id:)`, `.onChange`), Swift Testing (`import Testing`), XcodeGen project, macOS 14.0 deploy target, Apple Silicon only.

## Global Constraints

- **Branch:** work on `claude/heuristic-mccarthy-7bbffc` in the worktree `.claude/worktrees/heuristic-mccarthy-7bbffc`. This work is **unrelated** to the battery-calibration-mode design on `claude/battery-calibration-mode-65e9d7` — do not merge, rebase onto, or cherry-pick from that branch.
- **Swift 6 language mode**, `MACOSX_DEPLOYMENT_TARGET` 14.0, `ARCHS: arm64`. Everything must compile clean under `-swift-version 6` strict concurrency.
- **No protocol / daemon / IPC changes.** `BatteryControlConfiguration`, `BatteryControlClient`, `BatteryControlPolicy`, and `BatteryControlEngine` are already correct and already carry `autoDischargeEnabled` / `manualDischargeTarget` end-to-end. **Only `Wattly/Views/BatteryControlBridge.swift` changes**, plus one new test file.
- **No behaviour change for the six already-wired keys** (`batteryLimitEnabled`, `batteryLimitPercentage`, `batterySailingEnabled`, `batterySailingDelta`, `batteryHeatProtectionEnabled`, `batteryHeatProtectionThreshold`). The builder refactor must be value-identical for them.
- **One new file** (`WattlyTests/BatteryControlBridgeTests.swift`) → **`xcodegen generate` is REQUIRED** before the first test run. Both targets use directory globs (`sources: - path: WattlyTests`), so a new file is invisible to the build until the project is regenerated.
- **Test baseline:** 1048 `@Test` declarations exist today (`grep -rn "@Test" WattlyTests | wc -l`). The suite must stay green; this plan adds 4.
- **Verified facts (read from the code on 2026-08-28 — do not re-derive):**
  - `Defaults.batteryAutoDischargeEnabled == false`, `Defaults.batteryManualDischargeTarget == 80` (`Wattly/Settings/Settings.swift:439-440`).
  - `StorageKey.batteryAutoDischargeEnabled == "batteryAutoDischargeEnabled"`, `StorageKey.batteryManualDischargeTarget == "batteryManualDischargeTarget"` (`Wattly/Settings/Settings.swift:483-484`).
  - `BatteryControlConfiguration.init` declares its parameters in the order `enabled, limitPercentage, lowerHysteresisDelta, heatProtectionEnabled, heatProtectionThresholdCelsius, heatProtectionResumeDeltaCelsius, heatProtectionMinCooldownSeconds, topUpActive, autoDischargeEnabled, manualDischargeActive, manualDischargeTarget` (`FanControlShared/BatteryControlProtocol.swift:15-27`). Swift requires call-site labels in declaration order; the builder below skips defaults but preserves order.
  - `BatteryControlConfiguration.normalized` clamps `manualDischargeTarget` through `clampLimit` (range **50…100**), so `70` survives unclamped.
  - `BatteryControlBridge.wakeAction` is already a `static func` called from a **non-`@MainActor`** test (`WattlyTests/BatteryControlClientTests.swift:164`). Static members of this `View` struct are therefore callable from nonisolated tests — the new builder follows the same shape.
  - `BatteryControlEngine` gates auto-discharge on `config.enabled && config.autoDischargeEnabled && …` (`FanControlShared/BatteryControlEngine.swift:296`), so auto-discharge without the charge limit is intentionally inert — the disable path still carries the flag so the daemon persists the preference.
  - `BatteryControlClient.reconcile` keeps the caller's `manualDischargeTarget` whenever manual discharge is **not** active (`Wattly/Control/BatteryControlClient.swift:275-281`) — so passing the stored 70 is sufficient to stop the drift to 80.

## File Structure

| File | Change | Responsibility after this plan |
| --- | --- | --- |
| `Wattly/Views/BatteryControlBridge.swift` | Modify | Owns **all eight** battery `@AppStorage` reads, exposes one pure static builder that turns them into a `BatteryControlConfiguration`, and drives every daemon write (initial, onChange ×7, wake, 60 s reconcile) from that one value. |
| `WattlyTests/BatteryControlBridgeTests.swift` | Create | Guards the builder: every stored preference reaches the configuration, and the resulting configuration makes `BatteryControlPolicy.shouldReapply` agree with a daemon that has auto-discharge on. Plus a client-level regression test that `reconcile` forwards both discharge fields. |

No other file is touched. `SettingsBatterySection.swift` already wires both keys correctly and stays as-is.

---

### Task 1: Pure configuration builder + the two missing `@AppStorage` reads

**Files:**
- Modify: `Wattly/Views/BatteryControlBridge.swift:15-35`
- Create: `WattlyTests/BatteryControlBridgeTests.swift`

**Interfaces:**
- Consumes: `BatteryControlConfiguration` (`FanControlShared/BatteryControlProtocol.swift`), `StorageKey` / `Defaults` (`Wattly/Settings/Settings.swift`).
- Produces, both used by Task 2 and by the tests:
  - `static func BatteryControlBridge.effectiveDelta(sailingEnabled: Bool, sailingDelta: Int) -> Int`
  - `static func BatteryControlBridge.makeConfiguration(enabled: Bool, limitPercentage: Int, sailingEnabled: Bool, sailingDelta: Int, heatProtectionEnabled: Bool, heatProtectionThresholdCelsius: Int, autoDischargeEnabled: Bool, manualDischargeTarget: Int) -> BatteryControlConfiguration`

- [ ] **Step 1: Write the failing test file**

Create `WattlyTests/BatteryControlBridgeTests.swift` with exactly this content:

```swift
import Testing
import Foundation
@testable import Wattly

@Suite struct BatteryControlBridgeTests {

    // MARK: - 순수 설정 빌더

    /// The bug this file exists for: the bridge never read `batteryAutoDischargeEnabled` or
    /// `batteryManualDischargeTarget`, so `BatteryControlConfiguration`'s own defaults (false / 80)
    /// reached the daemon on every reconcile and switched auto-discharge back off once a minute.
    @Test func configurationCarriesEveryStoredPreference() {
        let config = BatteryControlBridge.makeConfiguration(
            enabled: true,
            limitPercentage: 85,
            sailingEnabled: true,
            sailingDelta: 5,
            heatProtectionEnabled: true,
            heatProtectionThresholdCelsius: 38,
            autoDischargeEnabled: true,
            manualDischargeTarget: 70)

        #expect(config.enabled == true)
        #expect(config.limitPercentage == 85)
        #expect(config.lowerHysteresisDelta == 5)
        #expect(config.heatProtectionEnabled == true)
        #expect(config.heatProtectionThresholdCelsius == 38)
        #expect(config.autoDischargeEnabled == true)
        #expect(config.manualDischargeTarget == 70)
        // Transient daemon-side activity is never asserted by the bridge; `shouldReapply`
        // preserves it from the helper's own status instead.
        #expect(config.topUpActive == false)
        #expect(config.manualDischargeActive == false)
    }

    /// Sailing off means the fixed 2-point hysteresis, regardless of the stored delta.
    @Test func sailingOffUsesTheFixedTwoPointDelta() {
        #expect(BatteryControlBridge.effectiveDelta(sailingEnabled: false, sailingDelta: 5) == 2)
        #expect(BatteryControlBridge.effectiveDelta(sailingEnabled: true, sailingDelta: 5) == 5)

        let config = BatteryControlBridge.makeConfiguration(
            enabled: true,
            limitPercentage: 80,
            sailingEnabled: false,
            sailingDelta: 5,
            heatProtectionEnabled: false,
            heatProtectionThresholdCelsius: 35,
            autoDischargeEnabled: false,
            manualDischargeTarget: 80)
        #expect(config.lowerHysteresisDelta == 2)
    }

    /// The stored defaults the bridge starts from, pinned so a Defaults edit cannot quietly
    /// re-create the original symptom.
    @Test func bridgeDischargeDefaultsMatchStoredDefaults() {
        #expect(Defaults.batteryAutoDischargeEnabled == false)
        #expect(Defaults.batteryManualDischargeTarget == 80)
        #expect(StorageKey.batteryAutoDischargeEnabled == "batteryAutoDischargeEnabled")
        #expect(StorageKey.batteryManualDischargeTarget == "batteryManualDischargeTarget")
    }
}
```

- [ ] **Step 2: Regenerate the project so the new test file is compiled**

The `WattlyTests` target globs the directory, so a new file is invisible until the project is regenerated.

```bash
xcodegen generate
```

Expected: `Loaded project ... Created project at Wattly.xcodeproj` and no error.

- [ ] **Step 3: Run the new suite to verify it fails**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlBridgeTests test 2>&1 | tail -30
```

Expected: **BUILD FAILED** with `type 'BatteryControlBridge' has no member 'makeConfiguration'` (and the same for `effectiveDelta`). A compile failure is the red state here — Swift cannot run a test that names a symbol that does not exist.

- [ ] **Step 4: Add the two `@AppStorage` reads and the pure builder**

In `Wattly/Views/BatteryControlBridge.swift`, add the two stored properties immediately after the `heatProtectionThreshold` line (currently line 20):

```swift
    @AppStorage(StorageKey.batteryHeatProtectionThreshold) private var heatProtectionThreshold = Defaults.batteryHeatProtectionThreshold
    @AppStorage(StorageKey.batteryAutoDischargeEnabled) private var autoDischargeEnabled = Defaults.batteryAutoDischargeEnabled
    @AppStorage(StorageKey.batteryManualDischargeTarget) private var manualDischargeTarget = Defaults.batteryManualDischargeTarget
```

Then replace the whole existing block (currently lines 24-35):

```swift
    private var effectiveDelta: Int {
        sailingEnabled ? sailingDelta : 2
    }

    private var configuration: BatteryControlConfiguration {
        BatteryControlConfiguration(
            enabled: enabled,
            limitPercentage: limit,
            lowerHysteresisDelta: effectiveDelta,
            heatProtectionEnabled: heatProtectionEnabled,
            heatProtectionThresholdCelsius: heatProtectionThreshold)
    }
```

with:

```swift
    /// Sailing off means the fixed 2-point hysteresis the daemon assumes by default.
    static func effectiveDelta(sailingEnabled: Bool, sailingDelta: Int) -> Int {
        sailingEnabled ? sailingDelta : 2
    }

    /// Every stored battery preference this bridge is responsible for, assembled in exactly one
    /// place. Pure, so a unit test can prove no `@AppStorage` value is dropped on the way to the
    /// daemon — the omission that had this always-alive bridge reconciling the user's
    /// auto-discharge opt-in back off once a minute. `topUpActive` and `manualDischargeActive` are
    /// deliberately absent: they are transient daemon activity, and `BatteryControlPolicy`
    /// preserves them from the helper's own status rather than from preferences.
    static func makeConfiguration(
        enabled: Bool,
        limitPercentage: Int,
        sailingEnabled: Bool,
        sailingDelta: Int,
        heatProtectionEnabled: Bool,
        heatProtectionThresholdCelsius: Int,
        autoDischargeEnabled: Bool,
        manualDischargeTarget: Int
    ) -> BatteryControlConfiguration {
        BatteryControlConfiguration(
            enabled: enabled,
            limitPercentage: limitPercentage,
            lowerHysteresisDelta: effectiveDelta(
                sailingEnabled: sailingEnabled, sailingDelta: sailingDelta),
            heatProtectionEnabled: heatProtectionEnabled,
            heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
            autoDischargeEnabled: autoDischargeEnabled,
            manualDischargeTarget: manualDischargeTarget)
    }

    private var configuration: BatteryControlConfiguration {
        Self.makeConfiguration(
            enabled: enabled,
            limitPercentage: limit,
            sailingEnabled: sailingEnabled,
            sailingDelta: sailingDelta,
            heatProtectionEnabled: heatProtectionEnabled,
            heatProtectionThresholdCelsius: heatProtectionThreshold,
            autoDischargeEnabled: autoDischargeEnabled,
            manualDischargeTarget: manualDischargeTarget)
    }

    private var effectiveDelta: Int {
        Self.effectiveDelta(sailingEnabled: sailingEnabled, sailingDelta: sailingDelta)
    }
```

Note: the instance `effectiveDelta` property is kept **only** so the untouched call sites still compile at the end of this task; Task 2 removes it once nothing references it.

- [ ] **Step 5: Run the new suite to verify it passes**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlBridgeTests test 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **` with 3 tests passing.

- [ ] **Step 6: Commit**

```bash
git add Wattly/Views/BatteryControlBridge.swift WattlyTests/BatteryControlBridgeTests.swift Wattly.xcodeproj
git commit -m "fix(battery): read auto-discharge and manual target in the control bridge"
```

---

### Task 2: Route every daemon write through the builder, and react to the toggle

**Files:**
- Modify: `Wattly/Views/BatteryControlBridge.swift:52-207` (body handlers, `handleInitialTask`, `handleConfigChange`, `handleWake`, `handleReconcileLoop`)
- Test: `WattlyTests/BatteryControlBridgeTests.swift` (append to the existing `@Suite`)

**Interfaces:**
- Consumes from Task 1: `BatteryControlBridge.makeConfiguration(...)`, `BatteryControlBridge.effectiveDelta(...)`.
- Consumes (unchanged, already present): `BatteryControlClient.apply(enabled:limitPercentage:lowerHysteresisDelta:heatProtectionEnabled:heatProtectionThresholdCelsius:topUpActive:autoDischargeEnabled:manualDischargeActive:manualDischargeTarget:)`, `BatteryControlClient.reconcile(enabled:limitPercentage:lowerHysteresisDelta:heatProtectionEnabled:heatProtectionThresholdCelsius:autoDischargeEnabled:manualDischargeActive:manualDischargeTarget:)`, `BatteryControlClient.disableAndConfirm(limitPercentage:lowerHysteresisDelta:autoDischargeEnabled:manualDischargeTarget:)`, `BatteryControlPolicy.shouldReapply(configuration:status:)`.
- Produces: `private func handleConfigChange(_ requested: BatteryControlConfiguration) async` — the old five-parameter signature is replaced.

**Why the `.task(id:)` string must also change (do not skip this):** `.task(id:)` restarts only when the id changes. `handleReconcileLoop` reads `self`, and the `self` it captured is the view value from the body evaluation that *started* the task. If the id does not mention `autoDischargeEnabled` / `manualDischargeTarget`, the loop keeps reconciling with the stale pre-change values forever. That is exactly why the six already-wired keys are in the id today.

- [ ] **Step 1: Write the failing tests**

Append these two tests inside the existing `BatteryControlBridgeTests` suite in `WattlyTests/BatteryControlBridgeTests.swift`, just before the closing `}`:

```swift
    // MARK: - 데몬 왕복 회귀

    /// The mechanism of the reported bug, pinned. A daemon that holds auto-discharge ON and a
    /// bridge configuration that says OFF is a mismatch `shouldReapply` acts on — it re-pushes,
    /// and auto-discharge dies. With the preference wired, the two agree and nothing is re-pushed.
    @Test func autoDischargeMismatchIsWhatTriggeredTheReapply() {
        let daemonConfig = BatteryControlConfiguration(
            enabled: true,
            limitPercentage: 85,
            lowerHysteresisDelta: 2,
            autoDischargeEnabled: true)
        let status = BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 100,
            isPowerAdapterConnected: true,
            detail: "충전 제한 85% 도달",
            updatedAt: 100.0,
            desiredConfiguration: daemonConfig,
            capabilities: [.persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1])

        let unwired = BatteryControlBridge.makeConfiguration(
            enabled: true, limitPercentage: 85,
            sailingEnabled: false, sailingDelta: 5,
            heatProtectionEnabled: false, heatProtectionThresholdCelsius: 35,
            autoDischargeEnabled: false, manualDischargeTarget: 80)
        #expect(BatteryControlPolicy.shouldReapply(configuration: unwired, status: status) == true)

        let wired = BatteryControlBridge.makeConfiguration(
            enabled: true, limitPercentage: 85,
            sailingEnabled: false, sailingDelta: 5,
            heatProtectionEnabled: false, heatProtectionThresholdCelsius: 35,
            autoDischargeEnabled: true, manualDischargeTarget: 80)
        #expect(BatteryControlPolicy.shouldReapply(configuration: wired, status: status) == false)
    }

    /// The second half of the same omission: while no discharge is running, `reconcile` keeps the
    /// caller's target, so the bridge passing the stored 70 is what stops the daemon's setting
    /// from drifting back to 80.
    @MainActor @Test func reconcileForwardsBothDischargePreferences() async throws {
        let receiver = BridgeRequestReceiver()
        let daemonConfig = BatteryControlConfiguration(
            enabled: true,
            limitPercentage: 85,
            lowerHysteresisDelta: 2,
            autoDischargeEnabled: false,
            manualDischargeActive: false,
            manualDischargeTarget: 80)
        let status = BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 100,
            isPowerAdapterConnected: true,
            detail: "충전 제한 85% 도달",
            updatedAt: 100.0,
            desiredConfiguration: daemonConfig,
            capabilities: [.persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1])
        let client = BatteryControlClient(requestHandler: { request in
            await receiver.set(request)
            return (try? BatteryControlCodec.encode(status), nil)
        })

        await client.reconcile(
            enabled: true,
            limitPercentage: 85,
            lowerHysteresisDelta: 2,
            heatProtectionEnabled: false,
            heatProtectionThresholdCelsius: 35,
            autoDischargeEnabled: true,
            manualDischargeTarget: 70)

        guard case .configure(let data) = await receiver.request else {
            Issue.record("Expected configure request")
            return
        }
        let sent = try BatteryControlCodec.decode(
            BatteryControlConfigurationRequest.self, from: data)
        #expect(sent.configuration.autoDischargeEnabled == true)
        #expect(sent.configuration.manualDischargeTarget == 70)
    }
```

And add this helper actor at file scope, immediately after the `@testable import Wattly` line and before `@Suite struct BatteryControlBridgeTests {`:

```swift
private actor BridgeRequestReceiver {
    var request: BatteryControlClient.BatteryControlClientRequest?
    func set(_ request: BatteryControlClient.BatteryControlClientRequest) {
        self.request = request
    }
}
```

(`BatteryControlClientTests.swift` declares its own `private actor RequestReceiver`; top-level `private` is file-scoped, but a distinct name keeps the two unambiguous when reading either file.)

- [ ] **Step 2: Run the tests to verify they pass already, then confirm the wiring is still missing**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlBridgeTests test 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 5 tests. These two tests describe the daemon contract, which is already correct — they are the *pin*, not the red state. The remaining red state is structural and is checked in Step 4: no call site is required to go through the builder yet.

- [ ] **Step 3: Route every call site through the builder**

In `Wattly/Views/BatteryControlBridge.swift`, replace the entire `var body` (currently lines 52-128) with:

```swift
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task {
                await handleInitialTask()
            }
            .onChange(of: enabled) { _, val in
                syncMonitorTarget()
                let requested = Self.makeConfiguration(
                    enabled: val,
                    limitPercentage: limit,
                    sailingEnabled: sailingEnabled,
                    sailingDelta: sailingDelta,
                    heatProtectionEnabled: heatProtectionEnabled,
                    heatProtectionThresholdCelsius: heatProtectionThreshold,
                    autoDischargeEnabled: autoDischargeEnabled,
                    manualDischargeTarget: manualDischargeTarget)
                Task {
                    await handleConfigChange(requested)
                }
            }
            .onChange(of: limit) { _, val in
                syncMonitorTarget()
                let requested = Self.makeConfiguration(
                    enabled: enabled,
                    limitPercentage: val,
                    sailingEnabled: sailingEnabled,
                    sailingDelta: sailingDelta,
                    heatProtectionEnabled: heatProtectionEnabled,
                    heatProtectionThresholdCelsius: heatProtectionThreshold,
                    autoDischargeEnabled: autoDischargeEnabled,
                    manualDischargeTarget: manualDischargeTarget)
                Task {
                    await handleConfigChange(requested)
                }
            }
            .onChange(of: sailingEnabled) { _, isSailing in
                let requested = Self.makeConfiguration(
                    enabled: enabled,
                    limitPercentage: limit,
                    sailingEnabled: isSailing,
                    sailingDelta: sailingDelta,
                    heatProtectionEnabled: heatProtectionEnabled,
                    heatProtectionThresholdCelsius: heatProtectionThreshold,
                    autoDischargeEnabled: autoDischargeEnabled,
                    manualDischargeTarget: manualDischargeTarget)
                Task {
                    await handleConfigChange(requested)
                }
            }
            .onChange(of: sailingDelta) { _, newDelta in
                guard sailingEnabled else { return }
                let requested = Self.makeConfiguration(
                    enabled: enabled,
                    limitPercentage: limit,
                    sailingEnabled: true,
                    sailingDelta: newDelta,
                    heatProtectionEnabled: heatProtectionEnabled,
                    heatProtectionThresholdCelsius: heatProtectionThreshold,
                    autoDischargeEnabled: autoDischargeEnabled,
                    manualDischargeTarget: manualDischargeTarget)
                Task {
                    await handleConfigChange(requested)
                }
            }
            .onChange(of: heatProtectionEnabled) { _, isHeatEnabled in
                let requested = Self.makeConfiguration(
                    enabled: enabled,
                    limitPercentage: limit,
                    sailingEnabled: sailingEnabled,
                    sailingDelta: sailingDelta,
                    heatProtectionEnabled: isHeatEnabled,
                    heatProtectionThresholdCelsius: heatProtectionThreshold,
                    autoDischargeEnabled: autoDischargeEnabled,
                    manualDischargeTarget: manualDischargeTarget)
                Task {
                    await handleConfigChange(requested)
                }
            }
            .onChange(of: heatProtectionThreshold) { _, threshold in
                let requested = Self.makeConfiguration(
                    enabled: enabled,
                    limitPercentage: limit,
                    sailingEnabled: sailingEnabled,
                    sailingDelta: sailingDelta,
                    heatProtectionEnabled: heatProtectionEnabled,
                    heatProtectionThresholdCelsius: threshold,
                    autoDischargeEnabled: autoDischargeEnabled,
                    manualDischargeTarget: manualDischargeTarget)
                Task {
                    await handleConfigChange(requested)
                }
            }
            // Auto-discharge is a user setting, not transient activity, so nothing in
            // `BatteryControlPolicy` preserves it for us — flipping it has to push. `reconcile`
            // rather than `apply`: it reads the helper first, so it keeps a running Top Up or
            // manual discharge intact and writes nothing at all when the settings screen already
            // pushed the same change a moment ago.
            .onChange(of: autoDischargeEnabled) { _, isAutoDischarge in
                Task {
                    await client.reconcile(
                        enabled: enabled,
                        limitPercentage: limit,
                        lowerHysteresisDelta: Self.effectiveDelta(
                            sailingEnabled: sailingEnabled, sailingDelta: sailingDelta),
                        heatProtectionEnabled: heatProtectionEnabled,
                        heatProtectionThresholdCelsius: heatProtectionThreshold,
                        autoDischargeEnabled: isAutoDischarge,
                        manualDischargeTarget: manualDischargeTarget)
                }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                Task {
                    await handleWake()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in
                Task {
                    if let scheduleCoordinator {
                        await scheduleCoordinator.evaluateSchedules(at: Date(), isWake: false)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                Task {
                    if let scheduleCoordinator {
                        await scheduleCoordinator.evaluateSchedules(at: Date(), isWake: false)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                Task {
                    if let scheduleCoordinator {
                        await scheduleCoordinator.evaluateSchedules(at: Date(), isWake: false)
                    }
                }
            }
            // The loop body reads the `self` captured when the task started, so every preference
            // it forwards must appear here — otherwise it reconciles stale values forever.
            .task(id: "\(enabled)-\(limit)-\(sailingEnabled)-\(sailingDelta)-\(heatProtectionEnabled)-\(heatProtectionThreshold)-\(autoDischargeEnabled)-\(manualDischargeTarget)") {
                await handleReconcileLoop()
            }
            .onChange(of: client.status) { _, newStatus in
                syncMonitorTarget()
                if topUpDetector.update(reasonKind: newStatus.detailReason?.kind) {
                    BatteryNotificationManager.postTopUpCompleteNotification()
                }
            }
    }
```

Then replace the four private methods (currently lines 130-206) with:

```swift
    private func handleInitialTask() async {
        syncMonitorTarget()
        await client.refreshStatus()
        syncMonitorTarget()
        let requested = configuration
        guard BatteryControlPolicy.shouldReapply(
            configuration: requested, status: client.status) else { return }
        await push(requested)
    }

    private func handleConfigChange(_ requested: BatteryControlConfiguration) async {
        await push(requested)
    }

    private func handleWake() async {
        let requested = configuration
        switch Self.wakeAction(configuration: requested, status: client.status) {
        case .refreshStatus:
            await client.refreshStatus()
        case .apply:
            await applyRequested(requested)
        case .disableAndConfirm:
            await disableRequested(requested)
        }
        if let scheduleCoordinator {
            await scheduleCoordinator.evaluateSchedules(at: Date(), isWake: true)
        }
    }

    private func handleReconcileLoop() async {
        var consecutiveUnsupported = 0
        while !Task.isCancelled {
            try? await Task.sleep(
                for: .seconds(BatteryControlPolicy.reconcileInterval(
                    consecutiveUnsupported: consecutiveUnsupported))
            )
            guard !Task.isCancelled else { return }
            let requested = configuration
            await client.reconcile(
                enabled: requested.enabled,
                limitPercentage: requested.limitPercentage,
                lowerHysteresisDelta: requested.lowerHysteresisDelta,
                heatProtectionEnabled: requested.heatProtectionEnabled,
                heatProtectionThresholdCelsius: requested.heatProtectionThresholdCelsius,
                autoDischargeEnabled: requested.autoDischargeEnabled,
                manualDischargeTarget: requested.manualDischargeTarget)
            consecutiveUnsupported = client.status.mode == .unsupported
                ? consecutiveUnsupported + 1
                : 0
            if client.status.isHardwareSupported == false { return }
        }
    }

    /// The one place a bridge-built configuration turns into a daemon write. An inactive policy
    /// still carries the discharge preferences: the helper persists them, so the user's target
    /// survives the limit being switched off and back on.
    private func push(_ requested: BatteryControlConfiguration) async {
        if requested.enabled || requested.heatProtectionEnabled {
            await applyRequested(requested)
        } else {
            await disableRequested(requested)
        }
    }

    private func applyRequested(_ requested: BatteryControlConfiguration) async {
        await client.apply(
            enabled: requested.enabled,
            limitPercentage: requested.limitPercentage,
            lowerHysteresisDelta: requested.lowerHysteresisDelta,
            heatProtectionEnabled: requested.heatProtectionEnabled,
            heatProtectionThresholdCelsius: requested.heatProtectionThresholdCelsius,
            autoDischargeEnabled: requested.autoDischargeEnabled,
            manualDischargeTarget: requested.manualDischargeTarget)
    }

    private func disableRequested(_ requested: BatteryControlConfiguration) async {
        _ = await client.disableAndConfirm(
            limitPercentage: requested.limitPercentage,
            lowerHysteresisDelta: requested.lowerHysteresisDelta,
            autoDischargeEnabled: requested.autoDischargeEnabled,
            manualDischargeTarget: requested.manualDischargeTarget)
    }
```

Note two deliberate behaviour points:
- `handleInitialTask` previously branched on `requested.isActive` while `handleConfigChange` branched on `enabled || heatEnabled`. `isActive` is `enabled || heatProtectionEnabled || topUpActive || manualDischargeActive`, and the bridge never sets the last two, so the two conditions are identical for bridge-built configurations. Collapsing them into `push` is value-identical.
- `manualDischargeTarget` gets **no** `.onChange` here on purpose: `SettingsBatterySection` already pushes it (`Wattly/Views/Settings/SettingsBatterySection.swift:412-429`), and any change made elsewhere restarts the `.task(id:)` loop, so the new target reaches the daemon within one reconcile interval. Adding a second immediate pusher would only double the XPC write.

- [ ] **Step 4: Delete the now-unused instance `effectiveDelta`**

Nothing references the instance property any more (every call site now goes through `makeConfiguration` or the static `effectiveDelta`). Remove this block from `Wattly/Views/BatteryControlBridge.swift`:

```swift
    private var effectiveDelta: Int {
        Self.effectiveDelta(sailingEnabled: sailingEnabled, sailingDelta: sailingDelta)
    }
```

Then confirm it is really gone and nothing still calls it:

```bash
grep -n "effectiveDelta" Wattly/Views/BatteryControlBridge.swift
```

Expected: exactly **three** matching lines — the `static func effectiveDelta(` declaration, the call inside `makeConfiguration`, and the call in the `.onChange(of: autoDischargeEnabled)` handler. Crucially, **no** `private var effectiveDelta` line.

- [ ] **Step 5: Verify every write path now carries the preferences**

```bash
grep -n "client.apply\|client.reconcile\|client.disableAndConfirm" Wattly/Views/BatteryControlBridge.swift
```

This lists every daemon write in the file. The rule to check by eye — not a count, which is fragile to reformatting — is: **every one of these calls passes both `autoDischargeEnabled:` and `manualDischargeTarget:`**. Zero exceptions. (After Step 3 there are four such calls: `client.reconcile` in the `.onChange(of: autoDischargeEnabled)` handler, `client.reconcile` in `handleReconcileLoop`, `client.apply` in `applyRequested`, and `client.disableAndConfirm` in `disableRequested`.)

- [ ] **Step 6: Run the full suite**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`. No pre-existing test may regress — `SettingsBatterySectionTests.integrationComponentsAcceptScheduleCoordinator` and `BatteryControlClientTests.legacyWakeWithDisabledConfigurationUsesVerifiedDisable` both touch `BatteryControlBridge` and must still pass.

- [ ] **Step 7: Commit**

```bash
git add Wattly/Views/BatteryControlBridge.swift WattlyTests/BatteryControlBridgeTests.swift
git commit -m "fix(battery): push auto-discharge and manual target on every bridge write path"
```

---

### Task 3: On-device verification against the SMC registers

**Files:**
- Read-only: `scripts/probe-charge-registers.swift`
- No source changes. This task either confirms the fix on the reporting Mac (Mac17,2 / macOS 26.6.2 / firmware 18000.161.10) or produces the evidence needed to reopen.

**Interfaces:**
- Consumes: the built app from Task 2 and the installed privileged helper.
- Produces: a pass/fail observation on `CHIE`, recorded in the final report.

- [ ] **Step 1: Build and launch the app under test**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. Then quit any running Wattly and launch the freshly built bundle:

```bash
open "$(xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')/Wattly.app"
```

- [ ] **Step 2: Record the pre-change register state**

```bash
swift scripts/probe-charge-registers.swift
```

Expected (the reported symptom, if it has not been cleared by other work): `CHTE=[01 00 00 00]`, `CHIE=[00]`. This is a read-only probe — it writes nothing.

- [ ] **Step 3: Set up the trigger condition in the app**

In Wattly's Settings → 배터리 충전 제어:
1. Set the charge limit **below** the current battery level (e.g. limit 85% at 100% charge).
2. Ensure 충전 제한 is ON and the power adapter is connected.
3. Turn 자동 방전 ON (or off-then-on if it is already on, so the new `.onChange` fires).

- [ ] **Step 4: Confirm auto-discharge engages immediately**

```bash
swift scripts/probe-charge-registers.swift
```

Expected: `CHIE=[08]` — forced discharge armed. Before this fix the toggle produced this only from the settings screen's own handler, and never from the bridge.

- [ ] **Step 5: Confirm the 60-second reconcile no longer undoes it**

Wait at least 90 seconds (more than one `BatteryControlPolicy.reconcileInterval` of 60 s) with the Settings window **closed**, so only the bridge's loop is running, then probe again:

```bash
swift scripts/probe-charge-registers.swift
```

Expected: `CHIE=[08]` still. This is the actual regression gate — the old bridge reset it to `[00]` on the first reconcile after the settings window stopped re-pushing.

- [ ] **Step 6: Confirm the manual-discharge target no longer drifts**

Set 수동 방전 목표 to **70%** in Settings while no discharge is running, close Settings, wait 90 seconds, then reopen Settings and read the target back.

Expected: still **70%**, not 80%.

- [ ] **Step 7: Report**

If Steps 4-6 all pass, the fix is confirmed on device. If any step fails, do **not** patch further without re-diagnosing: capture the probe output, `log show --predicate 'subsystem CONTAINS "Wattly"' --last 5m`, and the daemon's `desiredConfiguration` from the Settings status row, and report those rather than guessing.

- [ ] **Step 8: Commit any notes**

No code changes expected in this task. If the verification produced a doc-worthy finding, record it and commit:

```bash
git add -A
git commit -m "docs(battery): record on-device auto-discharge verification"
```

---

## Self-Review

**Spec coverage:**
| Spec item | Task |
| --- | --- |
| Add `@AppStorage(StorageKey.batteryAutoDischargeEnabled)` and `@AppStorage(StorageKey.batteryManualDischargeTarget)` | Task 1, Step 4 |
| Include both in the `configuration` computed property | Task 1, Step 4 |
| Pass both to `reconcile(...)` | Task 2, Step 3 (`handleReconcileLoop`) |
| Pass both to `handleConfigChange` | Task 2, Step 3 (`handleConfigChange` → `push`) |
| Pass both on the wake `apply(...)` path | Task 2, Step 3 (`handleWake` → `applyRequested` / `disableRequested`) |
| `.onChange` for `autoDischargeEnabled` | Task 2, Step 3 |
| `xcodegen generate` + full `xcodebuild … test` green | Task 1 Step 2, Task 2 Step 6 |
| Regression test via a pure configuration builder | Task 1 (builder + 3 tests), Task 2 (2 more tests) |
| On-device `CHIE=[08]` check with `probe-charge-registers.swift` | Task 3 |
| Separate branch from `claude/battery-calibration-mode-65e9d7` | Global Constraints |

**Additional item found while reading the code, not in the original spec but required for the fix to hold:** the `.task(id:)` string must include the two new keys, or the reconcile loop keeps running against the stale captured `self`. Covered in Task 2, Step 3, with the reasoning stated inline.

**Placeholder scan:** none — every step carries the literal code or command.

**Type consistency:** `makeConfiguration` / `effectiveDelta` signatures are identical in the Task 1 interface block, the Task 1 implementation, the Task 1 tests, and every Task 2 call site. `push` / `applyRequested` / `disableRequested` are introduced and used only within Task 2. `BridgeRequestReceiver` is declared and used only in the Task 2 test block.
