# Self-power baseline (issue 16)

Wattly's own measured power draw, recorded build-to-build so a regression (the monitor
becoming a battery hog) is caught — the PRD "a power tool that uses lots of power is a
contradiction" safeguard. This is a **manual spot-check**, not an automated CI gate:
`ri_energy_nj` needs real Apple-Silicon hardware under controlled load, which CI VM
runners can't provide, and the repo has no CI.

## Procedure

1. Build **Release**, launch, let it warm ~30 s on an otherwise-quiet machine.
2. Record the **settings-footer** "자체 소비 X.XX W" averaged over ~60 s in each state:
   - **OPEN** — popover open → 1 s cadence + popover rendering.
   - **CLOSED-default** — popover closed, menubar text ON → 2 s cadence (the shipped default).
   - **CLOSED-deep** — popover closed, menubar text OFF → 5 s cadence (deepest power save).
3. Expect **OPEN ≥ CLOSED-default ≥ CLOSED-deep** (monotone, *observational* — the
   always-rendered menubar label still polls + re-renders when closed, so the delta may be
   small or within noise; record the numbers, don't gate pass/fail on a strict inequality).
4. **Regression flag**: a later build whose 3-run average is **> baseline × 1.2** for any
   state warrants investigation.

## Recorded baselines

| Date | Commit | Machine / macOS | OPEN (1 s) | CLOSED-default (2 s) | CLOSED-deep (5 s) | Notes |
|------|--------|-----------------|-----------:|---------------------:|------------------:|-------|
| _TBD_ | _TBD_ | M-series / 26.5.1 | _–_ | _–_ | _–_ | first measurement pending a Release run |

> Fill a row per release. Values are watts (footer 2-decimal). If a state reads "0.00 W"
> that's a genuine sub-10 mW result, not a bug.
