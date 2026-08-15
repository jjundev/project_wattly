# Immediate Tick on Fan Curve Change Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the fan response latency and zero-RPM hold stall when changing fan curves (e.g., switching from "저소음" to "최대" mode) by triggering an immediate hardware tick during live curve reconfiguration.

**Architecture:** In `FanControlEngine.configureAccepted`, when an updated configuration is accepted while control is actively engaged (`controlled` is non-empty), immediately invoke `try tick(now: now)` instead of waiting for the next timer tick (0.5s) or control interval cooldown. This evaluates the new curve against current CPU temperature, updates `zeroRPMFans` state, and writes the new target RPM directly to SMC hardware.

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing (`@Test`, `#expect`), SMC fan control engine.

## Global Constraints

- Target macOS 14.0+ on Apple Silicon with Swift 6 strict concurrency complete mode.
- Maintain full test coverage across `WattlyTests/FanControlEngineTests.swift`.
- No changes to public API or XPC protocol signatures.
- Clean separation between `FanControlShared`, `Wattly`, and `WattlyFanDaemon`.
- Final test command: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test`

---

### Task 1: Add Unit Tests for Immediate Target RPM Write on Curve Reconfiguration

**Files:**
- Modify: `WattlyTests/FanControlEngineTests.swift`

**Interfaces:**
- Consumes: `FanControlEngine.configure(_:now:)`, `FanControlEngine.configure(_:clientGeneration:now:)`, `FanCurvePreset.silent`, `FanCurvePreset.fullSpeed`
- Produces: Verified unit tests for immediate SMC write on live curve change and zero-RPM exit transition.

- [ ] **Step 1: Write failing unit test for immediate tick on curve reconfiguration**

Add `reconfigureFromZeroRPMHoldToFullSpeedImmediatelyWritesMaxRPM` and verify `reconfigureWhileControllingAdoptsTheNewCurve` in `WattlyTests/FanControlEngineTests.swift`:

```swift
    @Test func reconfigureFromZeroRPMHoldToFullSpeedImmediatelyWritesMaxRPM() throws {
        let hw = FakeFanControlHardware(modeKey: "F0md", hasFtst: false, hottestCPU: 50,
                                        limits: FanLimits(minimum: 2000, maximum: 6500))
        let engine = FanControlEngine(hardware: hw)
        let silent = FanCurvePreset.silent.curve(forMaxRPM: 6500)
        let fullSpeed = FanCurvePreset.fullSpeed.curve(forMaxRPM: 6500)

        // Initial configure + tick under silent mode at 50°C enters zero-RPM hold (target 0)
        try engine.configure(.init(enabled: true, curve: silent), now: 0)
        try engine.tick(now: 0)
        #expect(hw.writes.last == .target(0, 0))

        // Reconfigure to full speed must immediately evaluate and write 6500 without waiting for a subsequent tick
        try engine.configure(.init(enabled: true, curve: fullSpeed), now: 1)
        #expect(hw.writes.last == .target(0, 6500))
        #expect(engine.status.mode == .controlling)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test`
Expected: FAIL on `reconfigureFromZeroRPMHoldToFullSpeedImmediatelyWritesMaxRPM` (because `configure` does not write target RPM immediately without a separate `tick`).

---

### Task 2: Implement Immediate Tick in `FanControlEngine.configureAccepted`

**Files:**
- Modify: `FanControlShared/FanControlEngine.swift:82-105`

**Interfaces:**
- Consumes: `FanControlEngine.tick(now:)`, `FanControlConfiguration`
- Produces: `FanControlEngine.configureAccepted(_:now:) throws` invoking immediate `tick` on live curve updates.

- [ ] **Step 1: Update `configureAccepted` to execute `try tick(now: now)` on live reconfiguration**

In `FanControlShared/FanControlEngine.swift`:

```swift
    private func configureAccepted(_ configuration: FanControlConfiguration, now: TimeInterval) throws {
        configurationGeneration &+= 1
        pendingManual.removeAll()
        engagementGeneration = nil
        nextTargetUpdateAt = nil

        guard configuration.enabled else {
            releaseAccepted(now: now, reason: "control disabled")
            return
        }

        // Live update while already controlling (e.g. an edited fan curve): swap the configuration
        // in place, keep control engaged, and immediately evaluate/write the new target RPM without
        // waiting for the next timer tick.
        if self.configuration != nil, !controlled.isEmpty {
            self.configuration = configuration
            lastHeartbeat = now
            try tick(now: now)
            return
        }

        // Otherwise fans must be in a clean state before a fresh engagement: any still owned from a
        // prior session are mid automatic-mode recovery, so defer until that completes.
        guard controlled.isEmpty else {
            status = .init(mode: .failed, detail: "automatic-mode recovery pending", updatedAt: now)
            return
        }

        self.configuration = configuration
        lastHeartbeat = now
        status = .init(mode: .engaging, detail: "waiting to engage fan control", updatedAt: now)
    }
```

Also ensure both `configure(_:now:)` and `configure(_:clientGeneration:now:)` forward `try configureAccepted(...)`.

- [ ] **Step 2: Run tests to verify all tests pass**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test`
Expected: PASS (** TEST SUCCEEDED **)

- [ ] **Step 3: Commit changes**

```bash
git add FanControlShared/FanControlEngine.swift WattlyTests/FanControlEngineTests.swift
git commit -m "fix(fan): trigger immediate tick on fan curve reconfiguration"
```

---

## Verification Plan

### Automated Tests
- Run complete test suite:
  ```bash
  xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
  ```
  Verify all existing fan engine, preset, and policy tests pass alongside the new test.

### Manual Verification
1. Launch `Wattly.app` on Apple Silicon hardware with active fan control.
2. In Settings -> 팬 커브, select "저소음" mode while CPU temperature is in the 48°C~55°C range (fan should be stopped at 0 RPM).
3. Switch preset to "최대" mode.
4. Verify the fan starts spinning immediately without remaining stalled in 0 RPM hold.
