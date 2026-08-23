# Final review round 2 fix report

## Status

Complete. Both final re-review findings are addressed.

1. Charge-latch release probing is fail-closed. `BatteryControlKeyProbeResult` now separates
   confirmed absence, a readable key-info record, and uncertainty. The no-register proof is issued
   only after every latch key explicitly reports absence. Transport/SMC failures, invalid sizes,
   unexpected types, and an uncertain sibling latch return an unsafe release result instead.
   Normal runtime generation selection is unchanged.
2. Both helper replacement paths hold a root-owned `shlock` lock at
   `/var/run/Wattly/wattly-helper-install.lock` from the final elevated owner validation through
   release verification, bootout, helper/plist installation, bootstrap, and kickstart. The lock is
   non-blocking (exit 75 on contention), resides in a root-only writable directory, and is removed
   through an EXIT trap.

## TDD evidence

- Red: new no-latch and installer-lock assertions failed before the implementation.
- Red: the added regression with a valid `CHTE` plus an uncertain `CH0B` initially returned the
  valid candidate; the runtime probe was then changed to inspect all latch candidates and fail
  closed.
- Green: regressions cover all-confirmed-absent, transport uncertainty, unexpected size/type,
  preserved normal candidate selection, and a concurrent/stale-owner interleaving boundary in both
  installer sources.

## Verification

- Focused: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/BatteryControlKeysTests -only-testing:WattlyTests/BatteryControlClientTests -only-testing:WattlyTests/FanControlProtocolTests` — 68 tests in 3 suites passed.
- Full: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test` — 867 tests in 65 suites passed.
- Static: `zsh -n scripts/install-fan-helper.sh` and target-scoped `git diff --check` passed.

## Boundary and concerns

No root installer, launchd, or SMC operation was executed. The suite retains its existing
non-fatal `linkd.autoShortcut` test-host connection noise. Physical SMC and launchd behavior still
requires acceptance on a real Mac with explicit authorization.
