# Task 2 Scope Correction Report

## Implementation

Removed only the unreachable synthetic `remainingWh: 49.5` and
`timeRemainingMinutes: net > 0.05 ? 210 : nil` arguments from the battery
`BatterySample` in `FakeProvider`. The argument list now ends with
`externalConnected: charging`, as it did before Task 2. No live
`BatteryProvider`, monitor, model, presentation, view, or test code changed.

## Verification

Exact command run:

```sh
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
```

Result (exit status 0):

```text
✔ Test run with 341 tests in 29 suites passed after 0.230 seconds.
** TEST SUCCEEDED **
```

The complete `xcodebuild` console output also reported the expected existing
headermap deprecation warning for the `Wattly` target; there were no test
failures.

## Files Changed

- `Wattly/Providers/FakeProvider.swift` — removed the two unused fake telemetry
  arguments.
- `.agents/sdd/task-2-scope-correction-report.md` — this report.

## Self-Review

- Confirmed the source diff is restricted to the two requested arguments.
- Ran `git diff --check` successfully.
- Confirmed the full test suite passes, including
  `batteryDisplaySmoothingDampsAndResetsOnPlug` discovered by the full suite.

## Concerns

None for this correction. A pre-existing untracked plan file,
`docs/plans/2026-07-29-battery-remaining-capacity-and-time.md`, was left
unchanged and will not be included in the commit.
