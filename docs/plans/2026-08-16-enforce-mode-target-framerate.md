# Enforce Mode Target Frame Rate in Kinetic Notch Motion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure dynamic menu bar icon animations always render smoothly at their mode-specific target frame rate (e.g. 60 fps on AC / 24 fps on Battery), eliminating the 10 fps visual judder during idle (0~5% load), while maintaining exact physical rotation speed (RPS).

**Architecture:**
- Simplify `MenuBarIconMotion.effectiveFrameRate` to directly return `KineticNotchSpeed.resolveTargetFPS(speed:isACConnected:isLowPowerMode:)`, removing the dynamic down-throttling that capped FPS to ~10 fps during low RPS.
- Continuous phase accumulation (`advancePhase`) precisely integrates phase with true elapsed time ($\Delta t = 1.0 / \text{targetFPS}$), so slow physical rotations (0.25~0.40 RPS) sample smooth sub-pixel/sub-frame steps without judder.

**Tech Stack:** Swift 6, SwiftUI, XCTest / Swift Testing framework.

## Global Constraints
- Target macOS 14.0+.
- All 455+ unit tests must pass.
- Physical rotation speed ($RPS$) remains $0.25 \sim 2.50\text{ RPS}$ bound to workload.

---

### Task 1: Update Core Frame Rate Resolution & Unit Tests

**Files:**
- Modify: `Wattly/Core/KineticNotchMotion.swift`
- Modify: `WattlyTests/KineticNotchMotionTests.swift`

- [ ] **Step 1: Update unit tests in `KineticNotchMotionTests.swift`**
- [ ] **Step 2: Update `KineticNotchMotion.swift`**
- [ ] **Step 3: Run unit tests**
- [ ] **Step 4: Commit**

---

### Task 2: Verify UI Layer and App Build

- [ ] **Step 1: Run full regression test suite**
- [ ] **Step 2: Build & Launch Wattly App to permanent `./build` path**
- [ ] **Step 3: Verify live UI & motion smoothness**
