# Low-Power Provider Scheduler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Wattly가 패널이 닫힌 동안 불필요한 IOReport·SMC·IOKit 폴링과 자체 계측 wake-up을 줄이면서, 메뉴바에 표시한 수치와 열린 패널의 반응성은 유지한다.

**Architecture:** 전역 timer는 유지하되, 순수 정책이 화면 상태·사용자 고정 주기·표시 수요에서 provider별 갱신 간격을 산출한다. SystemMonitor는 마지막 실제 읽기 시각을 기준으로 due provider만 호출하고, 재개 때에는 즉시 baseline/read를 시작한다. 자기 전력 계측은 화면 갱신과 분리해 30초마다만 수행한다.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI MenuBarExtra, Observation, Swift Testing, macOS 14+, Apple Silicon.

## Global Constraints

- 타깃은 macOS 14.0+ / Apple Silicon이며 Swift 6 strict concurrency를 유지한다.
- 관리자 권한, helper, powermetrics, 명시적 Metal API, 외부 텔레메트리를 런타임 경로에 추가하지 않는다.
- MetricProvider → MetricSample Sendable 경계와 지표별 부분 실패 격리를 보존한다.
- PollInterval.s1·.s2·.s5는 활성 provider 전체를 사용자가 선택한 고정 간격으로 갱신한다.
- .auto: 패널 열림 CPU/SoC 전력 1초, 온도 2초, 메모리/배터리 5초; 패널 닫힘+메뉴바 텍스트는 메뉴바 선택 provider만 2초; 텍스트 OFF는 지표 provider를 폴링하지 않는다.
- 패널 재개나 새 메뉴바 수요는 즉시 읽는다. CPU/전력의 첫 delta 기반 샘플은 .loading일 수 있으나 다음 고속 샘플에서 최신값이 되어야 한다.
- SelfEnergySampling은 최대 30초마다만 호출한다.
- 60초/256개 history, 온도 SMC 게이팅, 확장 카드의 on-demand 프로세스 열거를 보존한다.

---

## File structure

| File | Responsibility |
|---|---|
| Wattly/Core/PollPolicy.swift | 수요를 provider interval·due set·다음 wake-up으로 순수 변환한다. |
| Wattly/Core/SystemMonitor.swift | 정책을 실행해 선택된 provider만 읽고 reschedule/self-energy를 조정한다. |
| WattlyTests/PollPolicyTests.swift | interval, due, wake-up 순수 로직을 결정론적으로 검증한다. |
| WattlyTests/SystemMonitorTests.swift | 닫힌 메뉴바 상태와 수동 refresh의 실제 provider 호출을 검증한다. |
| Wattly/Settings/Settings.swift, Wattly/Views/SettingsView.swift | 단일 사용자 설명 문구를 제공·표시한다. |
| docs/self-power-baseline.md | 새 측정 상태와 30초 평균 회귀 절차를 기록한다. |

## Decision checkpoint

새 라이브러리나 데이터 모델 선택은 없다. 기존 .auto는 절전 동작이며 고정 1/2/5초는 사용자가 전체 지표의 새로고침을 명시한 것이므로, 자동 모드만 계층화하고 고정 모드는 호환 동작으로 둔다.

### Task 1: Provider-level polling policy

**Files:**
- Modify: Wattly/Core/PollPolicy.swift:1-34
- Test: WattlyTests/PollPolicyTests.swift:1-58

**Interfaces:**
- Consumes: PollInterval, ProviderKind, CardKind.
- Produces: providerIntervals(setting:panelVisible:menubarTextEnabled:active:menubarNeeds:) -> [ProviderKind: Duration], dueProviders(intervals:lastRead:now:force:) -> Set<ProviderKind>, nextPollDelay(intervals:lastRead:now:housekeeping:) -> Duration.

- [ ] **Step 1: Write the failing tests**

Append these tests to PollPolicyTests.

~~~swift
@Test func autoPolicyBudgetsProvidersByVisibility() {
    let all = Set(ProviderKind.allCases)
    #expect(providerIntervals(setting: .auto, panelVisible: true,
                              menubarTextEnabled: true, active: all,
                              menubarNeeds: [.cpu]) == [
        .cpu: .seconds(1), .power: .seconds(1), .temperature: .seconds(2),
        .memory: .seconds(5), .battery: .seconds(5),
    ])
    #expect(providerIntervals(setting: .auto, panelVisible: false,
                              menubarTextEnabled: true, active: all,
                              menubarNeeds: [.cpu]) == [.cpu: .seconds(2)])
    #expect(providerIntervals(setting: .auto, panelVisible: false,
                              menubarTextEnabled: false, active: all,
                              menubarNeeds: [.cpu]).isEmpty)
}

@Test func fixedPolicyKeepsEveryActiveProviderAtChosenInterval() {
    #expect(providerIntervals(setting: .s2, panelVisible: false,
                              menubarTextEnabled: false,
                              active: [.cpu, .power], menubarNeeds: []) == [
        .cpu: .seconds(2), .power: .seconds(2),
    ])
}

@Test func dueProvidersOnlyReturnsExpiredIntervalsUnlessForced() {
    let now = ContinuousClock.now
    let intervals: [ProviderKind: Duration] = [.cpu: .seconds(1), .memory: .seconds(5)]
    let last: [ProviderKind: ContinuousClock.Instant] = [
        .cpu: now.advanced(by: .seconds(-1)),
        .memory: now.advanced(by: .seconds(-2)),
    ]
    #expect(dueProviders(intervals: intervals, lastRead: last, now: now, force: false) == [.cpu])
    #expect(dueProviders(intervals: intervals, lastRead: last, now: now, force: true) == [.cpu, .memory])
}

@Test func nextDelayNeverExceedsHousekeepingWake() {
    let now = ContinuousClock.now
    #expect(nextPollDelay(intervals: [:], lastRead: [:], now: now,
                          housekeeping: .seconds(30)) == .seconds(30))
    #expect(nextPollDelay(intervals: [.cpu: .seconds(2)], lastRead: [:], now: now,
                          housekeeping: .seconds(30)) == .zero)
}

@Test func nextDelayUsesTheEarliestProviderDeadline() {
    let now = ContinuousClock.now
    let last: [ProviderKind: ContinuousClock.Instant] = [
        .cpu: now.advanced(by: .seconds(-1)),
        .memory: now.advanced(by: .seconds(-1)),
    ]
    #expect(nextPollDelay(intervals: [.cpu: .seconds(5), .memory: .seconds(2)],
                          lastRead: last, now: now,
                          housekeeping: .seconds(30)) == .seconds(1))
}
~~~

- [ ] **Step 2: Run the tests and confirm they fail**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  test -only-testing:WattlyTests/PollPolicyTests
~~~

Expected: build failure mentioning cannot find providerIntervals in scope.

- [ ] **Step 3: Add the complete pure policy**

Keep resolvePollInterval and activeProviders for existing callers. Append this code to PollPolicy.swift.

~~~swift
func providerIntervals(setting: PollInterval,
                       panelVisible: Bool,
                       menubarTextEnabled: Bool,
                       active: Set<ProviderKind>,
                       menubarNeeds: Set<CardKind>) -> [ProviderKind: Duration] {
    if setting != .auto {
        let interval: Duration = switch setting {
        case .s1: .seconds(1)
        case .s2: .seconds(2)
        case .s5: .seconds(5)
        case .auto: preconditionFailure("handled above")
        }
        return Dictionary(uniqueKeysWithValues: active.map { ($0, interval) })
    }
    if panelVisible {
        let open: [ProviderKind: Duration] = [
            .cpu: .seconds(1), .power: .seconds(1), .temperature: .seconds(2),
            .memory: .seconds(5), .battery: .seconds(5),
        ]
        return open.filter { active.contains($0.key) }
    }
    guard menubarTextEnabled else { return [:] }
    let menuProviders = Set(menubarNeeds.map(\.provider))
    return Dictionary(uniqueKeysWithValues:
        menuProviders.intersection(active).map { ($0, .seconds(2)) })
}

func dueProviders(intervals: [ProviderKind: Duration],
                  lastRead: [ProviderKind: ContinuousClock.Instant],
                  now: ContinuousClock.Instant,
                  force: Bool) -> Set<ProviderKind> {
    Set(intervals.compactMap { kind, interval in
        guard force || lastRead[kind].map({ seconds(from: $0, to: now) >= seconds(interval) }) != false
        else { return nil }
        return kind
    })
}

func nextPollDelay(intervals: [ProviderKind: Duration],
                   lastRead: [ProviderKind: ContinuousClock.Instant],
                   now: ContinuousClock.Instant,
                   housekeeping: Duration = .seconds(30)) -> Duration {
    intervals.reduce(housekeeping) { next, entry in
        guard let last = lastRead[entry.key] else { return .zero }
        let remaining = max(0, seconds(entry.value) - seconds(from: last, to: now))
        return min(next, .seconds(remaining))
    }
}

func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: end)
    return Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
}

private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
}
~~~

- [ ] **Step 4: Verify the policy**

Run the Step 2 command again.

Expected: TEST SUCCEEDED.

- [ ] **Step 5: Commit**

~~~bash
git add Wattly/Core/PollPolicy.swift WattlyTests/PollPolicyTests.swift
git commit -m "feat: add provider-level polling policy"
~~~

### Task 2: Apply the policy without changing provider boundaries

**Files:**
- Modify: Wattly/Core/SystemMonitor.swift:41-263
- Test: WattlyTests/SystemMonitorTests.swift:15-45,230-321

**Interfaces:**
- Consumes: Task 1 functions, MetricProvider.read(at:), TemperatureGating.setEnabled(_:), SelfEnergySampling.energyNanojoules().
- Produces: SystemMonitor.pollScheduled(force:) async, SystemMonitor.pollScheduled(forceProviders:) async, and a targeted reschedule path; retains pollOnce() async as the all-active manual/test seam.

- [ ] **Step 1: Write failing monitor integration tests**

Add the fake and tests inside SystemMonitorTests.

~~~swift
actor CountingProvider: MetricProvider {
    let kind: ProviderKind
    private(set) var reads = 0
    init(kind: ProviderKind) { self.kind = kind }

    func read(at: ContinuousClock.Instant) async -> ProviderReading {
        reads += 1
        return .pending
    }
}

@Test func scheduledClosedMenubarPollReadsOnlySelectedProvider() async {
    let cpu = CountingProvider(kind: .cpu)
    let power = CountingProvider(kind: .power)
    let monitor = SystemMonitor(providers: [cpu, power], clock: ManualClock())

    await monitor.pollScheduled(force: false)

    #expect(await cpu.reads == 1)
    #expect(await power.reads == 0)
}

@Test func manualPollOnceStillReadsEveryActiveProvider() async {
    let cpu = CountingProvider(kind: .cpu)
    let power = CountingProvider(kind: .power)
    let monitor = SystemMonitor(providers: [cpu, power], clock: ManualClock())

    await monitor.pollOnce()

    #expect(await cpu.reads == 1)
    #expect(await power.reads == 1)
}

@Test func scheduledPollWaitsForTheProviderInterval() async {
    let cpu = CountingProvider(kind: .cpu)
    let clock = ManualClock()
    let monitor = SystemMonitor(providers: [cpu], clock: clock)

    await monitor.pollScheduled(force: false)
    clock.advance(by: .seconds(1))
    await monitor.pollScheduled(force: false)
    #expect(await cpu.reads == 1)

    clock.advance(by: .seconds(1))
    await monitor.pollScheduled(force: false)
    #expect(await cpu.reads == 2)
}

@Test func textOffPerformsNoMetricReads() async {
    let cpu = CountingProvider(kind: .cpu)
    let monitor = SystemMonitor(providers: [cpu], clock: ManualClock())

    await monitor.setMenubarTextEnabled(false)
    monitor.stop()
    await monitor.pollScheduled(force: false)

    #expect(await cpu.reads == 0)
}

@Test func forcedProviderRefreshDoesNotReadOtherScheduledProviders() async {
    let cpu = CountingProvider(kind: .cpu)
    let power = CountingProvider(kind: .power)
    let monitor = SystemMonitor(providers: [cpu, power], clock: ManualClock())

    await monitor.pollScheduled(forceProviders: [.power])

    #expect(await cpu.reads == 1)       // closed menu bar's normal CPU demand
    #expect(await power.reads == 1)     // explicit new-demand refresh only
}
~~~

- [ ] **Step 2: Run the focused suite and confirm it fails**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  test -only-testing:WattlyTests/SystemMonitorTests
~~~

Expected: build failure mentioning SystemMonitor has no member pollScheduled or no overload accepting forceProviders.

- [ ] **Step 3: Add scheduler state and replace the timer loop**

Add beside pollTask:

~~~swift
private static let selfPowerInterval: Duration = .seconds(30)
private var lastProviderRead: [ProviderKind: ContinuousClock.Instant] = [:]
private var lastSelfPowerSample: ContinuousClock.Instant?
~~~

Replace start() and the old currentInterval with:

~~~swift
func start() {
    start(forceProviders: nil)
}

private func start(forceProviders: Set<ProviderKind>?) {
    guard pollTask == nil else { return }
    let initial = forceProviders ?? Set(currentProviderIntervals.keys)
    pollTask = Task(priority: .utility) { [weak self] in
        var forced = initial
        while !Task.isCancelled {
            guard let self else { return }
            await self.pollScheduled(forceProviders: forced)
            self.sampleSelfPowerIfDue(at: self.clock.now())
            forced = []
            let delay = self.nextScheduledDelay(at: self.clock.now())
            try? await Task.sleep(for: delay, tolerance: delay / 5)
        }
    }
}

private var currentProviderIntervals: [ProviderKind: Duration] {
    let needs: Set<CardKind> = menubarTextEnabled ? menubarMetrics : []
    return providerIntervals(setting: pollSetting, panelVisible: panelVisible,
                             menubarTextEnabled: menubarTextEnabled,
                             active: activeProviderKinds, menubarNeeds: needs)
}

private func nextScheduledDelay(at instant: ContinuousClock.Instant) -> Duration {
    nextPollDelay(intervals: currentProviderIntervals, lastRead: lastProviderRead,
                  now: instant, housekeeping: Self.selfPowerInterval)
}

func pollScheduled(force: Bool) async {
    await pollScheduled(forceProviders: force ? Set(currentProviderIntervals.keys) : [])
}

func pollScheduled(forceProviders: Set<ProviderKind>) async {
    let instant = clock.now()
    let due = dueProviders(intervals: currentProviderIntervals, lastRead: lastProviderRead,
                           now: instant, force: false)
    await poll(kinds: due.union(forceProviders), at: instant)
}

private func poll(kinds: Set<ProviderKind>, at instant: ContinuousClock.Instant) async {
    for provider in providers where kinds.contains(provider.kind) {
        let reading = await provider.read(at: instant)
        lastProviderRead[provider.kind] = instant
        apply(reading, from: provider.kind, at: instant)
    }
}

func sampleSelfPowerIfDue(at instant: ContinuousClock.Instant) {
    guard lastSelfPowerSample.map({ seconds(from: $0, to: instant) >= 30 }) != false else { return }
    sampleSelfPower(at: instant)
    lastSelfPowerSample = instant
}
~~~

Replace pollOnce() with:

~~~swift
func pollOnce() async {
    await poll(kinds: activeProviderKinds, at: clock.now())
}
~~~

- [ ] **Step 4: Make refresh paths narrow and schedule-aware**

Replace reschedule() with this targeted version:

~~~swift
private func reschedule(forceProviders: Set<ProviderKind> = []) {
    stop()
    start(forceProviders: forceProviders)
}
~~~

In each of setPanelVisible(_:), setPollInterval(_:), setMenubarTextEnabled(_:), setShownCards(_:), and setMenubarMetrics(_:), capture currentProviderIntervals before and after the mutation. When the dictionaries differ, call reschedule(forceProviders:) with Set(after.keys).subtracting(before.keys). For a false → true panel transition, pass Set(after.keys) instead: every visible card needs an immediate sample. For a close or a mere fixed-interval edit, pass [] so due timing is preserved and no provider is unnecessarily read. A nonempty provider set returned by recomputeGating() also requires reschedule(forceProviders:) even when the interval dictionaries are equal.

Replace broad immediate refreshes in setMemoryProcessEnumeration(_:) and setPowerProcessEnumeration(_:) with:

~~~swift
if on { await poll(kinds: [.memory], at: clock.now()) }
~~~

and:

~~~swift
if on { await poll(kinds: [.power], at: clock.now()) }
~~~

Make recomputeGating() return Set<ProviderKind>. It must retain await tempGater?.setEnabled(want) and return newlyActivated plus [.temperature] when tempTurnedOn is true. The caller intersects that set with Set(after.keys) and unions it with newly scheduled keys before calling reschedule(forceProviders:). This preserves an immediate CPU/GPU temperature refresh when temperature was already active for batTemp, while still avoiding unrelated provider I/O.

- [ ] **Step 5: Verify focused and complete suites**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  test -only-testing:WattlyTests/SystemMonitorTests
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
~~~

Expected: both commands end with TEST SUCCEEDED, including history, temperature gate, self-power, and process-enumeration tests.

- [ ] **Step 6: Add and run the self-energy cadence test**

Extend the existing FakeSelfEnergy with private(set) var reads = 0 and increment reads in energyNanojoules(). Add this test; sampleSelfPowerIfDue is intentionally internal so it can be driven without a wall-clock timer.

~~~swift
@Test func scheduledSelfEnergySamplingIsCappedAtThirtySeconds() {
    let energy = FakeSelfEnergy(0)
    let clock = ManualClock()
    let monitor = SystemMonitor(providers: [], clock: clock, selfEnergy: energy)

    monitor.sampleSelfPowerIfDue(at: clock.now())
    clock.advance(by: .seconds(29))
    monitor.sampleSelfPowerIfDue(at: clock.now())
    #expect(energy.reads == 1)

    clock.advance(by: .seconds(1))
    monitor.sampleSelfPowerIfDue(at: clock.now())
    #expect(energy.reads == 2)
}
~~~

Run the Task 2 Step 5 focused command again.

Expected: TEST SUCCEEDED with the new cadence test.

- [ ] **Step 7: Commit**

~~~bash
git add Wattly/Core/SystemMonitor.swift WattlyTests/SystemMonitorTests.swift
git commit -m "feat: schedule metric providers by demand"
~~~

### Task 3: Explain and measure the new behavior

**Files:**
- Modify: Wattly/Settings/Settings.swift:1-28
- Modify: Wattly/Views/SettingsView.swift:360-377
- Modify: docs/self-power-baseline.md:1-30
- Test: WattlyTests/PanelPresentationTests.swift

**Interfaces:**
- Consumes: Task 1 cadence values and SystemMonitor.selfPower.
- Produces: automaticPollingDescription: String and a manual protocol that maps exactly to scheduler states.

- [ ] **Step 1: Write a failing copy test**

Append to PanelPresentationTests:

~~~swift
@Test func automaticPollingCopyMatchesProviderBudget() {
    #expect(automaticPollingDescription ==
        "자동: 패널 열림은 CPU·전력 1초/온도 2초/메모리·배터리 5초, 닫힘은 메뉴바에 표시한 지표만 2초마다 갱신합니다. 텍스트를 끄면 지표 폴링을 멈춥니다.")
}
~~~

- [ ] **Step 2: Verify the symbol is absent**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  test -only-testing:WattlyTests/PanelPresentationTests
~~~

Expected: build failure mentioning automaticPollingDescription.

- [ ] **Step 3: Implement the copy and document the procedure**

Add next to PollInterval in Settings.swift:

~~~swift
let automaticPollingDescription =
    "자동: 패널 열림은 CPU·전력 1초/온도 2초/메모리·배터리 5초, 닫힘은 메뉴바에 표시한 지표만 2초마다 갱신합니다. 텍스트를 끄면 지표 폴링을 멈춥니다."
~~~

Replace the hard-coded automatic-poll text in SettingsView with:

~~~swift
Text(automaticPollingDescription)
    .font(WattlyFont.at(11.5, weight: .regular))
    .foregroundStyle(t.faint)
    .fixedSize(horizontal: false, vertical: true)
~~~

Replace the procedure in docs/self-power-baseline.md with:

~~~markdown
## Procedure

1. Build **Release**, launch, and warm for 60 seconds on an otherwise-quiet Apple-Silicon Mac.
2. In each state, wait for one 30-second self-energy refresh, then record the value after a full 60-second observation window:
   - **OPEN** — CPU/SoC power 1s, temperature 2s, memory/battery 5s.
   - **CLOSED-menu** — popover closed, menu-bar CPU text on; only selected menu-bar providers update at 2s.
   - **CLOSED-idle** — popover closed, menu-bar text off; metric providers stop and only the 30-second self-energy sample wakes Wattly.
3. Record three runs per state and put their arithmetic mean in the table. Include commit, Mac model, macOS build, power source, and selected menu metrics in Notes.
4. Expected ordering is **OPEN ≥ CLOSED-menu ≥ CLOSED-idle**. It is observational because ri_energy_nj excludes WindowServer composition.
5. A matching-state three-run mean above prior baseline ×1.2 is a regression. The first post-change row must retain the pre-change row and have CLOSED-menu/CLOSED-idle no higher than their pre-change counterparts.
~~~

Rename table columns CLOSED-default/CLOSED-deep to CLOSED-menu/CLOSED-idle, and call the values 30-second process-energy averages.

- [ ] **Step 4: Verify and commit**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
git add Wattly/Settings/Settings.swift Wattly/Views/SettingsView.swift \
  WattlyTests/PanelPresentationTests.swift docs/self-power-baseline.md
git commit -m "docs: describe low-power polling behavior"
~~~

Expected: test command ends with TEST SUCCEEDED.

### Task 4: Record the release result

**Files:**
- Modify: docs/self-power-baseline.md:Recorded baselines table

**Interfaces:**
- Consumes: Release Wattly.app, Task 3 state definitions, settings footer value.
- Produces: one reproducible real-hardware release baseline row.

- [ ] **Step 1: Build Release**

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Release \
  -destination 'platform=macOS' build
~~~

Expected: BUILD SUCCEEDED.

- [ ] **Step 2: Measure without contaminating the result**

Use default CPU-only menu text and take three 60-second observations for OPEN, CLOSED-menu, and CLOSED-idle. Do not run powermetrics, Xcode Instruments, the thermal probe, or the differential script; those tools alter process or machine load.

- [ ] **Step 3: Write and commit only actual measurements**

Append a table row in this exact form, replacing every bracketed field with observed hardware data:

~~~markdown
| 2026-07-13 | [final commit] | [Mac model] / [macOS build] | [OPEN mean] W | [CLOSED-menu mean] W | [CLOSED-idle mean] W | Release, CPU-only menu metric, [battery or AC] |
~~~

Run and then commit:

~~~bash
git diff --check
git status --short
git add docs/self-power-baseline.md
git commit -m "docs: record low-power release baseline"
~~~

Expected: no whitespace errors and only docs/self-power-baseline.md is modified during this task.

## Self-review

- **Spec coverage:** Tasks 1–2 reduce provider I/O and self-energy wake-ups while preserving fixed intervals, history, gates, and refresh behavior. Tasks 3–4 make the behavior measurable and visible.
- **Placeholder scan:** There are no unbounded implementation placeholders. Bracketed fields occur only in Task 4's required manual hardware record and must be replaced by observed data before commit.
- **Type consistency:** Task 1 defines providerIntervals, dueProviders, and nextPollDelay; Task 2 consumes those exact names and exports pollScheduled(force:); Task 3 defines and tests automaticPollingDescription.
