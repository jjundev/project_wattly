# Battery Charge Limit — Unsupported-Hardware UI Follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the settings screen from polling a Mac whose answer can never change, and give the user a way out of a charge-limit toggle that is stuck reading ON while disabled.

**Architecture:** Both defects live in one pure decision function each, in `Wattly/Core/BatterySectionPresentation.swift`, consumed by exactly one view (`Wattly/Views/Settings/SettingsBatterySection.swift`). The daemon, the engine, the register table and `FanControlShared` are not touched at all. Each task adds one input to a pure function, updates its single call site, and is fully covered by `WattlyTests/BatterySectionPresentationTests.swift` — no UI test, no XPC, no hardware.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`import Testing`), xcodegen, `@AppStorage`.

## Why this plan exists

Two independent verification agents reviewed the `.firmwareManaged` change on 2026-08-23. Both defects below are theirs, restated with the code confirmed:

1. **A poll that never ends.** `BatterySectionPresentation.shouldPollStatus` (`Wattly/Core/BatterySectionPresentation.swift:121-127`) returns `true` whenever the limit is on, and also whenever the mode is `.unsupported` — without ever consulting `isHardwareSupported`. On a Mac the helper has declared permanently incapable, the settings `.task` loop (`Wattly/Views/Settings/SettingsBatterySection.swift:73-92`) therefore runs forever at `BatteryControlPolicy.statusPollInterval` (5 s), each iteration a `batteryStatus` XPC round trip that makes the root daemon take a full `IOPSCopyPowerSourcesInfo` snapshot — to refresh `batteryStatusIndicator`, which `areDetailsVisible == false` has already removed from the view tree. No SMC writes, so it is waste rather than danger.

2. **A toggle stuck in the ON position.** `isEnabled: !isHardwareUnsupported` (`Wattly/Views/Settings/SettingsBatterySection.swift:29`) disables the toggle whenever the helper answers `isHardwareSupported == false`, *including* when the stored `batteryLimitEnabled` is already `true`. The existing recovery — clearing the opt-in at `:118-120` — fires only inside `.onChange(of: batteryLimitEnabled)`, i.e. only when the user flips the toggle, which a disabled toggle cannot do. A stored `true` that predates the answer therefore has no exit but a global Settings Reset.

   This became reachable with the `.firmwareManaged` case: registers do not vanish from a Mac, but *firmware ownership arrives* — the whole premise recorded in `FanControlShared/BatteryControlKeys.swift:3-16` is that the generation moves under a machine that never changed. A user with the limit working today gets this state from a macOS update.

### The mechanism for #2, and why it is not "clear the stored value"

The obvious fix — have the app switch `batteryLimitEnabled` off when the hardware turns out to be incapable — is **explicitly rejected by this codebase already**, at `Wattly/Views/Settings/SettingsBatterySection.swift:21-26`:

> Rendering never writes the stored value: flipping it off here would look like the app undoing the user's choice, and it would be wrong the moment the same preferences reach a Mac that does support the limit.

That reasoning still holds, so this plan does not overturn it. It fixes the same defect from the other side: **the toggle stays interactive while it reads ON, so the user can switch it off themselves.** Turning it on remains impossible on incapable hardware, so the escape hatch is one-way. Nothing writes preferences on the user's behalf, no new user-facing string is introduced, and the file-top comment stays true.

## Global Constraints

- Swift 6 language mode, deployment target macOS 14.0.
- Tests are Swift Testing (`import Testing`, `@Test`, `#expect`) — **not** XCTest.
- All new logic must be a pure function in `Wattly/Core/BatterySectionPresentation.swift`, called from the view. Logic that lives inside a SwiftUI `body` is unreachable from `WattlyTests` and does not count as covered.
- **No new user-facing strings.** `Wattly/Resources/Localizable.xcstrings` carries 30 languages and every key must be translated in all of them; this plan reuses strings that already exist there. If a step seems to need new copy, stop and report instead of adding a key.
- `nil` is not `false`. `isHardwareSupported` is `Bool?` — `nil` means "the helper has not answered, or is too old to say", and a Mac must never be declared incapable on a missing answer (`Wattly/Core/BatterySectionPresentation.swift:30-36`, `Wattly/Views/Settings/SettingsBatterySection.swift:192-196`).
- No new files, so **no `xcodegen` run and no `project.pbxproj` change should appear in any commit** in this plan.
- Full gate for every task, run from the repo root:
  ```
  xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath "$DD"
  ```
  **`-derivedDataPath` is mandatory in this worktree.** With the default DerivedData location the build fails at the asset-catalog step with `actool: You don't have permission to save the file "assetcatalog_dependencies_thinned"`, even after wiping DerivedData. Export it once per shell:
  ```
  export DD=/private/tmp/claude-501/-Users-hyunjun-macbook-pro-Documents-Project-project-wattly--claude-worktrees-battery-charge-limit-m5-macbook-fdabbc/d2f24b4d-1fdd-4125-a7cd-08506042d995/scratchpad/dd
  ```
- Baseline before Task 1: **686 tests / 60 suites, green.** Task 1 adds 3 tests (→ 689); Task 2 adds 1 test (→ 690).
- The working tree already contains uncommitted `.firmwareManaged` work. Commit only the files each step names — never `git add -A`.

## Out of Scope

- Any distinct message for a firmware-managed Mac ("이 macOS 버전은 아직 지원하지 않습니다"). It needs a new catalog key in 30 languages for an unreleased OS; deferred by decision on 2026-08-23.
- `BatteryControlEngine.release()`'s missing `isHardwareSupported` guard. It is inert today (`WattlyFanDaemon/BatteryControlHardware.swift:22` returns early on an empty write list) and a naive guard breaks `unsupportedHardwareLeavesTheOtherEntryPointsInert`, which pins the current behaviour on purpose. Deferred to whenever macOS 27 support is implemented — recorded in `docs/plans/2026-08-23-battery-register-generations.md`.
- Flipping `BatteryControlKeys.probeOrder` to match upstream's `CH0B`-first order. Blocked on a report from a Mac exposing both registers; no such machine has ever been reported.
- Anything in `FanControlShared/` or `WattlyFanDaemon/`.

---

## File Structure

**Modify:**
- `Wattly/Core/BatterySectionPresentation.swift` — the two pure decisions. `shouldPollStatus` gains an `isHardwareSupported` parameter (Task 1); a new `isToggleEnabled(isHardwareSupported:isLimitOn:)` joins it (Task 2). This file already owns every other "what should the battery section do" decision, so both belong here rather than in the view.
- `Wattly/Views/Settings/SettingsBatterySection.swift` — the two call sites, one per task, plus the file-top comment in Task 2.
- `WattlyTests/BatterySectionPresentationTests.swift` — three new tests in Task 1 (and three existing ones updated for the new signature), one new test in Task 2.

**Create:** nothing.

---

## Task 1: Stop polling hardware that can never change its answer

`shouldPollStatus` learns the one fact that makes further reads pointless. The signature change forces every call site to answer the question, which is the point — a defaulted parameter would let the view keep its current behaviour by accident.

**Files:**
- Modify: `Wattly/Core/BatterySectionPresentation.swift:111-127` (doc comment and function)
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift:85-87` (the `while` condition)
- Test: `WattlyTests/BatterySectionPresentationTests.swift:134-153` (three existing tests updated, three added)

**Interfaces:**
- Consumes: `BatteryControlServiceMode` (`.inhibited` / `.charging` / `.unavailable` / `.unsupported`), and `BatteryControlServiceStatus.isHardwareSupported: Bool?`, both already in `FanControlShared`.
- Produces: `BatterySectionPresentation.shouldPollStatus(isLimitOn: Bool, mode: BatteryControlServiceMode, isHardwareSupported: Bool?) -> Bool` — replaces the two-parameter version. Task 2 does not consume it.

- [ ] **Step 1: Update the three existing polling tests to the new signature**

In `WattlyTests/BatterySectionPresentationTests.swift`, replace the three tests that currently sit under the `// MARK: - 폴링` heading (lines 134-153) with these. Only the added argument changes; the existing expectations and comments are preserved verbatim, because they are still exactly right for a Mac whose hardware is capable.

```swift
    @Test func pollingRunsWhenOnRegardlessOfMode() {
        for mode: BatteryControlServiceMode in [.inhibited, .charging, .unavailable, .unsupported] {
            #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: true, mode: mode,
                                                                isHardwareSupported: true) == true)
        }
    }

    @Test func pollingStopsWhenOffAndSettled() {
        // `.charging` = 정상적으로 꺼짐, `.unavailable` = 도우미가 없어 물어봐야 답할 주체가 없음.
        // 둘 다 문구가 상수라 다시 읽어도 바뀌지 않는다.
        #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: false, mode: .charging,
                                                            isHardwareSupported: true) == false)
        #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: false, mode: .unavailable,
                                                            isHardwareSupported: true) == false)
    }

    @Test func pollingContinuesWhenOffAndStillRecovering() {
        // 껐는데 하드웨어가 아직 물고 있거나 해제 쓰기가 실패한 상태 — 데몬이 스스로 재시도해
        // 풀어내므로, 여기서 폴링을 멈추면 사용자가 어댑터를 다시 꽂아 실제로 복구된 뒤에도 화면은
        // 실패 문구에 얼어붙는다.
        #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: false, mode: .inhibited,
                                                            isHardwareSupported: true) == true)
        #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: false, mode: .unsupported,
                                                            isHardwareSupported: true) == true)
    }
```

- [ ] **Step 2: Add the three new tests**

Insert these immediately after `pollingContinuesWhenOffAndStillRecovering`, still under the `// MARK: - 폴링` heading and before the `// MARK: - 현지화 (plan 2026-08-23)` heading.

```swift
    @Test func pollingStopsOnHardwareThatCanNeverChangeItsAnswer() {
        // 영구적인 사실에는 재질문이 없다. 이 상태에서는 `areDetailsVisible == false`라 갱신할
        // 화면조차 없는데, 5초마다 XPC 왕복과 루트 데몬의 IOKit 전원 소스 읽기가 무한히 돈다.
        // 한도가 켜져 있어도 마찬가지다 — 켜짐은 사용자의 저장값일 뿐, 하드웨어의 답을 바꾸지 못한다.
        for isOn in [true, false] {
            for mode: BatteryControlServiceMode in [.inhibited, .charging, .unavailable, .unsupported] {
                #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: isOn, mode: mode,
                                                                    isHardwareSupported: false) == false)
            }
        }
    }

    @Test func pollingSurvivesAnUnansweredHelper() {
        // `nil`은 "아직 답이 없다"이지 "불가능하다"가 아니다. 여기서 폴링을 멈추면 도우미가 처음
        // 답하기 전에 창을 연 사용자는 영영 답을 못 받는다 — 다시 물어볼 유일한 주체가 이 루프다.
        #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: true, mode: .unavailable,
                                                            isHardwareSupported: nil) == true)
        #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: false, mode: .unsupported,
                                                            isHardwareSupported: nil) == true)
    }

    @Test func pollingContinuesWhileSupportedHardwareIsStillFailingItsWrites() {
        // `.unsupported` 모드는 두 가지를 뜻한다 — 레지스터가 아예 없거나, 쓰기가 계속 실패하거나
        // (`BatteryControlEngine`의 `!isHardwareSupported || hasActionableFailure`). 후자는 데몬이
        // 재시도로 빠져나올 수 있는 일시적 상태이므로, 이 커밋이 그 폴링까지 끄면 안 된다.
        #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: false, mode: .unsupported,
                                                            isHardwareSupported: true) == true)
        #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: true, mode: .unsupported,
                                                            isHardwareSupported: true) == true)
    }
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath "$DD" -only-testing:WattlyTests/BatterySectionPresentationTests 2>&1 | grep -E "error:|Test run"
```

Expected: the build fails to compile with `error: extra argument 'isHardwareSupported' in call` (six times, once per updated/added call). A compile failure **is** the red state here — `shouldPollStatus` does not yet take the parameter.

- [ ] **Step 4: Add the parameter and the short-circuit**

In `Wattly/Core/BatterySectionPresentation.swift`, replace the `shouldPollStatus` doc comment and function (lines 111-127) with:

```swift
    /// 설정 화면이 상태를 주기적으로 다시 읽어야 하는지.
    ///
    /// 도우미가 "이 Mac은 불가능하다"고 명시적으로 답했다면 다시 묻지 않는다. 그 답은 영구적인
    /// 사실이라 재질문으로 바뀔 수 없고, 그 상태에서는 `areDetailsVisible == false`라 갱신할 화면
    /// 자체가 없다. 이 확인이 없으면 제한이 켜진 채로 지원되지 않는 Mac에 남은 사용자는 5초마다
    /// XPC 왕복과 루트 데몬의 전원 소스 읽기를 영원히 유발한다.
    ///
    /// 켜져 있으면 항상 읽는다 — 관심 있는 순간(한도 도달)이 창을 연 뒤 몇 분 뒤에 온다.
    ///
    /// 꺼져 있을 때는 문구가 바뀔 수 있는 상태에서만 읽는다. `.charging`은 정상적으로 꺼진 상태라
    /// 문구가 상수이고, `.unavailable`은 도우미가 없어 다시 물어봐야 답할 주체가 없다 — 둘 다
    /// 폴링해봐야 `batteryStatus` XPC → 데몬의 IOKit 전원 소스 읽기만 유발한다. 반대로
    /// `.inhibited`/`.unsupported`는 "껐는데 하드웨어가 아직 물고 있다"이고, 데몬이 스스로
    /// 재시도해 풀어내는 상태다. 여기서 읽지 않으면 사용자가 안내대로 어댑터를 다시 꽂아 실제로
    /// 복구된 뒤에도 화면은 실패 문구에 멈춰 있게 된다. `.unsupported`가 두 가지(레지스터 없음 /
    /// 쓰기 실패)를 함께 뜻하기 때문에, 영구적인 쪽을 걸러내는 일은 위의 `isHardwareSupported`
    /// 확인이 맡는다.
    static func shouldPollStatus(isLimitOn: Bool,
                                 mode: BatteryControlServiceMode,
                                 isHardwareSupported: Bool?) -> Bool {
        if isHardwareSupported == false { return false }
        if isLimitOn { return true }
        switch mode {
        case .inhibited, .unsupported: return true
        case .charging, .unavailable: return false
        }
    }
```

- [ ] **Step 5: Update the one call site**

In `Wattly/Views/Settings/SettingsBatterySection.swift`, replace the `while` condition (lines 85-87):

```swift
                while !Task.isCancelled,
                      BatterySectionPresentation.shouldPollStatus(isLimitOn: batteryLimitEnabled,
                                                                   mode: batteryControl.status.mode,
                                                                   isHardwareSupported: batteryControl.status.isHardwareSupported) {
```

- [ ] **Step 6: Run the full suite to verify it passes**

```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath "$DD" 2>&1 | grep -E "error:|✘|Test run"
```

Expected: `✔ Test run with 689 tests in 60 suites passed`, no `✘`, no `error:`.

- [ ] **Step 7: Commit**

```bash
git add Wattly/Core/BatterySectionPresentation.swift Wattly/Views/Settings/SettingsBatterySection.swift WattlyTests/BatterySectionPresentationTests.swift
git commit -m "fix(battery): stop polling a Mac that reported permanent unsupport"
```

---

## Task 2: Leave the user a way out of a toggle stuck ON

The toggle stops being dead when it reads ON on incapable hardware. It still cannot be switched *on* there, so the exit is one-way, and no code writes the user's preference for them.

**Files:**
- Modify: `Wattly/Core/BatterySectionPresentation.swift` (add `isToggleEnabled` directly below `areDetailsVisible`, i.e. after line 36)
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift:21-30` (file-top comment and the two `SettingsToggleRow` arguments) and `:192-196` (add the derived property beside `isHardwareUnsupported`)
- Test: `WattlyTests/BatterySectionPresentationTests.swift` (one test, in the `// MARK: - 하위 항목 노출` section)

**Interfaces:**
- Consumes: `BatterySectionPresentation.areDetailsVisible(isHardwareSupported: Bool?) -> Bool`, already present at `Wattly/Core/BatterySectionPresentation.swift:30-36`.
- Produces: `BatterySectionPresentation.isToggleEnabled(isHardwareSupported: Bool?, isLimitOn: Bool) -> Bool`. Nothing later in this plan consumes it.

- [ ] **Step 1: Write the failing test**

Add to `WattlyTests/BatterySectionPresentationTests.swift`, immediately after `detailsAreVisibleWhenHardwareSupportIsTrueOrUnknown` in the `// MARK: - 하위 항목 노출` section:

```swift
    @Test func theToggleStaysUsableWhileItReadsOnEvenOnHardwareThatCannotDoIt() {
        // 지원되는(또는 아직 모르는) 하드웨어에서는 언제나 조작할 수 있다.
        for supported: Bool? in [true, nil] {
            for isOn in [true, false] {
                #expect(BatterySectionPresentation.isToggleEnabled(isHardwareSupported: supported,
                                                                    isLimitOn: isOn) == true)
            }
        }

        // 불가능한 하드웨어에서 꺼져 있으면 켤 수 없다 — 켜봐야 아무 일도 일어나지 않는다.
        #expect(BatterySectionPresentation.isToggleEnabled(isHardwareSupported: false,
                                                            isLimitOn: false) == false)

        // ...그러나 이미 켜져 있다면 끌 수 있어야 한다. 펌웨어가 바뀌며 지원이 사라진 Mac에는 저장된
        // `true`가 그대로 남는데, 그 값을 앱이 대신 꺼주지 않는 것은 의도된 설계다(SettingsBatterySection
        // 상단 주석). 이 한 칸이 열려 있지 않으면 사용자에게는 전체 설정 초기화 말고 빠져나갈 길이 없다.
        #expect(BatterySectionPresentation.isToggleEnabled(isHardwareSupported: false,
                                                            isLimitOn: true) == true)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath "$DD" -only-testing:WattlyTests/BatterySectionPresentationTests 2>&1 | grep -E "error:|Test run"
```

Expected: compile failure, `error: type 'BatterySectionPresentation' has no member 'isToggleEnabled'`.

- [ ] **Step 3: Add the pure function**

In `Wattly/Core/BatterySectionPresentation.swift`, insert directly below the closing brace of `areDetailsVisible` (after line 36):

```swift
    /// 토글을 조작할 수 있는지.
    ///
    /// 불가능한 하드웨어에서는 켤 수 없다. 그러나 **이미 켜져 있는 값은 끌 수 있어야 한다.** 충전
    /// 제어 레지스터는 기종이 아니라 펌웨어를 따라가므로(`BatteryControlKeys` 참고), 오늘 잘 쓰던
    /// Mac이 macOS 업데이트 한 번으로 지원 대상에서 빠질 수 있다. 그때 저장된 `true`는 그대로 남아
    /// 토글은 켜짐으로 표시된 채 조작 불가가 되고, 사용자에게는 전체 설정 초기화 말고 빠져나갈
    /// 길이 없어진다.
    ///
    /// 렌더링이 저장값을 대신 꺼주지 않는 것은 의도다(`SettingsBatterySection` 상단 주석): 같은
    /// 환경설정이 이 기능을 지원하는 Mac에 도달하는 순간 그 값은 틀린 값이 된다. 그래서 끄는 행위는
    /// 사용자에게 남기고, 이 함수는 그 길만 열어 둔다.
    static func isToggleEnabled(isHardwareSupported: Bool?, isLimitOn: Bool) -> Bool {
        areDetailsVisible(isHardwareSupported: isHardwareSupported) || isLimitOn
    }
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath "$DD" -only-testing:WattlyTests/BatterySectionPresentationTests 2>&1 | grep -E "error:|✘|Test run"
```

Expected: no `✘`, no `error:`, and `theToggleStaysUsableWhileItReadsOnEvenOnHardwareThatCannotDoIt` reported as passed.

- [ ] **Step 5: Wire the view to it**

Two edits in `Wattly/Views/Settings/SettingsBatterySection.swift`.

First, replace the file-top comment and the `SettingsToggleRow` arguments (lines 21-30) with:

```swift
                // Rendering never writes the stored value: flipping it off here would look like the
                // app undoing the user's choice, and it would be wrong the moment the same
                // preferences reach a Mac that does support the limit. Two things keep that from
                // stranding anyone. The toggle handler clears the opt-in the user just made once
                // the helper answers that this Mac has no register; and `isToggleEnabled` leaves
                // the row switchable while it reads ON, so a `true` that arrived some other way —
                // a firmware update that took the register away under a working Mac — can still be
                // switched off by hand. Turning it back on stays impossible, so the exit is
                // one-way.
                SettingsToggleRow(isOn: $batteryLimitEnabled,
                                  divider: areDetailsVisible,
                                  isEnabled: isToggleEnabled,
                                  disabledReason: isToggleEnabled ? nil : "이 Mac은 충전 제어를 지원하지 않습니다") {
```

Second, add the derived property directly below `isHardwareUnsupported` (after line 196):

```swift
    /// 토글이 조작 가능한지. `isHardwareUnsupported`의 단순한 반대가 아니다 — 이미 켜져 있는 값을
    /// 끌 수 있게 남겨두는 예외가 붙는다. 판단은 `BatterySectionPresentation`이 갖는다.
    private var isToggleEnabled: Bool {
        BatterySectionPresentation.isToggleEnabled(
            isHardwareSupported: batteryControl.status.isHardwareSupported,
            isLimitOn: batteryLimitEnabled)
    }
```

- [ ] **Step 6: Run the full suite to verify it passes**

```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath "$DD" 2>&1 | grep -E "error:|✘|Test run"
```

Expected: `✔ Test run with 690 tests in 60 suites passed`, no `✘`, no `error:`.

- [ ] **Step 7: Confirm the switch-off actually reaches the daemon**

No code change — a reading check, so the escape hatch is not cosmetic. Open `Wattly/Views/BatteryControlBridge.swift` and confirm the `onChange` observer at line 21 pushes **both** values:

```swift
                Task { await client.apply(enabled: val, limitPercentage: limit) }
```

It is not guarded on `val == true`, so switching the toggle off pushes `enabled: false` to the helper like any other change. The handler in `SettingsBatterySection.onChange` returns early for the off direction (`guard isEnabled`), which is correct — that one only exists to run the installer. If the bridge observer ever grows a `guard val` this task's fix becomes cosmetic, so state in the commit body that it was checked.

- [ ] **Step 8: Commit**

```bash
git add Wattly/Core/BatterySectionPresentation.swift Wattly/Views/Settings/SettingsBatterySection.swift WattlyTests/BatterySectionPresentationTests.swift
git commit -m "fix(battery): keep the limit toggle switchable while it reads ON

An unsupported answer used to disable the row in whatever position it was
already in, and the only handler that clears a stale ON runs on user flip —
which a disabled toggle cannot produce. Reachable since .firmwareManaged:
firmware ownership can arrive on a Mac where the limit works today.

The stored value is still never written by rendering (see the file-top
comment); the row is simply left switchable in the off direction. Verified
that BatteryControlBridge pushes enabled:false to the helper on that flip."
```

---

## Verification checklist for the reviewer between tasks

- `git diff --stat` after each task touches **only** the three files that task names, and never `Wattly.xcodeproj/project.pbxproj`.
- `grep -rn "shouldPollStatus" --include="*.swift" .` finds exactly one call site outside the tests.
- `grep -c "String(localized" Wattly/Core/BatterySectionPresentation.swift` is unchanged from before this plan — no new copy was introduced.
- `python3 -c "import json;print(len(json.load(open('Wattly/Resources/Localizable.xcstrings'))['strings']))"` still prints **227**.
