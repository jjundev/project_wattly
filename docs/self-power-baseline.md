# Self-power baseline (issue 16)

Wattly's own measured power draw, recorded build-to-build so a regression (the monitor
becoming a battery hog) is caught — the PRD "a power tool that uses lots of power is a
contradiction" safeguard. This is a **manual spot-check**, not an automated CI gate:
`ri_energy_nj` needs real Apple-Silicon hardware under controlled load, which CI VM
runners can't provide, and the repo has no CI.

## Procedure

1. Build **Release**, launch, and warm for 60 seconds on an otherwise-quiet Apple-Silicon Mac.
2. In each state, wait for one 30-second self-energy refresh, then record the value after a full 60-second observation window:
   - **OPEN** — CPU/SoC power 1s, temperature 2s, memory/battery 5s.
   - **CLOSED-menu** — popover closed, menu-bar CPU text on; only selected menu-bar providers update at 2s.
   - **CLOSED-idle** — popover closed, menu-bar text off; metric providers stop and only the 30-second self-energy sample wakes Wattly.
3. Record three runs per state and put their arithmetic mean in the table. Include commit, Mac model, macOS build, power source, and selected menu metrics in Notes.
4. Expected ordering is **OPEN ≥ CLOSED-menu ≥ CLOSED-idle**. It is observational because ri_energy_nj excludes WindowServer composition.
5. A matching-state three-run mean above prior baseline ×1.2 is a regression. The first post-change row must retain the pre-change row and have CLOSED-menu/CLOSED-idle no higher than their pre-change counterparts.

## Recorded baselines

| Date | Commit | Machine / macOS | OPEN | CLOSED-menu | CLOSED-idle | Notes |
|------|--------|-----------------|-----:|------------:|-------------:|-------|
| _TBD_ | _TBD_ | M-series / 26.5.1 | _–_ | _–_ | _–_ | first measurement pending a Release run |

> Fill a row per release. Values are 30-second process-energy averages in watts (footer 2-decimal). If a state reads "0.00 W"
> that's a genuine sub-10 mW result, not a bug.

## Controlled processor-power expansion A/B

Use a Release build on one Apple-Silicon Mac. Keep the power source, Low Power Mode,
menu-bar icon style/motion/speed, visible cards, panel mode, process-list limit, and
foreground apps unchanged for the whole comparison. Close Wattly Settings because its
animated icon preview is a separate renderer. Leave the popover open in Mode A and wait
60 seconds after launch before measuring.

1. Build and launch the exact commit being measured.
2. Find the Release PID with `pgrep -x Wattly` and confirm its binary path with
   `ps -p "$WATTLY_PID" -o command=`.
3. Collapse the processor-power card, wait 10 seconds, then run three consecutive
   60-second samples:
   `swift scripts/measure-process-energy.swift "$WATTLY_PID" 60 3`.
4. Expand only the processor-power card, wait until app rows appear, wait another
   10 seconds, then run the same command.
5. Compute `expansion delta = expanded mean - collapsed mean`.
6. Repeat all five steps after the optimization on the same Mac and settings.

The optimization passes when it preserves one-second processor-power polling and:

- if the pre-change expansion delta is at least 0.03 W, the post-change delta is no
  more than 80% of the pre-change delta;
- if the pre-change expansion delta is below 0.03 W, the post-change delta remains
  at or below 0.03 W because the reported 0.2–0.3 W expansion symptom did not reproduce.

## Recorded expanded-card comparisons

Each comparison records the exact date, commit, Mac model, macOS build, power source,
motion settings, collapsed runs and mean, expanded runs and mean, computed delta, and
pass/fail verdict. Do not add a comparison until all six runs were captured under the
controlled protocol above.

### Baseline (before optimization)

- **Date:** 2026-08-25
- **Commit:** `02503a0bcf8fee1b51c5302c2bed3c666002c2e3`
- **Machine / macOS:** Mac17,2 / macOS 26.6.2 (Build 25G83)
- **Power source:** AC Power (90%, AC attached)
- **Settings:** Mode A, pollInterval=auto (Eco), powerProcessLimit=7, menubarIconStyle=sailboat, kineticNotchMotionEnabled=1, menubarTextEnabled=0, Wattly Settings closed
- **Collapsed runs (60s):**
  - Run 1: `0.018676 W`
  - Run 2: `0.013844 W`
  - Run 3: `0.013438 W`
  - **Collapsed mean:** `0.015319 W`
- **Expanded runs (60s):**
  - Run 1: `0.013949 W`
  - Run 2: `0.013784 W`
  - Run 3: `0.019414 W`
  - **Expanded mean:** `0.015716 W`
- **Expansion delta:** `+0.000397 W` (`0.015716 - 0.015319`)

### Optimized (after caching process row views)

- **Date:** 2026-08-25
- **Commit:** `0b9195a0ab384030760515a4cfcc8ef497755bbb`
- **Machine / macOS:** Mac17,2 / macOS 26.6.2 (Build 25G83)
- **Power source:** AC Power (90%, AC attached)
- **Settings:** Mode A, pollInterval=auto (Eco), powerProcessLimit=7, menubarIconStyle=sailboat, kineticNotchMotionEnabled=1, menubarTextEnabled=0, Wattly Settings closed
- **Collapsed runs (60s):**
  - Run 1: `0.019095 W`
  - Run 2: `0.019210 W`
  - Run 3: `0.018904 W`
  - **Collapsed mean:** `0.019070 W`
- **Expanded runs (60s):**
  - Run 1: `0.019287 W`
  - Run 2: `0.019068 W`
  - Run 3: `0.019239 W`
  - **Expanded mean:** `0.019198 W`
- **Expansion delta:** `+0.000128 W` (`0.019198 - 0.019070`)
- **Delta reduction vs pre-change:** `67.76%` reduction (`(0.000397 - 0.000128) / 0.000397 = 67.76%`)
- **Acceptance gate:** `PASS` (pre-delta < 0.03 W, post-delta 0.000128 W <= 0.03 W)
