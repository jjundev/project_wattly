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
