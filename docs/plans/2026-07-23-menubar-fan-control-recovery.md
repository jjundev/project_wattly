# Menubar Fan-Control Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 잠자기 후 macOS 자동 제어로 풀린 팬 커브 제어를 사용자가 메뉴바를 클릭해 팝오버를 열 때만 확인하고, 실제 적용 설정이 켜져 있을 때 Wattly 팬 커브 제어를 다시 시작한다.

**Architecture:** 데몬의 기존 sleep 안전 복구 동작은 유지한다. 앱은 팝오버가 나타날 때 XPC `status`를 한 번 조회하고, 응답이 `.automatic`이며 `fanControlEnabled`가 true인 경우에만 현재 저장된 커브를 `configure`로 재전송한다. 이미 `.controlling`/`.engaging`/`.failed`인 상태에는 중복 명령을 보내지 않으며, 설정이 꺼져 있으면 상태 조회도 하지 않는다.

**Tech Stack:** Swift 6, SwiftUI `MenuBarExtra(.window)`, Foundation/Observation, NSXPC, Swift Testing, macOS 14+ arm64.

## Global Constraints

- macOS 14.0+, Swift 6 strict concurrency, arm64만 지원한다.
- 팬 제어 설정이 꺼져 있으면 메뉴바 클릭으로 helper에 재적용 명령을 보내지 않는다.
- 잠자기 시 팬을 macOS 자동 모드로 되돌리는 `WattlyFanDaemon`의 fail-safe 동작은 변경하지 않는다.
- 재적용은 XPC `status`가 `.automatic`일 때만 수행한다. `.controlling`, `.engaging`, `.failed`, `.unavailable`에는 configure를 보내지 않는다.
- 기존 `FanControlClient`의 generation-stamped configure 요청과 heartbeat 동작을 재사용하며 새로운 의존성을 추가하지 않는다.
- SwiftUI View 전용 동작은 이 코드베이스의 기존 관례에 따라 dedicated View unit test 대신 빌드와 실제 메뉴바 수동 검증으로 확인한다.

---

## File Structure

| Path | Responsibility |
|---|---|
| `FanControlShared/FanControlPolicy.swift` | 메뉴바 진입 시 재적용 여부를 결정하는 순수 정책 함수와 기존 fan-control timing 정책을 함께 둔다. |
| `Wattly/Control/FanControlClient.swift` | helper의 현재 상태를 읽고, 필요한 경우 저장된 커브를 다시 configure하는 app-side XPC 흐름을 제공한다. |
| `Wattly/Views/PopoverContentView.swift` | 메뉴바 팝오버가 나타나는 순간 recovery 흐름을 호출하고 현재 `@AppStorage` 값을 전달한다. |
| `Wattly/App/WattlyApp.swift` | 앱 전체에서 공유하는 `FanControlClient`를 팝오버에 주입한다. |
| `WattlyTests/FanControlProtocolTests.swift` | 순수 recovery 조건이 enabled/mode 조합별로 정확히 동작하는지 검증한다. |

### Decision checkpoint

코드베이스가 결정할 수 없는 실행 수준의 분기는 없다. `MenuBarExtra` 클릭 자체를 AppKit으로 후킹하는 대신 이미 메뉴바 클릭으로 생성되는 팝오버의 `onAppear`를 사용한다. 이 이벤트는 사용자가 메뉴바 항목을 열 때마다 실행되고, 팝오버가 닫힐 때 unmount되는 현재 구조와 일치한다. 데몬의 sleep observer나 polling timer를 수정하면 사용자가 요청한 “메뉴바 클릭 시 확인” 범위를 넘어가므로 변경하지 않는다.

### Task 1: Add status-aware fan-control recovery to the client

**Files:**
- Modify: `FanControlShared/FanControlPolicy.swift`
- Modify: `Wattly/Control/FanControlClient.swift`
- Modify: `WattlyTests/FanControlProtocolTests.swift`

**Interfaces:**
- Consumes: existing `FanControlServiceMode`, `FanControlServiceStatus`, `FanControlXPCService.status(withReply:)`, `FanControlClient.apply(enabled:curve:)`.
- Produces: `FanControlPolicy.shouldReapplyAfterMenuBarOpen(enabled:mode:) -> Bool`, `FanControlClient.refreshStatus() async`, and `FanControlClient.reconcileAfterMenuBarOpen(enabled:curve:) async`.

- [ ] **Step 1: Write the failing policy tests**

Append these tests to `WattlyTests/FanControlProtocolTests.swift`:

```swift
    @Test func menuBarRecoveryOnlyReappliesWhenEnabledAndAutomatic() {
        #expect(FanControlPolicy.shouldReapplyAfterMenuBarOpen(enabled: true, mode: .automatic))
        #expect(!FanControlPolicy.shouldReapplyAfterMenuBarOpen(enabled: true, mode: .controlling))
        #expect(!FanControlPolicy.shouldReapplyAfterMenuBarOpen(enabled: true, mode: .engaging))
        #expect(!FanControlPolicy.shouldReapplyAfterMenuBarOpen(enabled: true, mode: .failed))
        #expect(!FanControlPolicy.shouldReapplyAfterMenuBarOpen(enabled: true, mode: .unavailable))
        #expect(!FanControlPolicy.shouldReapplyAfterMenuBarOpen(enabled: false, mode: .automatic))
    }
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  -only-testing:WattlyTests/FanControlProtocolTests/menuBarRecoveryOnlyReappliesWhenEnabledAndAutomatic test
```

Expected: FAIL at compile time because `shouldReapplyAfterMenuBarOpen(enabled:mode:)` has not been defined.

- [ ] **Step 3: Add the pure recovery predicate**

Add this function inside `FanControlPolicy` in `FanControlShared/FanControlPolicy.swift`, alongside the existing timing predicates:

```swift
    /// A menu-bar open should repair a lost Wattly session only when the user still opted in
    /// and the helper confirms that every fan is back in macOS automatic mode. Other states are
    /// either already progressing, already controlling, or unsafe to override blindly.
    static func shouldReapplyAfterMenuBarOpen(enabled: Bool,
                                               mode: FanControlServiceMode) -> Bool {
        enabled && mode == .automatic
    }
```

- [ ] **Step 4: Add status refresh and conditional reconfiguration to the client**

In `Wattly/Control/FanControlClient.swift`, add the following methods after `heartbeat()` and before `release()`:

```swift
    /// Reads the helper's current state without changing fan ownership. This is separate from
    /// heartbeat because a menu-bar open must distinguish automatic mode from an active session.
    func refreshStatus() async {
        await send { service, reply in service.status(withReply: reply) }
    }

    /// Repairs the session that the daemon intentionally released during system sleep. The
    /// caller snapshots its @AppStorage values before awaiting so a settings change cannot alter
    /// the request halfway through this menu-bar-open transaction.
    func reconcileAfterMenuBarOpen(enabled: Bool, curve: FanCurve) async {
        guard enabled else { return }
        await refreshStatus()
        guard FanControlPolicy.shouldReapplyAfterMenuBarOpen(enabled: enabled, mode: status.mode) else {
            return
        }
        await apply(enabled: true, curve: curve)
    }
```

The `refreshStatus()` call must use the existing private `send` helper so XPC reply/error handling, connection invalidation, and `.unavailable` status updates remain identical to `apply`, `heartbeat`, and `release`.

- [ ] **Step 5: Run the focused test and verify it passes**

Run the same focused `xcodebuild` command from Step 2.

Expected: PASS. The test must cover all five non-recovery modes and the disabled opt-in case.

- [ ] **Step 6: Commit the client recovery seam**

```bash
git add FanControlShared/FanControlPolicy.swift Wattly/Control/FanControlClient.swift WattlyTests/FanControlProtocolTests.swift
git commit -m "feat(fan): add status-aware menu-bar recovery"
```

### Task 2: Trigger recovery when the menu-bar popover opens

**Files:**
- Modify: `Wattly/App/WattlyApp.swift:25-36`
- Modify: `Wattly/Views/PopoverContentView.swift:12-20, 108-132`

**Interfaces:**
- Consumes: `FanControlClient.reconcileAfterMenuBarOpen(enabled:curve:) async`, `StorageKey.fanControlEnabled`, and `StorageKey.fanCurve`.
- Produces: every menu-bar popover open invokes one snapshot-based recovery check; only a confirmed `.automatic` state with the opt-in enabled triggers configure.

- [ ] **Step 1: Inject the shared client into the popover**

In `Wattly/App/WattlyApp.swift`, change the `MenuBarExtra` content construction from:

```swift
                PopoverContentView(monitor: monitor)
```

to:

```swift
                PopoverContentView(monitor: monitor, fanControl: fanControl)
```

Do not create a second `FanControlClient`; the `@State private var fanControl` instance already owns the app-wide observable status and is also used by `FanControlBridge` and `SettingsView`.

- [ ] **Step 2: Add the client and persisted fan settings to the popover view**

In `Wattly/Views/PopoverContentView.swift`, replace the existing stored monitor property with:

```swift
    let monitor: SystemMonitor
    let fanControl: FanControlClient

    @AppStorage(StorageKey.fanControlEnabled) private var fanControlEnabled = Defaults.fanControlEnabled
    @AppStorage(StorageKey.fanCurve) private var fanCurve = Defaults.fanCurve
```

This keeps the recovery trigger independent of the Settings window, which can be unmounted or closed while the menu-bar item remains alive.

- [ ] **Step 3: Call reconciliation from the existing popover `onAppear`**

Extend the existing `.onAppear` in `PopoverContentView.body` immediately after `monitor.setPanelVisible(true)`:

```swift
            // Opening the MenuBarExtra is the user-visible recovery action. Snapshot the
            // persisted values before awaiting XPC so a concurrent Settings edit is handled by
            // the normal bridge/onChange path rather than changing this transaction mid-flight.
            let shouldControlFans = fanControlEnabled
            let curveForRecovery = fanCurve
            Task {
                await fanControl.reconcileAfterMenuBarOpen(enabled: shouldControlFans,
                                                            curve: curveForRecovery)
            }
```

Keep the existing screen-height calculation in the same `onAppear` closure. Do not put this in `.onDisappear`, the polling bridge, or the daemon's sleep observer: recovery is intentionally user-triggered by opening the menu-bar panel.

- [ ] **Step 4: Build the app and run the full automated suite**

Run:

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' build
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
```

Expected: `BUILD SUCCEEDED`, then `TEST SUCCEEDED`. Existing `FanControlEngineTests` must remain green, especially sleep release, heartbeat expiry, and explicit disable tests.

- [ ] **Step 5: Perform the on-device menu-bar recovery check**

With the helper installed on a fan-equipped Mac:

```text
1. Turn on “팬 커브 실제 적용” and wait until Settings reports “적용 중 · 커브대로 제어”.
2. Put the MacBook to sleep, wake it, and do not open Wattly during wake-up.
3. Confirm the daemon has returned the fans to macOS automatic mode, then click the Wattly menu-bar item once.
4. Confirm the next status transition is “연결 중…”/“적용 중 · 커브대로 제어” and that the fan follows the saved curve again.
5. Close and reopen the menu-bar panel while already controlling; confirm it stays controlling and does not visibly restart or flicker.
6. Turn the setting off, repeat the sleep/wake/open sequence, and confirm no recovery configure is sent and the UI remains “꺼짐 · macOS 자동 제어”.
7. If the helper is unavailable or reports “제어 실패”, confirm opening the panel does not blindly override that state; the existing error/status text remains visible.
```

- [ ] **Step 6: Commit the menu-bar integration**

```bash
git add Wattly/App/WattlyApp.swift Wattly/Views/PopoverContentView.swift
git commit -m "feat(fan): recover curve control on menu-bar open"
```

## Self-review

### Spec coverage

- Sleep currently releases Wattly ownership to macOS automatic mode: preserved by the global constraint and verified by existing engine tests.
- Menu-bar click checks whether control was released: Task 2 calls reconciliation from the popover's per-open `onAppear`.
- Released control is restored: Task 1 refreshes XPC status and reconfigures the saved curve only for `.automatic`.
- Disabled control is not unexpectedly re-enabled: Task 1's predicate test and Task 2's manual check cover `enabled == false`.
- Already-active or failed states are not blindly overwritten: Task 1 tests all service modes and Task 2 includes the on-device check.

### Placeholder scan

The plan contains no TODO/TBD/“implement later” steps and every code-changing step includes the exact symbols, snippets, commands, or expected result needed for implementation.

### Type consistency

`FanControlPolicy.shouldReapplyAfterMenuBarOpen(enabled:mode:)` consumes `Bool` and `FanControlServiceMode`; `FanControlClient.reconcileAfterMenuBarOpen(enabled:curve:)` calls it with `status.mode`; `PopoverContentView` passes `Bool` and `FanCurve` snapshots from the declared `@AppStorage` properties. The app passes the already-declared `FanControlClient` into the new initializer.

### Automatic review follow-up

The plan reviewer approved the document with one advisory recommendation: add client-level tests for status refresh and conditional configure dispatch if XPC mocking is available. The current client owns a concrete `NSXPCConnection` inside its private request path and the repository has no XPC mock/test-double seam. The plan therefore keeps the change minimal: the decision is covered by the pure policy test, compile/build verification covers the new client calls, and the real helper path is covered by the on-device sleep/wake acceptance checklist. Introducing a new mock transport solely for this small recovery path would change the client boundary and task decomposition without being required by the user request.
