# Active Discharge Power Supply Visibility Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the battery card's `전원 공급원`, `어댑터 전력`, and `시스템 소비 전력` rows visible throughout manual or automatic forced discharge without showing them during ordinary unplugged battery use.

**Architecture:** Move the visibility decision out of the private SwiftUI branch into a pure `BatterySectionPresentation.shouldShowPowerSupplySection(...)` policy. The policy combines the raw `BatterySample.externalConnected` value with the helper's verified adapter/activity state and the Power Flow scenario, while still requiring an actual `PowerFlowSnapshot`; `CardExpandRegion` remains a renderer of the resulting decision.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, Wattly `BatterySample`, `BatteryControlServiceStatus`, and `PowerFlowSnapshot`.

## Global Constraints

- Work only in `/Users/hyunjun_macbook_pro/.gemini/antigravity/worktrees/project_wattly/implement_manual_automatic_discharge`.
- Preserve all existing uncommitted manual-discharge and button-style changes; do not reset, overwrite, or silently include them in this fix's commit.
- Do not modify SMC keys, `BatteryProvider` telemetry semantics, `BatteryControlEngine`, `BatteryDaemonControlService`, or the installed helper; this is a presentation-only fix.
- During verified or requested forced discharge, keep all three power-supply rows visible even when raw `externalConnected` becomes `false` because `CHIE=8` isolates the adapter.
- During ordinary battery-only operation with no active/requested discharge and no helper-confirmed adapter, keep the power-supply rows hidden.
- If `BatterySample.powerFlow` is absent, keep the section hidden rather than inventing adapter or system wattage.
- Preserve the existing forced-discharge copy: `배터리 강제 방전 중 ⚡`, `0.0 W (차단됨)`, and the measured `systemWatts` value.
- Do not change `방전 시작`, `방전 중지`, `비활성화됨`, their colors, button enablement, row visibility, localization entries, or accessibility copy in this task.
- Use Swift Testing for new tests and verify with the full macOS suite before live acceptance.

---

### Task 1: Unify the power-supply section's effective adapter-state policy

**Files:**
- Modify: `Wattly/Core/BatterySectionPresentation.swift:467`
- Modify: `Wattly/Views/CardExpandRegion.swift:244-273`
- Test: `WattlyTests/BatterySectionPresentationTests.swift:777-789`

**Interfaces:**
- Consumes: `sampleExternalConnected: Bool`, `serviceAdapterConnected: Bool`, `activity: BatteryControlActivity?`, `manualDischargeActive: Bool`, and `powerFlowScenario: PowerFlowScenario?`.
- Produces: `BatterySectionPresentation.shouldShowPowerSupplySection(...) -> Bool`, used only to gate the three existing power-supply rows.

- [ ] **Step 1: Write the failing visibility-policy regression test**

Add this test next to `dischargeAndPowerFlowLabels()` in `WattlyTests/BatterySectionPresentationTests.swift`:

```swift
@Test func powerSupplyVisibilityUsesEffectiveAdapterStateDuringForcedDischarge() {
    #expect(BatterySectionPresentation.shouldShowPowerSupplySection(
        sampleExternalConnected: false,
        serviceAdapterConnected: true,
        activity: .discharging,
        manualDischargeActive: true,
        powerFlowScenario: .batteryOnly
    ))

    #expect(BatterySectionPresentation.shouldShowPowerSupplySection(
        sampleExternalConnected: false,
        serviceAdapterConnected: false,
        activity: .discharging,
        manualDischargeActive: false,
        powerFlowScenario: .batteryOnly
    ))

    #expect(BatterySectionPresentation.shouldShowPowerSupplySection(
        sampleExternalConnected: false,
        serviceAdapterConnected: false,
        activity: nil,
        manualDischargeActive: false,
        powerFlowScenario: .activeDischarge
    ))

    #expect(!BatterySectionPresentation.shouldShowPowerSupplySection(
        sampleExternalConnected: false,
        serviceAdapterConnected: false,
        activity: nil,
        manualDischargeActive: false,
        powerFlowScenario: .batteryOnly
    ))

    #expect(!BatterySectionPresentation.shouldShowPowerSupplySection(
        sampleExternalConnected: true,
        serviceAdapterConnected: true,
        activity: .discharging,
        manualDischargeActive: true,
        powerFlowScenario: nil
    ))
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
xcodebuild test \
  -project Wattly.xcodeproj \
  -scheme Wattly \
  -destination 'platform=macOS' \
  -only-testing:WattlyTests/BatterySectionPresentationTests
```

Expected: build/test failure because `BatterySectionPresentation` has no member `shouldShowPowerSupplySection`. The existing 57 presentation tests must remain otherwise unchanged.

- [ ] **Step 3: Implement the pure effective-adapter visibility policy**

Add this method to `BatterySectionPresentation` immediately after `startDischargeButtonText(...)`:

```swift
static func shouldShowPowerSupplySection(
    sampleExternalConnected: Bool,
    serviceAdapterConnected: Bool,
    activity: BatteryControlActivity?,
    manualDischargeActive: Bool,
    powerFlowScenario: PowerFlowScenario?
) -> Bool {
    guard let powerFlowScenario else { return false }
    return sampleExternalConnected
        || serviceAdapterConnected
        || activity == .discharging
        || manualDischargeActive
        || powerFlowScenario == .activeDischarge
}
```

This is fail-closed for missing telemetry: verified/requested discharge may override a false raw connection flag, but no state may override a missing `PowerFlowSnapshot`.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the command from Step 2.

Expected: `BatterySectionPresentationTests` passes 58 tests with no failure in `powerSupplyVisibilityUsesEffectiveAdapterStateDuringForcedDischarge`.

- [ ] **Step 5: Replace the raw `externalConnected` SwiftUI gate with the policy**

In `CardExpandRegion.batteryExpand(_:)`, replace the current category-1 block beginning with `if s.externalConnected, let flow = s.powerFlow` with this complete block:

```swift
// [범주 1] 전원 공급 및 소비 전력 — 물리 어댑터 연결 또는 강제 방전 중 노출
if let flow = s.powerFlow {
    let activity = batteryControl?.status.activity
    let manualDischargeActive =
        batteryControl?.status.desiredConfiguration?.manualDischargeActive == true
    let isDischarging = activity == .discharging
        || manualDischargeActive
        || flow.scenario == .activeDischarge
    let shouldShowPowerSupply =
        BatterySectionPresentation.shouldShowPowerSupplySection(
            sampleExternalConnected: s.externalConnected,
            serviceAdapterConnected:
                batteryControl?.status.isPowerAdapterConnected == true,
            activity: activity,
            manualDischargeActive: manualDischargeActive,
            powerFlowScenario: flow.scenario
        )

    if shouldShowPowerSupply {
        let powerSourceValue = isDischarging
            ? BatterySectionPresentation.forcedDischargeText(locale: locale)
            : CardPresentation.powerSourceText(flow.scenario, locale: locale)
        let adapterPowerValue = isDischarging
            ? BatterySectionPresentation.adapterPowerBlockedText(locale: locale)
            : CardPresentation.adapterPowerText(flow.adapterWatts)

        VStack(alignment: .leading, spacing: 10) {
            batteryDetailRow(
                label: CardPresentation.powerSourceLabel,
                value: powerSourceValue
            )
            batteryDetailRow(
                label: CardPresentation.adapterPowerLabel,
                value: adapterPowerValue
            )
            batteryDetailRow(
                label: CardPresentation.systemPowerLabel,
                value: CardPresentation.systemPowerText(flow.systemWatts)
            )
        }
        Divider().background(t.line).opacity(0.6)
    }
}
```

Do not change the category-2 electrical metrics, category-3 capacity/health rows, schedule row, Top-Up row, or manual-discharge row below this block.

- [ ] **Step 6: Compile the real call site and rerun presentation tests**

Run:

```bash
xcodebuild test \
  -project Wattly.xcodeproj \
  -scheme Wattly \
  -destination 'platform=macOS' \
  -only-testing:WattlyTests/BatterySectionPresentationTests \
  -only-testing:WattlyTests/PowerFlowTests \
  -only-testing:WattlyTests/CardPresentationTests
```

Expected: all three selected suites pass. This compiles `CardExpandRegion` against the new policy and protects the existing Power Flow scenario and copy formatting.

- [ ] **Step 7: Run the complete automated regression suite**

Run:

```bash
xcodebuild \
  -project Wattly.xcodeproj \
  -scheme Wattly \
  -destination 'platform=macOS' \
  test
```

Expected: all tests pass. The current baseline is 1,045 tests in 77 suites; an increased count from the new test is expected, but no existing test may disappear.

- [ ] **Step 8: Perform the live UI acceptance sequence**

Build and launch the exact Debug app:

```bash
xcodebuild \
  -project Wattly.xcodeproj \
  -scheme Wattly \
  -configuration Debug \
  -destination 'platform=macOS' \
  build

open /Users/hyunjun_macbook_pro/Library/Developer/Xcode/DerivedData/Wattly-hefcdlqggpybrlfpfhdbmmptcxqj/Build/Products/Debug/Wattly.app
```

With the adapter physically connected and battery percentage above the manual target:

1. Expand the battery card and confirm all three power-supply rows are visible.
2. Press `방전 시작` once and leave the adapter connected.
3. Wait at least 10 seconds, until battery power is negative and raw `ExternalConnected` has had time to flip.
4. Confirm the rows never collapse and read `배터리 강제 방전 중 ⚡`, `0.0 W (차단됨)`, and a nonempty system-consumption value.
5. Confirm `방전 중지` remains visible and usable.
6. Stop discharge and confirm the normal adapter presentation returns.
7. With no discharge active, physically unplug the adapter and confirm the three power-supply rows hide as before.

Expected: the original 28-second screen-recording failure no longer reproduces in either discharge cycle, while ordinary battery-only mode remains compact.

- [ ] **Step 9: Inspect and stage only this fix's hunks**

Run:

```bash
git diff --check -- \
  Wattly/Core/BatterySectionPresentation.swift \
  Wattly/Views/CardExpandRegion.swift \
  WattlyTests/BatterySectionPresentationTests.swift

git diff -- \
  Wattly/Core/BatterySectionPresentation.swift \
  Wattly/Views/CardExpandRegion.swift \
  WattlyTests/BatterySectionPresentationTests.swift

git add -p \
  Wattly/Core/BatterySectionPresentation.swift \
  Wattly/Views/CardExpandRegion.swift \
  WattlyTests/BatterySectionPresentationTests.swift

git diff --cached --check
git diff --cached
```

At each `git add -p` prompt, stage only:

- `shouldShowPowerSupplySection(...)`;
- the category-1 `CardExpandRegion` visibility block;
- `powerSupplyVisibilityUsesEffectiveAdapterStateDuringForcedDischarge`.

Leave the earlier `방전 시작` copy/color changes and all daemon/engine/helper changes unstaged. If Git combines changes into one hunk, use `s` to split it or `e` to edit the staged patch, then inspect the complete cached diff before committing.

- [ ] **Step 10: Commit the isolated fix**

Only after Step 9 proves the cached diff contains no pre-existing work, run:

```bash
git commit -m "fix(battery): keep power source rows during discharge"
```

Expected: one commit containing the pure visibility policy, its `CardExpandRegion` consumer, and the regression test only. If the hunks cannot be isolated safely, do not commit; report the staging blocker while leaving the working tree intact.

## Self-review

- Spec coverage: the plan covers the confirmed disappearance during two forced-discharge cycles, preserved normal battery-only hiding, missing-flow safety, forced-discharge copy, focused tests, full tests, and live acceptance.
- Placeholder scan: every code change, command, expected failure/pass, live action, staging boundary, and commit message is explicit; no deferred implementation language remains.
- Type consistency: `shouldShowPowerSupplySection` has the same parameter labels and types in the test, implementation, and `CardExpandRegion` call site.
- Scope boundary: no provider, daemon, helper, SMC, button, localization, accessibility, or telemetry behavior changes are included.
- Automatic review: skipped because this plan has exactly one implementation task.
