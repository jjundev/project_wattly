# Smart Power-Adaptive & 24/48/60 FPS Kinetic Notch Speed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a 4-tier Kinetic Notch speed model featuring **Smart Auto-Adaptive (AC 60fps / Battery 24fps / Low Power 15fps)** as default, alongside **Eco (24fps)**, **Standard (48fps)**, and **Responsive (60fps)**, fully decoupled from physical rotation speed (RPS).

**Architecture:** 
- Decouple physical rotation speed ($RPS$, driven solely by hardware load) from display refresh rate ($FPS$).
- `KineticNotchSpeed` enum expanded to `.smart`, `.eco`, `.standard`, `.responsive`.
- `resolveTargetFPS` dynamically evaluates `isACConnected` (from BatterySample/SystemMonitor) and `ProcessInfo.processInfo.isLowPowerModeEnabled`.
- Time-based continuous phase accumulator (`ContinuousClock` / `CACurrentMediaTime`) steps phase proportionally to true elapsed $\Delta t$.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest / Swift Testing framework.

## Global Constraints
- Target macOS 14.0+.
- All 455+ existing unit tests must pass without regressions.
- Physical rotation speed ($RPS$) remains identical across all modes for any given workload.

---

### Task 1: Core Domain Model & Unit Tests (`KineticNotchMotion.swift` & `KineticNotchMotionTests.swift`)

**Files:**
- Modify: `Wattly/Core/KineticNotchMotion.swift`
- Modify: `WattlyTests/KineticNotchMotionTests.swift`

**Interfaces:**
- `enum KineticNotchSpeed: String, CaseIterable, Identifiable, Sendable`
  - Cases: `smart`, `eco`, `standard`, `responsive`
  - `label`: "스마트", "절전", "표준", "민감"
  - `static func resolveTargetFPS(speed: KineticNotchSpeed, isACConnected: Bool, isLowPowerMode: Bool) -> Double`
    - `.smart`: `isLowPowerMode ? 15.0 : (isACConnected ? 60.0 : 24.0)`
    - `.eco`: `24.0`
    - `.standard`: `48.0`
    - `.responsive`: `60.0`
- `MenuBarIconMotion.effectiveFrameRate(load: Double, speed: KineticNotchSpeed, isACConnected: Bool = true, isLowPowerMode: Bool = false, frameCount: Int = 24) -> Double`

- [ ] **Step 1: Write failing unit tests in `KineticNotchMotionTests.swift`**
- [ ] **Step 2: Run test to verify failure**
- [ ] **Step 3: Implement domain logic in `KineticNotchMotion.swift`**
- [ ] **Step 4: Run test to verify success**
- [ ] **Step 5: Commit**

---

### Task 2: Settings Defaults & SettingsReset Integration

**Files:**
- Modify: `Wattly/Settings/Settings.swift`
- Modify: `Wattly/Core/SettingsReset.swift`
- Modify: `WattlyTests/SettingsResetTests.swift`

- [ ] **Step 1: Update `Settings.swift` default value (`Defaults.kineticNotchSpeed = .smart`)**
- [ ] **Step 2: Update `SettingsResetTests.swift`**
- [ ] **Step 3: Run test to verify**
- [ ] **Step 4: Commit**

---

### Task 3: MenuBar & Settings UI Layer Integration

**Files:**
- Modify: `Wattly/Views/MenuBarLabel.swift`
- Modify: `Wattly/Views/Settings/SettingsMenuBarSection.swift`

- [ ] **Step 1: Update `MenuBarLabel.swift` with AC and Low Power mode detection**
- [ ] **Step 2: Update `SettingsMenuBarSection.swift` with 4-way Segmented picker and smart mode live label**
- [ ] **Step 3: Run full test suite to verify regression-free build**
- [ ] **Step 4: Commit**
