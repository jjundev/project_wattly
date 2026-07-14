# Eco / Performance mode plan

> **For implementation:** execute this plan task-by-task, keeping the existing low-power
> provider scheduler as the default behavior.

## Goal

Let the user choose, in Settings, whether the low-power scheduler introduced on this
branch is active:

- **에코 모드** keeps the current provider-level adaptive policy. With an automatic
  interval and a closed panel, only providers needed by enabled menubar text are read.
- **성능 모드** preserves the pre-scheduler experience. Every *active* provider remains
  warm at the selected global cadence while the panel is closed, so panel values,
  per-app power baselines, and sparklines recover without the first-sample delay.

`active` remains the existing visibility/menubar gate in both modes. A deliberately
hidden card is not made active again by performance mode; the setting changes cadence,
not which telemetry the user enabled.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Persisted model | `PowerMode` string enum (`eco`, `performance`) | Matches existing `PollInterval` / `PanelMode` storage and makes the policy pure and testable. |
| Default / reset | `.eco` | Existing installations and the current branch keep their low-power behavior until the user opts in to performance. |
| Scope of performance behavior | All active providers at `resolvePollInterval(...)` | This reproduces the former one-global-cadence scheduler for the providers the user exposes, including closed panel states. |
| Fixed interval chips | Identical in both modes | Fixed intervals already poll every active provider at the explicit cadence; mode selection is meaningful for automatic adaptive behavior. |
| UI control | A two-option `WattlySegment` in a new “동작 모드” settings section | Uses the app's existing selection control and makes the mutually exclusive choice clear. |
| Transition behavior | Reschedule immediately; newly added providers are force-read | Avoids waiting for a stale timer after selecting Performance. Power’s cumulative-energy calculation still needs its normal second sample before per-app watts are valid. |

## Tasks

## Task 1: Add the persisted mode and make the policy explicit

**Files**

- Modify `Wattly/Settings/Settings.swift`
- Modify `Wattly/Core/PollPolicy.swift`
- Modify `WattlyTests/PollPolicyTests.swift`

**Implementation**

1. Add `PowerMode: String, CaseIterable, Identifiable, Sendable` next to
   `PollInterval`, with `.eco` and `.performance`, Korean labels `에코` and `성능`, and
   a `PowerMode.eco` default in `Defaults`.
2. Add `StorageKey.powerMode = "powerMode"`.
3. Change the policy seam to accept `mode: PowerMode`:

   ```swift
   func providerIntervals(mode: PowerMode,
                          setting: PollInterval,
                          panelVisible: Bool,
                          menubarTextEnabled: Bool,
                          active: Set<ProviderKind>,
                          menubarNeeds: Set<CardKind>) -> [ProviderKind: Duration]
   ```

4. Keep the present provider-specific automatic table exactly for `.eco`. For
   `.performance`, return every `active` provider using the global result of
   `resolvePollInterval(setting:panelVisible:menubarTextEnabled:)`. Do this before the
   eco-specific automatic branches; the fixed interval result consequently remains equal
   in both modes.
5. Update existing policy calls to pass `.eco`. Add table tests proving that performance
   mode includes all active providers when the panel is closed, both with and without
   menubar text, and that the selected interval is the legacy 2 s / 5 s automatic
   cadence. Keep a fixed-interval assertion to show the modes agree when a user pins a
   cadence.

**Acceptance checks**

- `.eco` produces the current branch's exact schedule.
- `.performance` with all providers active and automatic closed-panel state returns all
  providers at 2 s (text on) or 5 s (text off), rather than only menu providers / none.
- A hidden provider remains absent because it is not in `active`.

## Task 2: Wire live mode changes into the monitor and reset path

**Files**

- Modify `Wattly/Core/SystemMonitor.swift`
- Modify `Wattly/Views/PollPolicyBridge.swift`
- Modify `Wattly/Core/SettingsReset.swift`
- Modify `WattlyTests/SystemMonitorTests.swift`
- Modify `WattlyTests/SettingsResetTests.swift`

**Implementation**

1. Store `private var powerMode = Defaults.powerMode` in `SystemMonitor`. Pass it to
   `currentProviderIntervals`.
2. Add `setPowerMode(_:)`, following the existing interval/gating setters: compare the
   before/after schedules, then reschedule when they differ. During a live selection,
   force providers newly introduced by the new schedule so switching to performance starts
   warming values right away. Do not force an unchanged provider solely for the selection
   change.
3. Make `reschedule(forceProviders:)` itself a no-op while `pollTask == nil` (or apply an
   equivalent common “started” guard used by **every** configuration setter). This is
   essential because `PollPolicyBridge` seeds persisted power mode, text, card visibility,
   and menubar metrics before its final `start()`: no setter may start a loop and read a
   provider from only a partially seeded configuration. After the bridge's final
   `monitor.start()`, every existing live setter retains its immediate reschedule behavior.
4. Add `@AppStorage(StorageKey.powerMode)` to `PollPolicyBridge`. Seed
   `monitor.setPowerMode(powerMode)` before `start()`, and forward later changes in an
   `.onChange` handler.
5. Have `SettingsReset.applyDefaults` write `Defaults.powerMode.rawValue`.
6. Extend the settings-reset scalar test by dirtying the key to `.performance` and
   asserting it resets to `.eco`.
7. Add a `SystemMonitor` scheduling test with counting CPU and power providers. With a
   closed, automatic, menubar-CPU-only monitor, switch to `.performance`, stop any
   replacement loop created by the setter, perform the deterministic `pollScheduled`,
   and assert both providers are read. This protects the live bridge from becoming a
   persisted-but-unused preference.
8. Add a seed-safety test that applies `.performance` and a non-default visibility or
   menubar configuration to a monitor that has not been started, then verifies neither
   configuration setter starts a background loop or reads a provider before the caller
   explicitly starts it. This protects the bridge's full-configuration-before-start
   invariant.

**Acceptance checks**

- The initial bridge seed applies the stored setting before polling begins.
- A stored Performance mode cannot read a provider before the bridge has seeded card and
  menubar gates.
- Switching from eco to performance while closed schedules formerly dormant active
  providers immediately.
- Reset returns the persistent preference and live `@AppStorage` UI to eco.

## Task 3: Expose the choice and describe its observable trade-off

**Files**

- Modify `Wattly/Views/SettingsView.swift`
- Modify `Wattly/Settings/Settings.swift`
- Modify `WattlyTests/PanelPresentationTests.swift`

**Implementation**

1. Add `@AppStorage(StorageKey.powerMode)` to `SettingsView` and insert an “동작 모드”
   section directly before “업데이트 주기”.
2. Render `WattlySegment(selection: $powerMode, options: ...)` with the two Korean
   labels. Beneath it, show mode-specific, non-promissory copy:

   - Eco: closed panels reduce background metric reads; opening the panel can need a
     fresh value and graph sample.
   - Performance: active metrics keep updating in the background; panel values and
     graphs are ready sooner, using more power.

3. Replace the global, eco-only `automaticPollingDescription` with a
   `pollingDescription(for: PowerMode)` helper (or equivalent mode-specific description),
   and use it in the update-cadence section. This avoids saying “text off stops metric
   polling” while Performance mode correctly continues its active-provider cadence.
4. Replace the existing `automaticPollingDescription` assertion in
   `PanelPresentationTests` with explicit Eco and Performance
   `pollingDescription(for:)` assertions. This keeps the displayed policy copy a tested
   contract and avoids retaining an inaccurate Eco-only global.
5. Adjust the settings window height only if the existing scroll area clips the new
   section; preserve its scroll behavior and existing section order otherwise.

**Acceptance checks**

- The selection is visible in Settings, survives restart, and updates a running monitor.
- Copy accurately explains that Performance trades higher background work for warm panel
  data; it does not promise an instant first per-app watt number, which inherently needs
  two energy counter samples.
- The automatic cadence description matches the selected mode.

## Verification

Run after implementation:

```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Wattly.xcodeproj -scheme Wattly -configuration Release \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Manual smoke test in a signed local build:

1. Set automatic + Eco, close the panel, wait five seconds, then open it. Confirm only
   the menubar metric remains warm and the power graph can acquire its first samples.
2. Set automatic + Performance, close the panel, wait five seconds, then open it.
   Confirm displayed active metrics and their sparklines have continued samples.
3. Expand per-app power in either mode. Confirm its first read establishes a baseline and
   the per-app watt list appears after the next power interval; this energy-delta
   requirement is independent of the mode setting.
4. Reset settings and confirm Eco is selected.

## Risks and non-goals

- Performance mode intentionally increases background reads; it is an opt-in compatibility
  mode, not a speedup to the physical per-process energy-delta calculation.
- The mode does not override hidden-card or unavailable-sensor gating.
- This plan does not alter the 30-second self-power sampling cadence or install/publish a
  new build; those remain separate release actions.
