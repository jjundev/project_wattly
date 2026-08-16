# Hybrid Precision Motion Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate micro-stuttering and uneven frame pacing in dynamic menu bar icons by implementing a **Hybrid Precision Motion Engine** combining:
1. Physical rotational inertia (Exponential Damping EMA filter on RPS).
2. True inter-frame precision scheduling ($\Delta T = 1.0 / (\text{RPS} \times 24)$) to ensure 100% mathematically uniform frame intervals without beat artifacts.
3. Selective `@State` updates (only refreshing SwiftUI when discrete sprite frame index actually advances), cutting render overhead by >80%.

**Architecture:**
- `MenuBarIconMotion.smoothedRPS(currentRPS:targetRPS:dt:tau:)`: 1st-order exponential lag filter with time constant $\tau = 0.25\text{s}$, giving analog turbine weight.
- `MenuBarIconMotion.interFrameDelay(...)`: Computes exact inter-frame duration needed for the next discrete sprite transition, bounded by preset max refresh rates.
- `MenuBarLabel` and `SettingsMenuBarSection`: Internalize continuous phase to local loop state and only publish `@State var displayedFrame: Int` on true frame transitions.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest / Swift Testing framework.

## Global Constraints
- Target macOS 14.0+.
- All 455+ unit tests must pass.
- Physical rotation speed ($RPS$) remains $0.25 \sim 2.50\text{ RPS}$ bound to workload.

---

### Task 1: Core Precision Scheduling & Inertia Model (`KineticNotchMotion.swift` & Tests)

**Files:**
- Modify: `Wattly/Core/KineticNotchMotion.swift`
- Modify: `WattlyTests/KineticNotchMotionTests.swift`

- [ ] **Step 1: Write unit tests in `KineticNotchMotionTests.swift`**
- [ ] **Step 2: Implement domain functions in `KineticNotchMotion.swift`**
- [ ] **Step 3: Run unit tests**
- [ ] **Step 4: Commit**

---

### Task 2: UI View Layer State Optimization & Even-Paced Game Loop

**Files:**
- Modify: `Wattly/Views/MenuBarLabel.swift`
- Modify: `Wattly/Views/Settings/SettingsMenuBarSection.swift`

- [ ] **Step 1: Update `MenuBarLabel.swift`**
- [ ] **Step 2: Update `SettingsMenuBarSection.swift`**
- [ ] **Step 3: Run full regression test suite**
- [ ] **Step 4: Build & Launch Wattly App**
- [ ] **Step 5: Commit**
