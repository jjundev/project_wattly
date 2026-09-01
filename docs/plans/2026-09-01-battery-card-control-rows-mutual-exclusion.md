# Battery Card Control Rows Mutual Exclusion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In the expanded Battery card, display only the active control row when either "One-Time Top-Up" or "Manual Discharge" is active, and display both rows (subject to standard settings and SoC criteria) when both are inactive.

**Architecture:** Update pure presentation functions in `BatterySectionPresentation` (`shouldShowTopUpRow`, `shouldShowManualDischargeRow`) to accept the opposite mode's active state (`isDischargeActive`, `isTopUpActive`). Ensure safety overrides always allow canceling an active mode, hide the inactive mode when one mode is active, and show both when idle or in dual-active emergency fallback. Wire the updated arguments into `CardExpandRegion`.

**Tech Stack:** Swift 6.0, SwiftUI, Swift Testing (`import Testing`), macOS 14.0+ on Apple Silicon.

## Global Constraints

- Swift 6 language mode with complete concurrency checking (`SWIFT_VERSION: "6.0"`).
- Target platform: macOS 14.0+ on Apple Silicon (arm64).
- Ad-hoc code signing (`CODE_SIGN_IDENTITY: "-"`).
- Pure logic must be separated from SwiftUI views in `BatterySectionPresentation` and covered with unit tests in `BatterySectionPresentationTests` using Swift Testing (`#expect`).
- Existing Settings views (`SettingsDisplaySection`, `SettingsBatterySection`, `SettingsBatteryDischargeSection`) must remain completely unaffected.

---

### Task 1: Update presentation logic and test suite in `BatterySectionPresentation`

**Files:**
- Modify: `Wattly/Core/BatterySectionPresentation.swift:642-663`
- Modify: `Wattly/Views/CardExpandRegion.swift:355-365`
- Test: `WattlyTests/BatterySectionPresentationTests.swift:883-930`

**Interfaces:**
- Produces:
  - `BatterySectionPresentation.shouldShowTopUpRow(showSetting: Bool, isTopUpActive: Bool, isDischargeActive: Bool) -> Bool`
  - `BatterySectionPresentation.shouldShowManualDischargeRow(showSetting: Bool, isDischarging: Bool, isTopUpActive: Bool, currentSoC: Int, targetSoC: Int) -> Bool`

- [ ] **Step 1: Update unit tests in `BatterySectionPresentationTests.swift` with failing expectations**

Replace existing `topUpRowVisibilityPolicy` and `manualDischargeRowVisibilityPolicy` and add `batteryControlRowsMutualExclusionPolicy`:

```swift
    @Test func topUpRowVisibilityPolicy() {
        // Setting ON + Top-up Inactive + Discharge Inactive -> Shown
        #expect(BatterySectionPresentation.shouldShowTopUpRow(showSetting: true, isTopUpActive: false, isDischargeActive: false))
        // Setting OFF + Top-up Inactive + Discharge Inactive -> Hidden
        #expect(!BatterySectionPresentation.shouldShowTopUpRow(showSetting: false, isTopUpActive: false, isDischargeActive: false))
        // Setting OFF + Top-up Active + Discharge Inactive -> Shown (Safety override)
        #expect(BatterySectionPresentation.shouldShowTopUpRow(showSetting: false, isTopUpActive: true, isDischargeActive: false))
        // Setting ON + Top-up Active + Discharge Inactive -> Shown
        #expect(BatterySectionPresentation.shouldShowTopUpRow(showSetting: true, isTopUpActive: true, isDischargeActive: false))
        // Discharge Active + Top-up Inactive -> Hidden (Mutual exclusion)
        #expect(!BatterySectionPresentation.shouldShowTopUpRow(showSetting: true, isTopUpActive: false, isDischargeActive: true))
        // Dual active (abnormal edge case) -> Shown (Emergency fallback)
        #expect(BatterySectionPresentation.shouldShowTopUpRow(showSetting: false, isTopUpActive: true, isDischargeActive: true))
    }

    @Test func manualDischargeRowVisibilityPolicy() {
        // Setting ON, SoC 90 > target 80, not discharging, top-up inactive -> Shown
        #expect(BatterySectionPresentation.shouldShowManualDischargeRow(
            showSetting: true,
            isDischarging: false,
            isTopUpActive: false,
            currentSoC: 90,
            targetSoC: 80
        ))

        // Setting ON, SoC 70 <= target 80, not discharging, top-up inactive -> Hidden (SoC below target)
        #expect(!BatterySectionPresentation.shouldShowManualDischargeRow(
            showSetting: true,
            isDischarging: false,
            isTopUpActive: false,
            currentSoC: 70,
            targetSoC: 80
        ))

        // Setting OFF, not discharging, top-up inactive -> Hidden even if SoC > target
        #expect(!BatterySectionPresentation.shouldShowManualDischargeRow(
            showSetting: false,
            isDischarging: false,
            isTopUpActive: false,
            currentSoC: 90,
            targetSoC: 80
        ))

        // Setting OFF, actively discharging, top-up inactive -> Shown (Safety override)
        #expect(BatterySectionPresentation.shouldShowManualDischargeRow(
            showSetting: false,
            isDischarging: true,
            isTopUpActive: false,
            currentSoC: 70,
            targetSoC: 80
        ))

        // Top-up active, discharge inactive -> Hidden (Mutual exclusion even if setting ON and SoC > target)
        #expect(!BatterySectionPresentation.shouldShowManualDischargeRow(
            showSetting: true,
            isDischarging: false,
            isTopUpActive: true,
            currentSoC: 90,
            targetSoC: 80
        ))

        // Dual active (abnormal edge case) -> Shown (Emergency fallback to allow stopping)
        #expect(BatterySectionPresentation.shouldShowManualDischargeRow(
            showSetting: false,
            isDischarging: true,
            isTopUpActive: true,
            currentSoC: 70,
            targetSoC: 80
        ))
    }

    @Test func batteryControlRowsMutualExclusionPolicy() {
        // Case 1: Top-up active -> Top-up shown, Discharge hidden
        let topUp1 = BatterySectionPresentation.shouldShowTopUpRow(showSetting: true, isTopUpActive: true, isDischargeActive: false)
        let discharge1 = BatterySectionPresentation.shouldShowManualDischargeRow(showSetting: true, isDischarging: false, isTopUpActive: true, currentSoC: 90, targetSoC: 80)
        #expect(topUp1 == true)
        #expect(discharge1 == false)

        // Case 2: Discharge active -> Top-up hidden, Discharge shown
        let topUp2 = BatterySectionPresentation.shouldShowTopUpRow(showSetting: true, isTopUpActive: false, isDischargeActive: true)
        let discharge2 = BatterySectionPresentation.shouldShowManualDischargeRow(showSetting: true, isDischarging: true, isTopUpActive: false, currentSoC: 90, targetSoC: 80)
        #expect(topUp2 == false)
        #expect(discharge2 == true)

        // Case 3: Both inactive, both settings ON, SoC > target -> Both shown
        let topUp3 = BatterySectionPresentation.shouldShowTopUpRow(showSetting: true, isTopUpActive: false, isDischargeActive: false)
        let discharge3 = BatterySectionPresentation.shouldShowManualDischargeRow(showSetting: true, isDischarging: false, isTopUpActive: false, currentSoC: 90, targetSoC: 80)
        #expect(topUp3 == true)
        #expect(discharge3 == true)

        // Case 4: Both inactive, both settings ON, SoC <= target -> Top-up shown, Discharge hidden
        let topUp4 = BatterySectionPresentation.shouldShowTopUpRow(showSetting: true, isTopUpActive: false, isDischargeActive: false)
        let discharge4 = BatterySectionPresentation.shouldShowManualDischargeRow(showSetting: true, isDischarging: false, isTopUpActive: false, currentSoC: 70, targetSoC: 80)
        #expect(topUp4 == true)
        #expect(discharge4 == false)

        // Case 5: Both active (edge case) -> Both shown (Safety override)
        let topUp5 = BatterySectionPresentation.shouldShowTopUpRow(showSetting: false, isTopUpActive: true, isDischargeActive: true)
        let discharge5 = BatterySectionPresentation.shouldShowManualDischargeRow(showSetting: false, isDischarging: true, isTopUpActive: true, currentSoC: 70, targetSoC: 80)
        #expect(topUp5 == true)
        #expect(discharge5 == true)
    }
```

- [ ] **Step 2: Run tests to verify compilation / test failure**

Run: `xcodebuild -scheme Wattly -configuration Debug -derivedDataPath /tmp/WattlyDerivedData -only-testing:WattlyTests/BatterySectionPresentationTests test`
Expected: Compilation failure due to missing arguments in `shouldShowTopUpRow` and `shouldShowManualDischargeRow`.

- [ ] **Step 3: Update `BatterySectionPresentation.swift` implementation**

In `Wattly/Core/BatterySectionPresentation.swift` lines 642–663:

```swift
    /// Determines whether the "한 번만 완충 (Top-Up)" row should be visible in the expanded battery card.
    /// Returns true if top-up is active (safety override), false if discharge is active (mutual exclusion),
    /// or user setting if both are idle.
    static func shouldShowTopUpRow(
        showSetting: Bool,
        isTopUpActive: Bool,
        isDischargeActive: Bool
    ) -> Bool {
        if isTopUpActive { return true }
        if isDischargeActive { return false }
        return showSetting
    }

    /// Determines whether the "수동 방전 (Manual Discharge)" row should be visible in the expanded battery card.
    /// Returns true if currently discharging (safety override), false if top-up is active (mutual exclusion),
    /// or if enabled by settings and current SoC exceeds target when idle.
    static func shouldShowManualDischargeRow(
        showSetting: Bool,
        isDischarging: Bool,
        isTopUpActive: Bool,
        currentSoC: Int,
        targetSoC: Int
    ) -> Bool {
        if isDischarging { return true }
        if isTopUpActive { return false }
        guard showSetting else { return false }
        return currentSoC > targetSoC
    }
```

- [ ] **Step 4: Update `CardExpandRegion.swift` invocation (to satisfy whole-project build during test run)**

In `Wattly/Views/CardExpandRegion.swift` lines 355–365:

```swift
                let willShowTopUp = BatterySectionPresentation.shouldShowTopUpRow(
                    showSetting: showBatteryTopUp,
                    isTopUpActive: isTopUpActive,
                    isDischargeActive: isDischargeActive
                )
                let willShowDischarge = BatterySectionPresentation.shouldShowManualDischargeRow(
                    showSetting: showBatteryManualDischarge,
                    isDischarging: isDischargeActive,
                    isTopUpActive: isTopUpActive,
                    currentSoC: currentSoC,
                    targetSoC: dischargeTarget
                )
```

- [ ] **Step 5: Run tests to verify all tests pass**

Run: `xcodebuild -scheme Wattly -configuration Debug -derivedDataPath /tmp/WattlyDerivedData -only-testing:WattlyTests/BatterySectionPresentationTests test`
Expected: PASS (all tests pass).

- [ ] **Step 6: Commit**

```bash
git add Wattly/Core/BatterySectionPresentation.swift Wattly/Views/CardExpandRegion.swift WattlyTests/BatterySectionPresentationTests.swift
git commit -m "feat(battery): mutual exclusion for top-up and manual discharge rows in expanded battery card"
```

---

### Task 2: Verify whole project build and integration

**Files:**
- Test: `WattlyTests` (entire test suite)

**Interfaces:**
- Consumes:
  - `BatterySectionPresentation.shouldShowTopUpRow`
  - `BatterySectionPresentation.shouldShowManualDischargeRow`

- [ ] **Step 1: Run full test suite**

Run: `xcodebuild test -scheme Wattly -configuration Debug -derivedDataPath /tmp/WattlyDerivedData`
Expected: PASS (all unit and integration tests pass).

- [ ] **Step 2: Verify no warnings or regressions**

Run: `xcodebuild build -scheme Wattly -configuration Debug -derivedDataPath /tmp/WattlyDerivedData`
Expected: BUILD SUCCEEDED with 0 warnings.
