# Battery Auto-Discharge Daemon Round-Trip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the app's auto-discharge opt-in actually reach the daemon on the reporting Mac, and make the app's daemon round-trip observable so the next failure of this kind is diagnosable from a log instead of by inference.

**Architecture:** The previous branch (`031f983`…`531e72d`) fixed every place the app *builds* a `BatteryControlConfiguration` — those were real defects and are covered by 1057 green tests. On-device verification then failed anyway: with the app holding `batteryAutoDischargeEnabled = true` and the daemon persisting `autoDischargeEnabled: false`, **no write reached the daemon for over six minutes** even though the bridge reconciles every 60 s. That silence is the bug this plan targets. It has two halves. First, a design error introduced by the previous branch: the bridge's auto-discharge `onChange` calls `reconcile`, which is gated by `BatteryControlPolicy.shouldReapply` — so a toggle the user just pressed can be silently swallowed. An explicit user action must be an unconditional push. Second, an unexplained gap: nothing in the current code accounts for the 60 s loop producing no write when `shouldReapply` should return `true`. Rather than guess a third time, this plan introduces the codebase's first logging so the loop's behaviour is observable, and only then re-verifies on device.

**Tech Stack:** Swift 6 (strict concurrency complete), SwiftUI, OSLog (`Logger`), Swift Testing (`import Testing`), XcodeGen project, macOS 14.0 deploy target, Apple Silicon only.

## Global Constraints

- **Branch:** continue on `claude/heuristic-mccarthy-7bbffc` in the worktree `.claude/worktrees/heuristic-mccarthy-7bbffc`, on top of `531e72d`. Unrelated to `claude/battery-calibration-mode-65e9d7` — do not merge, rebase onto, or cherry-pick from it.
- **Swift 6 language mode**, `MACOSX_DEPLOYMENT_TARGET` 14.0, `ARCHS: arm64`. Must compile clean under `-swift-version 6` strict concurrency.
- **Do not change the daemon's engine or policy semantics.** `FanControlShared/BatteryControlEngine.swift`, `FanControlShared/BatteryControlCoordinator.swift`, and `FanControlShared/BatteryControlPolicy.swift` are out of scope for behaviour changes. The installed privileged helper on the test machine is a 2026-08-26 build and will not be rebuilt by this plan; every fix must work against it as-is.
- **Logging is permanent, minimal, and non-PII.** Subsystem `dev.jjundev.Wattly`, category `battery-control`. Log configuration fields and policy verdicts only — never file paths, user identifiers, or serial numbers. This is the codebase's first use of OSLog (`grep -rl OSLog` over `Wattly`, `FanControlShared`, `WattlyFanDaemon` returns 0 files); introduce it in one small file rather than scattering `Logger(...)` literals.
- **OSLog interpolation is not string interpolation, and its default privacy is type-based.** `Bool` and numeric interpolations default to `.public` and print normally; **`String`-typed interpolations default to `.private` and are redacted to `<private>` by `log show`.** Anything wrapped in `String(describing:)` or produced by `joined(separator:)` is a `String` and therefore redacted unless it carries an explicit `privacy: .public`. Every such field in this plan is a configuration value or a policy verdict — exactly what the rule above permits logging — so each one is marked `privacy: .public` deliberately. **Do not drop those annotations**: without them the code still compiles, the log still appears, and every field the diagnosis depends on reads `<private>`, which is precisely the failure mode this plan exists to avoid.
- **One new source file** (`Wattly/Core/BatteryControlLog.swift`) → **`xcodegen generate` is REQUIRED** in Task 1. Both targets glob their source directories, so a new file is invisible to the build until the project is regenerated.
- **Test baseline:** `grep -rn "@Test" WattlyTests | wc -l` is **1057** at `531e72d`, and the full suite is green there. It must stay green; this plan adds 4.
- **Running the full suite regenerates `docs/assets/**` PNG/GIF snapshots** as a side effect of `SnapshotGeneratorTests`. Those are test byproducts: run `git checkout -- docs/assets/` before committing and never include them in a commit.
- **Verified facts measured on the reporting Mac 2026-08-28 (do not re-derive):**
  - Mac17,2, Apple M5, macOS 26.6.2 (25G83), firmware 18000.161.10. `verdict: modern`.
  - `CHIE` present, `type=hex_ size=1 attr=0xd4 writable`. `CHTE` present, writable. `CH0B`/`BCLM` absent.
  - App preferences (`~/Library/Preferences/dev.jjundev.Wattly.plist`, correct types): `batteryAutoDischargeEnabled = true (bool)`, `batteryLimitEnabled = true (bool)`, `batteryLimitPercentage = 80 (int)`, `batterySailingEnabled = true (bool)`, `batterySailingDelta = 5 (int)`, `batteryHeatProtectionEnabled = true (bool)`, `batteryManualDischargeTarget = 80 (int)`, `batteryHeatProtectionThreshold` **absent** → `Defaults.batteryHeatProtectionThreshold` = 35.
  - Daemon persisted policy (`/Library/Application Support/Wattly/battery-control-v1.json`, root-only mode 600): `{"autoDischargeEnabled":false,"topUpActive":false,"manualDischargeActive":false,"manualDischargeTarget":80,"enabled":true,"limitPercentage":80,"heatProtectionThresholdCelsius":35,"heatProtectionResumeDeltaCelsius":2,"lowerHysteresisDelta":5,"heatProtectionMinCooldownSeconds":300,"heatProtectionEnabled":true}`, `schemaVersion: 1`, `ownerUID: 501`.
  - So the bridge builds `autoDischargeEnabled: true` while the daemon holds `false` — a standing mismatch — and `updatedAt` did not advance for **6+ minutes** across multiple 60 s reconcile intervals.
  - `BatteryControlCoordinator.capabilities` = `[.persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1]`, introduced 2026-08-23 (`0b5700c`); the installed daemon is from 2026-08-26, so it advertises all three and `shouldReapply` takes the **persistent** branch (`desired.normalized != requested`), which compares the whole configuration. A "legacy capability path" explanation was considered and **ruled out** — do not re-propose it.
  - The running app at the time of measurement was the fixed Debug build (`Wattly.debug.dylib` contains the `reconcileTaskID` and `makeConfiguration` symbols; 51 `autoDischargeEnabled` references). The fix was running. The app bundle is a stub + `Wattly.debug.dylib`, so inspect the dylib, not `Contents/MacOS/Wattly`.
  - Engine gate for auto-discharge (`FanControlShared/BatteryControlEngine.swift:296`): `config.enabled && config.autoDischargeEnabled && !topUpCompletedHold && currentSoC >= 15 && isDischargeHardwareSupported && (isCurrentlyDischarging ? currentSoC > clampedLimit : currentSoC > clampedLimit + 1)`. Heat protection is evaluated **before** it, but the observed status text was the plain limit-reached one, so heat protection was not active.
- **Explicitly out of scope** (recorded so nobody "helpfully" adds them): removing the parameter defaults on `BatteryControlClient.apply`/`reconcile`/etc.; adding a `configure(_ config:)` entry point; changing `shouldReapply`'s legacy branch; rebuilding or reinstalling the privileged helper.

## File Structure

| File | Change | Responsibility after this plan |
| --- | --- | --- |
| `Wattly/Core/BatteryControlLog.swift` | Create | Owns the single `Logger` for the battery-control path, so the subsystem/category strings exist in exactly one place. |
| `Wattly/Views/BatteryControlBridge.swift` | Modify | Adds loop/push logging; changes the auto-discharge `onChange` from a gated `reconcile` to an unconditional `apply` that preserves daemon-side transient activity via a new pure helper. |
| `Wattly/Control/BatteryControlClient.swift` | Modify | Logs the `reconcile` round-trip: the status refresh outcome, the `shouldReapply` verdict, and which branch it took. No behaviour change. |
| `Wattly/Views/Settings/SettingsBatterySection.swift` | Modify | Fixes the two remaining call sites that omit the discharge preferences (the Top Up button's `cancelTopUp`/`startTopUp`). |
| `WattlyTests/BatteryControlBridgeTests.swift` | Modify | Adds tests for the new pure activity-preserving helper. |

---

### Task 1: Make the daemon round-trip observable

**Files:**
- Create: `Wattly/Core/BatteryControlLog.swift`
- Modify: `Wattly/Views/BatteryControlBridge.swift` (the `handleReconcileLoop` method)
- Modify: `Wattly/Control/BatteryControlClient.swift` (the `reconcile` method)

**Interfaces:**
- Produces, used by Tasks 2 and 4: `BatteryControlLog.battery` — a `Logger` on subsystem `dev.jjundev.Wattly`, category `battery-control`.

This task has no unit test. Logging is verified by running the app and reading the log, which is Step 5 — that is this task's test, and it is a real one: it either prints the loop's behaviour or proves the loop is not running.

- [ ] **Step 1: Create the logger**

Create `Wattly/Core/BatteryControlLog.swift`:

```swift
import OSLog

/// The battery-control path is the one part of this app that drives a privileged helper into SMC
/// register writes, and its failures are invisible from the outside: a reconcile that decides not
/// to write looks exactly like a reconcile that never ran. One `Logger`, defined once, so the
/// subsystem and category are not retyped at each call site.
enum BatteryControlLog {
    static let battery = Logger(subsystem: "dev.jjundev.Wattly", category: "battery-control")
}
```

- [ ] **Step 2: Log every reconcile-loop tick in the bridge**

In `Wattly/Views/BatteryControlBridge.swift`, replace the body of `handleReconcileLoop` with this. The additions are five `BatteryControlLog.battery.notice(...)` calls — `started`, `cancelled`, `tick`, `exiting: hardware unsupported`, and `ended` — plus the `guard` and `if` bodies growing braces to hold them. Every other line is unchanged, and the control flow is identical. Note `privacy: .public` on the `mode` interpolation: it is a `String`, so without it the field logs as `<private>`.

```swift
    private func handleReconcileLoop() async {
        var consecutiveUnsupported = 0
        BatteryControlLog.battery.notice("reconcile loop started")
        while !Task.isCancelled {
            try? await Task.sleep(
                for: .seconds(BatteryControlPolicy.reconcileInterval(
                    consecutiveUnsupported: consecutiveUnsupported))
            )
            guard !Task.isCancelled else {
                BatteryControlLog.battery.notice("reconcile loop cancelled")
                return
            }
            let requested = configuration
            BatteryControlLog.battery.notice(
                """
                reconcile tick: enabled=\(requested.enabled) limit=\(requested.limitPercentage) \
                autoDischarge=\(requested.autoDischargeEnabled) \
                manualTarget=\(requested.manualDischargeTarget) \
                mode=\(String(describing: client.status.mode), privacy: .public) \
                unsupportedStreak=\(consecutiveUnsupported)
                """)
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
            if client.status.isHardwareSupported == false {
                BatteryControlLog.battery.notice("reconcile loop exiting: hardware unsupported")
                return
            }
        }
        BatteryControlLog.battery.notice("reconcile loop ended: task cancelled")
    }
```

- [ ] **Step 3: Log the `shouldReapply` verdict inside the client**

In `Wattly/Control/BatteryControlClient.swift`, inside `reconcile`, replace this existing guard:

```swift
        guard !Task.isCancelled,
              BatteryControlPolicy.shouldReapply(
                configuration: targetConfig,
                status: status) else { return }
```

with:

```swift
        let willReapply = BatteryControlPolicy.shouldReapply(
            configuration: targetConfig, status: status)
        BatteryControlLog.battery.notice(
            """
            reconcile verdict: willReapply=\(willReapply) cancelled=\(Task.isCancelled) \
            mode=\(String(describing: self.status.mode), privacy: .public) \
            hardwareSupported=\(String(describing: self.status.isHardwareSupported), privacy: .public) \
            capabilities=\(self.status.capabilities?.map(\.rawValue).joined(separator: ",") ?? "nil", privacy: .public) \
            requestedAutoDischarge=\(targetConfig.autoDischargeEnabled) \
            desiredAutoDischarge=\(String(describing: self.status.desiredConfiguration?.autoDischargeEnabled), privacy: .public)
            """)
        guard !Task.isCancelled, willReapply else { return }
```

Two things that are not optional here. `self.status` rather than bare `status`: `status` is the client's own property and the surrounding code refers to it unqualified, but inside a multi-line interpolation the explicit `self.` keeps it unambiguous and avoids a strict-concurrency capture diagnostic. And `privacy: .public` on all four `String`-typed fields: OSLog redacts `String` interpolations by default, so without it this line logs `mode=<private> ... capabilities=<private> ... desiredAutoDischarge=<private>` and Step 5's decision table cannot be used at all.

The reordering is deliberate and behaviour-preserving in the way that matters: the original evaluated `!Task.isCancelled` first and short-circuited, so `shouldReapply` was skipped on a cancelled task. Now `shouldReapply` is always evaluated — it is a pure function over two values with no side effects, so computing it on a cancelled task costs a few comparisons and changes nothing. The `guard` still refuses to write when cancelled, which is the property that matters (a straggler reconcile is a WRITE, per the existing comment above it).

- [ ] **Step 4: Regenerate the project and build**

The new file is invisible to the build until the project is regenerated.

```bash
xcodegen generate
```

Expected: `Loaded project ... Created project at Wattly.xcodeproj`, no error.

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Capture the loop's real behaviour on device**

Quit any running Wattly (both `/Applications/Wattly.app` and any Debug build), then launch the freshly built one. Note the app bundle is a stub plus `Wattly.debug.dylib`; `open` handles that:

```bash
APP="$(xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/Wattly.app"; open "$APP"
```

`-showBuildSettings` prints `BUILT_PRODUCTS_DIR` once per target, hence `exit` after the first match — without it the path is two lines joined and `open` fails.

Leave it running for at least three minutes with the Settings window **closed**, then read the log:

```bash
log show --last 5m --predicate 'subsystem == "dev.jjundev.Wattly"' --info --style compact
```

Expected: a `reconcile loop started` line, then a `reconcile tick:` line roughly every 60 s, each followed by a `reconcile verdict:` line.

This is the diagnostic payoff. Record which of these you see, because they are mutually exclusive explanations of the six-minute silence:
- **No `reconcile loop started` line at all** → the bridge's `.task(id:)` is never running; the problem is that the view is not mounted or the task is being cancelled immediately, and the fix belongs in `WattlyApp`/`MenuBarLabel`, not in the bridge.
- **`started` but no `tick` lines** → the loop is stuck in `Task.sleep`, or `reconcileInterval` returned a long backoff; check the `unsupportedStreak` on the first tick that does appear.
- **`tick` lines with `autoDischarge=false`** → the bridge is reading a different preference store than the one measured above; the `@AppStorage` binding is the suspect.
- **`tick` with `autoDischarge=true` and `verdict: willReapply=false`** → `shouldReapply` disagrees with the persistent-branch reasoning; the `capabilities=` and `desiredAutoDischarge=` fields in the same line say exactly why.
- **`verdict: willReapply=true` but the daemon's `updatedAt` still does not advance** → the write is being made and rejected or dropped below `apply`; the problem is in the XPC path or the daemon.

Write down which case occurred. Task 4 depends on it, and if it is the first, second, third, or fifth case, **stop and report** — Tasks 2 and 3 are still correct and worth landing, but they will not by themselves fix the device, and the remaining work is a different plan.

- [ ] **Step 6: Commit**

```bash
git checkout -- docs/assets/
git add Wattly/Core/BatteryControlLog.swift Wattly/Views/BatteryControlBridge.swift Wattly/Control/BatteryControlClient.swift Wattly.xcodeproj
git commit -m "feat(battery): log the reconcile loop and its reapply verdict"
```

---

### Task 2: A user's toggle must push unconditionally

**Files:**
- Modify: `Wattly/Views/BatteryControlBridge.swift:196-221` (the comment block and the `.onChange(of: autoDischargeEnabled)` handler)
- Test: `WattlyTests/BatteryControlBridgeTests.swift`

**Interfaces:**
- Consumes from the previous branch: `BatteryControlBridge.makeConfiguration(enabled:limitPercentage:sailingEnabled:sailingDelta:heatProtectionEnabled:heatProtectionThresholdCelsius:autoDischargeEnabled:manualDischargeTarget:) -> BatteryControlConfiguration`.
- Produces, used by the handler and the tests: `static func BatteryControlBridge.preservingActivity(_ requested: BatteryControlConfiguration, daemon desired: BatteryControlConfiguration?) -> BatteryControlConfiguration`.

**Why this is a real defect, not a style change:** the previous branch chose `reconcile` here so that flipping the toggle could not clobber a running Top Up or manual discharge. That goal is right, but `reconcile` reaches its write only past `BatteryControlPolicy.shouldReapply`. A predicate that decides "the daemon already agrees, so write nothing" is correct for a background repair pass and wrong for a button the user just pressed: if it returns `false` for any reason, the user's action vanishes with no feedback. This task keeps the preservation and drops the gate, by reading the daemon's transient state explicitly and folding it into an unconditional `apply`.

**Two honest limits on that story, so nobody over-reads it.** First, the clobber protection was only ever true of the *bridge's* path: `SettingsBatterySection`'s own `.onChange(of: autoDischargeEnabled)` (around line 401) already pushes unconditionally via `setAutoDischarge`, and that call hardcodes `topUpActive: false, manualDischargeActive: false` — so whenever the Settings window is open, a toggle already cancels a running Top Up or manual discharge. This task does not change that, and Task 4's precondition #4 (Settings closed during verification) is what keeps it out of the measurement. Second, `preservingActivity` does **not** reproduce `reconcile`'s `effectiveEnabled = enabled || isTopUp || isManualDischarge`. That matters only in one reachable corner — the charge limit off while a Top Up or manual discharge runs, which `BatterySectionPresentation.isToggleEnabled` permits — where this push carries `enabled: false` instead of the effectively-true value `reconcile` would have computed. Tracing `BatteryControlEngine.update`, the `topUpActive` and `manualDischargeActive` branches do not test `config.enabled`, so the hardware does the right thing anyway, and the next ~60 s reconcile tick restores the field. It is a cosmetic divergence in the pushed record, not a functional regression — recorded here rather than fixed, because widening this task to reproduce `effectiveEnabled` would re-import the coupling the pure helper exists to avoid.

- [ ] **Step 1: Write the failing tests**

Append these two tests inside the existing `BatteryControlBridgeTests` suite in `WattlyTests/BatteryControlBridgeTests.swift`, just before the suite's closing `}`:

```swift
    // MARK: - 토글 푸시가 보존하는 것

    /// A toggle press must not cancel a Top Up or a manual discharge that the daemon is running —
    /// that was the whole reason the handler used to go through `reconcile`. The preservation is
    /// now explicit and pure, so it survives without the `shouldReapply` gate that was swallowing
    /// the user's press.
    @Test func preservingActivityCarriesDaemonTransientStateForward() {
        let requested = BatteryControlBridge.makeConfiguration(
            enabled: true, limitPercentage: 80,
            sailingEnabled: true, sailingDelta: 5,
            heatProtectionEnabled: true, heatProtectionThresholdCelsius: 35,
            autoDischargeEnabled: true, manualDischargeTarget: 80)
        let daemon = BatteryControlConfiguration(
            enabled: true,
            limitPercentage: 80,
            lowerHysteresisDelta: 5,
            topUpActive: true,
            autoDischargeEnabled: false,
            manualDischargeActive: true,
            manualDischargeTarget: 70)

        let merged = BatteryControlBridge.preservingActivity(requested, daemon: daemon)

        // Transient activity comes from the daemon.
        #expect(merged.topUpActive == true)
        #expect(merged.manualDischargeActive == true)
        // A running manual discharge owns its target; the stored preference must not yank it.
        #expect(merged.manualDischargeTarget == 70)
        // The user's own settings still win.
        #expect(merged.autoDischargeEnabled == true)
        #expect(merged.enabled == true)
        #expect(merged.limitPercentage == 80)
        #expect(merged.lowerHysteresisDelta == 5)
    }

    /// With nothing running on the daemon — and with no daemon answer at all — the request stands
    /// as written, including the stored manual-discharge target.
    @Test func preservingActivityLeavesAnIdleDaemonRequestAlone() {
        let requested = BatteryControlBridge.makeConfiguration(
            enabled: true, limitPercentage: 85,
            sailingEnabled: false, sailingDelta: 5,
            heatProtectionEnabled: false, heatProtectionThresholdCelsius: 35,
            autoDischargeEnabled: true, manualDischargeTarget: 70)
        let idle = BatteryControlConfiguration(
            enabled: true, limitPercentage: 85, lowerHysteresisDelta: 2,
            topUpActive: false, autoDischargeEnabled: false,
            manualDischargeActive: false, manualDischargeTarget: 80)

        let merged = BatteryControlBridge.preservingActivity(requested, daemon: idle)
        #expect(merged.topUpActive == false)
        #expect(merged.manualDischargeActive == false)
        #expect(merged.manualDischargeTarget == 70)
        #expect(merged.autoDischargeEnabled == true)

        let unknown = BatteryControlBridge.preservingActivity(requested, daemon: nil)
        #expect(unknown == requested)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlBridgeTests test 2>&1 | tail -30
```

Expected: **BUILD FAILED** with `type 'BatteryControlBridge' has no member 'preservingActivity'`. A compile failure is the red state — Swift cannot run a test naming a symbol that does not exist.

- [ ] **Step 3: Add the pure helper**

In `Wattly/Views/BatteryControlBridge.swift`, add this immediately after the `makeConfiguration` function:

```swift
    /// Folds the daemon's transient activity into a configuration built from stored preferences.
    /// `topUpActive` and `manualDischargeActive` describe what the helper is *doing*, not what the
    /// user chose, so a push driven by a preference change must carry them forward or it cancels
    /// them as a side effect. A running manual discharge also owns its target — the stored
    /// preference must not yank a discharge in progress to a different number. `nil` means the
    /// helper has not answered, and then the request stands exactly as built.
    static func preservingActivity(
        _ requested: BatteryControlConfiguration,
        daemon desired: BatteryControlConfiguration?
    ) -> BatteryControlConfiguration {
        guard let desired else { return requested }
        var merged = requested
        merged.topUpActive = desired.topUpActive
        merged.manualDischargeActive = desired.manualDischargeActive
        if desired.manualDischargeActive {
            merged.manualDischargeTarget = desired.manualDischargeTarget
        }
        return merged
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlBridgeTests test 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 8 tests (6 existing + 2 new).

- [ ] **Step 5: Make the handler push unconditionally**

In `Wattly/Views/BatteryControlBridge.swift`, replace the comment block and handler that currently read:

```swift
            // Auto-discharge is a user setting, not transient activity, so nothing in
            // `BatteryControlPolicy` preserves it for us — flipping it has to push. `reconcile`
            // rather than `apply`: it reads the helper first, so it keeps a running Top Up or
            // manual discharge intact and writes nothing at all when the settings screen already
            // pushed the same change a moment ago.
            .onChange(of: autoDischargeEnabled) { _, isAutoDischarge in
                let requested = Self.makeConfiguration(
                    enabled: enabled,
                    limitPercentage: limit,
                    sailingEnabled: sailingEnabled,
                    sailingDelta: sailingDelta,
                    heatProtectionEnabled: heatProtectionEnabled,
                    heatProtectionThresholdCelsius: heatProtectionThreshold,
                    autoDischargeEnabled: isAutoDischarge,
                    manualDischargeTarget: manualDischargeTarget)
                Task {
                    await client.reconcile(
                        enabled: requested.enabled,
                        limitPercentage: requested.limitPercentage,
                        lowerHysteresisDelta: requested.lowerHysteresisDelta,
                        heatProtectionEnabled: requested.heatProtectionEnabled,
                        heatProtectionThresholdCelsius: requested.heatProtectionThresholdCelsius,
                        autoDischargeEnabled: requested.autoDischargeEnabled,
                        manualDischargeTarget: requested.manualDischargeTarget)
                }
            }
```

with:

```swift
            // A toggle the user just pressed is an explicit instruction, so it pushes
            // unconditionally. It deliberately does NOT go through `reconcile`: that path writes
            // only if `BatteryControlPolicy.shouldReapply` agrees, and a repair predicate deciding
            // "the daemon already matches" is right for a background pass and wrong for a button —
            // the press would vanish with nothing shown to the user. Preservation of a running Top
            // Up or manual discharge, which is why this once used `reconcile`, is now explicit via
            // `preservingActivity` over a freshly read status.
            .onChange(of: autoDischargeEnabled) { _, isAutoDischarge in
                let requested = Self.makeConfiguration(
                    enabled: enabled,
                    limitPercentage: limit,
                    sailingEnabled: sailingEnabled,
                    sailingDelta: sailingDelta,
                    heatProtectionEnabled: heatProtectionEnabled,
                    heatProtectionThresholdCelsius: heatProtectionThreshold,
                    autoDischargeEnabled: isAutoDischarge,
                    manualDischargeTarget: manualDischargeTarget)
                Task {
                    await client.refreshStatus()
                    let merged = Self.preservingActivity(
                        requested, daemon: client.status.desiredConfiguration)
                    BatteryControlLog.battery.notice(
                        "auto-discharge toggle push: autoDischarge=\(merged.autoDischargeEnabled) topUp=\(merged.topUpActive) manualActive=\(merged.manualDischargeActive)")
                    await client.apply(
                        enabled: merged.enabled,
                        limitPercentage: merged.limitPercentage,
                        lowerHysteresisDelta: merged.lowerHysteresisDelta,
                        heatProtectionEnabled: merged.heatProtectionEnabled,
                        heatProtectionThresholdCelsius: merged.heatProtectionThresholdCelsius,
                        topUpActive: merged.topUpActive,
                        autoDischargeEnabled: merged.autoDischargeEnabled,
                        manualDischargeActive: merged.manualDischargeActive,
                        manualDischargeTarget: merged.manualDischargeTarget)
                }
            }
```

- [ ] **Step 6: Run the full suite**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | grep -E "✘|error:|Test run with|TEST SUCCEEDED|TEST FAILED"
```

Expected: `✔ Test run with 1059 tests in 78 suites passed` and `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git checkout -- docs/assets/
git add Wattly/Views/BatteryControlBridge.swift WattlyTests/BatteryControlBridgeTests.swift
git commit -m "fix(battery): push the auto-discharge toggle unconditionally"
```

---

### Task 3: The last two call sites that drop the discharge preferences

**Files:**
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift:175-194` (the Top Up button's `Task` block)

**Interfaces:**
- Consumes (unchanged, already present): `BatteryControlClient.cancelTopUp(limitPercentage:lowerHysteresisDelta:heatProtectionEnabled:heatProtectionThresholdCelsius:autoDischargeEnabled:manualDischargeTarget:)` and `BatteryControlClient.startTopUp(...)` with the same trailing parameters. Both default `autoDischargeEnabled` to `false` and `manualDischargeTarget` to `80`.
- Produces: nothing other tasks consume.

An audit of every `BatteryControlClient` call site in `Wattly/` found these two as the only remaining battery calls that omit `autoDischargeEnabled:`. They fire only on a button press, so they did not cause the observed failure — but pressing 한 번만 완충 while auto-discharge is on still clears the opt-in and resets a custom manual target, which is the same class of defect the previous branch fixed everywhere else.

One nearby line to leave alone: `SettingsBatterySection.swift:403` calls `setAutoDischarge(enabled:)`, whose `enabled:` label maps to `autoDischargeEnabled` inside the client, so it is already correct. An earlier informal pass flagged it; the Step 3 audit below does **not** — `setAutoDischarge` is deliberately absent from that command's function-name alternation, so line 403 can never match it. Do not "fix" it.

This View has no test seam, so there is no unit test; the gate is the audit command in Step 3 plus the full suite.

- [ ] **Step 1: Add the two preferences to the button's captured values**

In `Wattly/Views/Settings/SettingsBatterySection.swift`, replace this block:

```swift
                        Button {
                            let limit = batteryLimitPercentage
                            let delta = effectiveDelta
                            let heatEnabled = batteryHeatProtectionEnabled
                            let heatThreshold = Defaults.batteryHeatProtectionThreshold
                            Task {
                                if isTopUp {
                                    await batteryControl.cancelTopUp(
                                        limitPercentage: limit,
                                        lowerHysteresisDelta: delta,
                                        heatProtectionEnabled: heatEnabled,
                                        heatProtectionThresholdCelsius: heatThreshold)
                                } else {
                                    await batteryControl.startTopUp(
                                        limitPercentage: limit,
                                        lowerHysteresisDelta: delta,
                                        heatProtectionEnabled: heatEnabled,
                                        heatProtectionThresholdCelsius: heatThreshold)
                                }
                            }
                        } label: {
```

with:

```swift
                        Button {
                            let limit = batteryLimitPercentage
                            let delta = effectiveDelta
                            let heatEnabled = batteryHeatProtectionEnabled
                            let heatThreshold = Defaults.batteryHeatProtectionThreshold
                            let autoDischarge = autoDischargeEnabled
                            let manualTarget = manualDischargeTarget
                            Task {
                                if isTopUp {
                                    await batteryControl.cancelTopUp(
                                        limitPercentage: limit,
                                        lowerHysteresisDelta: delta,
                                        heatProtectionEnabled: heatEnabled,
                                        heatProtectionThresholdCelsius: heatThreshold,
                                        autoDischargeEnabled: autoDischarge,
                                        manualDischargeTarget: manualTarget)
                                } else {
                                    await batteryControl.startTopUp(
                                        limitPercentage: limit,
                                        lowerHysteresisDelta: delta,
                                        heatProtectionEnabled: heatEnabled,
                                        heatProtectionThresholdCelsius: heatThreshold,
                                        autoDischargeEnabled: autoDischarge,
                                        manualDischargeTarget: manualTarget)
                                }
                            }
                        } label: {
```

The local `let` bindings match the surrounding style, which reads `@AppStorage` values on the main actor before entering the `Task`.

- [ ] **Step 2: Run the full suite**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | grep -E "✘|error:|Test run with|TEST SUCCEEDED|TEST FAILED"
```

Expected: `✔ Test run with 1059 tests in 78 suites passed` and `** TEST SUCCEEDED **`. No new tests here, so the count is unchanged from Task 2.

- [ ] **Step 3: Re-run the call-site audit**

```bash
grep -rn -E "\.(apply|startTopUp|cancelTopUp|startManualDischarge|stopManualDischarge|reconcile|disableAndConfirm|installAndApply)\(" --include="*.swift" Wattly | grep -v "func \|//" | while IFS= read -r line; do f="${line%%:*}"; rest="${line#*:}"; n="${rest%%:*}"; if ! sed -n "${n},$((n+16))p" "$f" | grep -q "autoDischargeEnabled"; then echo "MISSING -> $f:$n"; fi; done
```

Expected: only `FanControlBridge.swift`, `SettingsFanCurveSection.swift`, and `FanControlClient.swift` lines. Those are the **fan** client, a different type with no discharge concept — they are correct as-is. **No `SettingsBatterySection.swift`, `BatteryControlBridge.swift`, `CardExpandRegion.swift`, `BatteryScheduleCoordinator.swift`, or `BatteryIntentBridge.swift` line may appear.**

- [ ] **Step 4: Commit**

```bash
git checkout -- docs/assets/
git add Wattly/Views/Settings/SettingsBatterySection.swift
git commit -m "fix(battery): carry the discharge preferences through the Top Up button"
```

---

### Task 4: On-device re-verification

**Files:** none. This task changes no code; it establishes whether the device symptom is gone.

**Interfaces:**
- Consumes: `BatteryControlLog.battery` (Task 1) and the unconditional toggle push (Task 2).
- Produces: a pass/fail observation on `CHIE`, and — if it fails — the log evidence that names the next thing to fix.

**Preconditions, all of which failed at least once during the previous attempt.** Do not start until every one holds:
1. **Power adapter connected.** `ioreg -rn AppleSmartBattery | grep '"ExternalConnected"'` must print `Yes`. The scenario is charge-inhibit plus forced discharge; it does not exist on battery power.
2. **Exactly one Wattly running**, the freshly built Debug one. `ps aux | grep "[W]attly.app"` must print a single line under `DerivedData`. `/Applications/Wattly.app` must be quit — it has none of these fixes and its bridge writes to the same daemon.
3. **Battery level at least 2 points above the charge limit.** The engine requires `currentSoC > limit + 1` when not already discharging, so at limit 80 the level must be 82 or more. The Settings UI offers only 80/85/90/95, so the way to create this is to raise the limit, let it charge, then lower it.
4. **Settings window and popover both closed** during the observation window. Both surfaces push on their own and would mask what the bridge does.

- [ ] **Step 1: Record the baseline**

```bash
swift scripts/probe-charge-registers.swift 2>&1 | grep -E "CHTE|CHIE"; ioreg -rn AppleSmartBattery | grep -E '"ExternalConnected"|"IsCharging"|"CurrentCapacity"'
```

This probe is read-only; it writes nothing. Record `CHIE` and the capacity.

- [ ] **Step 2: Create the level-above-limit condition**

In Settings → 배터리 충전 제어, set 최대 충전 한도 to a value above the current level (85% or 90%), and wait until the battery charges at least 2 points past 80. Watch it without polling by hand:

```bash
for i in $(seq 1 60); do CAP=$(ioreg -rn AppleSmartBattery | awk -F'= ' '/"CurrentCapacity"/{print $2}'); echo "$(date +%H:%M:%S) cap=$CAP"; [ "$CAP" -ge 82 ] && break; sleep 30; done
```

Expected: the capacity climbs and the loop stops at 82 or higher.

- [ ] **Step 3: Set the trigger and close the window**

In Settings, set 최대 충전 한도 back to **80%**, confirm 자동 방전 is **on**, then close the Settings window and make sure the popover is closed.

- [ ] **Step 4: Confirm the discharge arms**

```bash
for i in $(seq 1 18); do CHIE=$(swift scripts/probe-charge-registers.swift 2>/dev/null | awk '/CHIE/{print $NF}'); echo "$(date +%H:%M:%S) CHIE=$CHIE"; [ "$CHIE" = "[08]" ] && { echo ARMED; break; }; sleep 10; done
```

Expected: `CHIE=[08]` — forced discharge armed.

- [ ] **Step 5: Confirm it survives the reconcile loop**

Wait at least 90 seconds — more than one 60 s `reconcileInterval` — with both windows still closed, then probe again:

```bash
swift scripts/probe-charge-registers.swift 2>&1 | grep -E "CHTE|CHIE"; ioreg -rn AppleSmartBattery | awk -F'= ' '/"CurrentCapacity"/{print "cap=" $2}'
```

Expected: still `CHIE=[08]`, with the capacity at **81 or above**.

Mind the asymmetry in the engine's gate (`BatteryControlEngine.swift:296`), because it decides what counts as a failure here. The `+ 1` applies only to *entering* discharge: `isCurrentlyDischarging ? currentSoC > limit : currentSoC > limit + 1`. So at limit 80, discharge starts at 82 and then **continues while the capacity is 81 or above**, stopping only at 80. Therefore: `CHIE=[00]` at capacity 81 is a genuine **failure**; `CHIE=[00]` at capacity 80 or below is **correct behaviour** — the target was reached. If the capacity reached 80 before the 90 seconds elapsed, the window was too small: re-run from Step 2 with more headroom.

- [ ] **Step 6: Confirm the daemon holds the opt-in**

The persisted policy is root-owned mode 600, so this needs the machine's own user:

```bash
sudo cat "/Library/Application Support/Wattly/battery-control-v1.json"
```

Expected: `"autoDischargeEnabled":true`.

- [ ] **Step 7: Read the log regardless of the outcome**

```bash
log show --last 10m --predicate 'subsystem == "dev.jjundev.Wattly"' --info --style compact
```

On success this should show `reconcile tick:` lines carrying `autoDischarge=true`, and `reconcile verdict:` lines settling to `willReapply=false` once the daemon agrees — the loop running and finding nothing to repair.

On failure, this log is the deliverable. Do **not** patch further from a hunch: capture the full output, note which of Task 1 Step 5's five cases it matches, and report. The previous attempt burned three wrong hypotheses (heat-protection latch, `topUpCompletedHold`, legacy capability path) precisely because it reasoned from outside the process instead of from a log.

- [ ] **Step 8: Restore the user's settings**

The verification moved the charge limit and may have moved the manual-discharge target. Ask the user what these should be rather than assuming; the values before this plan began were limit 80, 자동 방전 on, manual target 80.

---

## Self-Review

**Spec coverage** — the "spec" here is the failed verification and the two defects it exposed:

| Requirement | Task |
| --- | --- |
| Explain the six-minute reconcile silence | Task 1 (instrumentation + the five-case decision table in Step 5) |
| A user's auto-discharge toggle must reach the daemon | Task 2 |
| Keep Top Up / manual discharge from being clobbered by that push | Task 2 (`preservingActivity`, both tests) |
| Remaining call sites that drop the discharge preferences | Task 3 (audit gate in Step 3) |
| Re-verify `CHIE=[08]` on device and that it survives 90 s | Task 4 Steps 4–5 |
| Verify the daemon actually holds the opt-in | Task 4 Step 6 |
| Leave the failure diagnosable next time | Task 1, and Task 4 Step 7 |

**Placeholder scan:** no "TBD"/"handle edge cases"/"write tests for the above". Every code step carries literal code; every command carries its expected output. Task 1 Step 5 and Task 4 Step 7 describe *reading* a log rather than writing code — that is the deliverable of a diagnostic task, and both enumerate the concrete outcomes and what each implies rather than deferring the thinking.

**Type consistency:** `preservingActivity(_:daemon:)` has one signature, used identically in Task 2's tests, its implementation, and the handler. `BatteryControlLog.battery` is defined in Task 1 and used in Tasks 1 and 2. `makeConfiguration` is consumed with the exact argument labels the previous branch defined. Test counts are consistent: 1057 at branch head, +2 in Task 2 = 1059, unchanged by Task 3.

**Known gap, stated rather than hidden:** if Task 1 Step 5 reveals the loop is not running at all, or that writes are made and dropped below `apply`, then Tasks 2 and 3 are still correct but will not fix the device, and the remaining work needs a new plan. Task 1 Step 5 says so explicitly and tells the implementer to stop and report.
