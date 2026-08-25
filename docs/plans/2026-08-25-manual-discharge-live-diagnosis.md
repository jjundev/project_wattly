# Manual Discharge Live Diagnosis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use diagnosing-bugs to execute this plan as one controlled live-hardware task. Do not edit production code until the evidence table identifies the cancellation boundary.

**Goal:** Determine why a single manual-discharge request disappears and reappears within seconds, while separating a false adapter-disconnect signal from client reconcile, heat protection, and helper restart.

**Architecture:** Treat the Mac as the system under test and collect one synchronized timeline from AppleSmartBattery, IOPS, SMC registers, Wattly UI state, and process identity. Compare a real unplug/replug baseline against a cable-untouched manual-discharge run, then repeat once with the app quit after the request to separate daemon behavior from client reconcile.

**Tech Stack:** macOS 26.6.2, M5 Mac17,2, `ioreg`, `pmset`, `scripts/probe-charge-registers.swift`, `launchctl`, `ps`, Wattly Debug app/helper.

## Global Constraints

- Use worktree `/Users/hyunjun_macbook_pro/.gemini/antigravity/worktrees/project_wattly/implement_manual_automatic_discharge` only.
- Do not edit source, defaults, the 69% target, the 90% charge limit, or the 32°C heat-protection threshold during diagnosis.
- Start only when battery temperature is stable in this Mac's observed 30–31°C baseline; abort at 31.5°C so the 32°C heat-protection policy cannot confound the result.
- Keep the Mac awake with the lid open and connect the charger directly, without a hub or dock.
- Never write SMC keys from a diagnostic command. Wattly is the only component allowed to change `CHTE` or `CHIE`.
- A physical unplug, target attainment, temperature abort, helper PID change, or unreadable SMC result ends the current run.
- At the end of every run, require `CHIE=0`; preserve the configured charge limit, which normally leaves `CHTE=1` at 90%.

---

### Task 1: Controlled live reproduction and cancellation-boundary isolation

**Files:**
- Read: `WattlyFanDaemon/FanControlDaemon.swift`
- Read: `FanControlShared/BatteryDaemonControlService.swift`
- Read: `FanControlShared/BatteryControlCoordinator.swift`
- Read: `FanControlShared/BatteryControlEngine.swift`
- Read: `scripts/probe-charge-registers.swift`
- Produce: `/tmp/wattly-manual-discharge-live.log` (disposable diagnostic artifact)

**Interfaces:**
- Consumes: one user click on `방전 시작`, one controlled physical unplug/replug sequence, AppleSmartBattery telemetry, SMC read-only probes.
- Produces: a timestamped verdict identifying daemon power detection, app reconcile, heat protection, or helper lifecycle as the first cancellation boundary.

- [x] **Step 1: Establish the cold, safe baseline**

User actions:

1. Keep the charger connected directly.
2. Keep the lid open.
3. Stop heavy workloads and wait until Codex reports a stable battery temperature between 30°C and 31°C.
4. Do not press any Wattly battery button yet.

Run:

```bash
pmset -g batt
ioreg -r -c AppleSmartBattery -l | rg '"(CurrentCapacity|ExternalConnected|AppleRawExternalConnected|IsCharging|Temperature)"'
swift scripts/probe-charge-registers.swift | rg 'CHTE  present|CHIE  present|B0AC  present'
launchctl print system/dev.jjundev.WattlyFanDaemon | rg 'state =|pid =|runs ='
```

Expected:

- `AC Power`, `ExternalConnected=Yes`, `AppleRawExternalConnected=Yes`.
- Battery 90%, target 69%, temperature below 3150 centi-Celsius.
- `CHTE=[01 00 00 00]`, `CHIE=[00]`, `B0AC` near zero.
- Helper state running with a stable PID.

- [x] **Step 2: Capture a real unplug/replug control timeline**

Start a 20-second read-only recorder. At Codex's first cue, the user unplugs the charger once. At the second cue, the user reconnects it once. The user does not touch Wattly.

Record once per second:

```bash
for second in {0..19}; do
  date '+%H:%M:%S'
  pmset -g batt | tail -n 1
  ioreg -r -c AppleSmartBattery -l | rg '"(ExternalConnected|AppleRawExternalConnected|IsCharging|Temperature)"'
  sleep 1
done | tee /tmp/wattly-manual-discharge-live.log
```

Expected: establish the exact ordering and recovery delay for a genuine cable transition. This is the control trace; do not interpret `ExternalConnected=No` during discharge until this trace exists.

- [x] **Step 3: Reproduce with the cable untouched**

Reconnect the charger and wait for the Step 1 baseline again. Start a 30-second recorder. At Codex's cue, the user presses `방전 시작` exactly once and then does nothing—no stop, unplug, slider movement, or settings navigation.

Record:

```bash
for second in {0..29}; do
  printf 't=%02d ' "$second"
  date '+%H:%M:%S'
  pmset -g batt | tail -n 1
  ioreg -r -c AppleSmartBattery -l | rg '"(ExternalConnected|AppleRawExternalConnected|IsCharging|Temperature)"'
  if (( second % 2 == 0 )); then
    swift scripts/probe-charge-registers.swift | rg 'CHTE  present|CHIE  present|B0AC  present'
  fi
  launchctl print system/dev.jjundev.WattlyFanDaemon | rg 'pid =' | head -n 1
  sleep 1
done | tee -a /tmp/wattly-manual-discharge-live.log
```

Abort immediately if temperature reaches 3150 centi-Celsius. Otherwise, expected bug signal is `CHIE 00 -> 08 -> 00`, accompanied by the discharge row disappearing. Record the first preceding signal change; do not infer causality from a later UI update.

- [x] **Step 4: Separate daemon cancellation from client reconcile**

Return to the Step 1 baseline. The user presses `방전 시작` once. After the first observed `CHIE=08`, Codex quits the Wattly app without stopping the helper and continues the same 30-second recorder.

Run after `CHIE=08`:

```bash
osascript -e 'tell application id "dev.jjundev.Wattly" to quit'
launchctl print system/dev.jjundev.WattlyFanDaemon | rg 'state =|pid =|runs ='
```

Verdict:

- `CHIE` still clears with the app absent: daemon power detection/coordinator is the cancellation boundary.
- `CHIE` remains `08` with the app absent: app reconcile is the cancellation boundary.
- `CHIE` clears only when temperature reaches 32°C: heat protection is working as designed, not this bug.
- Helper PID changes before `CHIE` clears: helper lifecycle/watchdog is the cancellation boundary.

- [x] **Step 5: Restore and report the safe end state**

Reopen the exact Debug app and verify the discharge register is released:

```bash
open /Users/hyunjun_macbook_pro/Library/Developer/Xcode/DerivedData/Wattly-hefcdlqggpybrlfpfhdbmmptcxqj/Build/Products/Debug/Wattly.app
swift scripts/probe-charge-registers.swift | rg 'CHTE  present|CHIE  present|B0AC  present'
pmset -g batt
```

Required final state: `CHIE=[00]`; helper running; app running; physical adapter state reported accurately. Summarize the first cancellation boundary with timestamps, then write a new failing automated regression test before any production fix.

## Execution evidence

- Pre-fix, cable untouched: `CHTE=1` and `CHIE=8` engaged at 15:40:07, then `CHIE=0` at 15:40:08 while temperature stayed 30.56–30.58°C and helper PID stayed 34289.
- Pre-fix, app absent: the app was closed immediately after `CHIE=8`; the helper still cleared `CHIE` with the same virtual adapter transition, proving the daemon/coordinator was the first cancellation boundary.
- Physical discriminator: during forced discharge, `ExternalConnected` and `AppleRawExternalConnected` became `No`, while AppleSmartBattery `AdapterDetails` retained `Watts=68` and `AdapterVoltage=20000`. `IOPSCopyExternalPowerAdapterDetails()` became nil and was rejected as the discriminator.
- Automated regression: `activeDischargeIgnoresVirtualDisconnectWhileAdapterDetailsRemain` failed before the adapter evidence API existed and passed after the fix.
- Post-fix, cable untouched: `CHTE=1`, `CHIE=8`, `AdapterDetails.Watts=68`, temperature 30.60°C, and helper PID 48515 remained stable for more than 35 seconds.
- Post-fix, real unplug: `AdapterDetails` disappeared at 15:53:52 and the helper restored `CHIE=0`, `CHTE=0` at 15:53:56.
- Automated verification: 127 related tests passed; the full suite passed 1,045 tests in 77 suites.

## Self-review

- Spec coverage: real unplug control, untouched-cable reproduction, app-versus-daemon isolation, temperature and PID confounders, and safe restoration are all covered.
- Placeholder scan: no deferred steps or unspecified commands remain.
- Type consistency: the plan uses existing `ExternalConnected`, `AppleRawExternalConnected`, `CHTE`, `CHIE`, `B0AC`, helper PID, and UI activity surfaces without proposing new production interfaces.
- Automatic review: skipped because this is exactly one diagnostic task.
