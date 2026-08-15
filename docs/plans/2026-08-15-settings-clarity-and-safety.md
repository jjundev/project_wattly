# Settings Clarity and Safety Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Reorganize Wattly Settings around common display choices, make dependent and unsupported controls truthful, simplify memory status coloring to macOS pressure only, and make destructive reset explicit.

**Architecture:** Keep persisted preferences in the existing Settings/SettingsReset seams and make memory-pressure and polling-copy rules pure, testable functions. Restructure only SettingsView and reusable settings controls for presentation; no new dependency, screen, or persisted setting is introduced. SystemMonitor.isPresent(_:) remains the runtime capability signal.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI, Foundation UserDefaults/@AppStorage, Swift Testing, XcodeGen-managed macOS 14+ project.

## Global Constraints

- Target macOS 14.0+ on Apple Silicon and Swift 6 strict concurrency. Add no dependencies, entitlements, privileged helpers, or AppStorage keys.
- Work only in the existing Settings window and its testable presentation/model seams. Do not alter popover ordering, polling execution policy, fan-helper installation, or metric collection.
- Defaults.showBatteryEfficiency remains false, persisted, and resettable. Its control is subordinate to 배터리 and unavailable while the parent card is hidden.
- Memory card state color always uses MemorySample.pressure. If pressure is unavailable, return no warning/critical level; never use memory occupancy percent as a fallback.
- Remove the memory color toggle and memory occupancy warning/critical sliders. Thresholds decoder must ignore legacy mem and memColorByPressure JSON fields.
- Preserve if monitor.isPresent(.fan) { fanCurveSection }. Fan controls remain absent on fanless Macs; unsupported metric toggles remain visible, disabled, and explain why.
- Use these Korean terms exactly: 프로세서 전력, 백그라운드 갱신, 절전, 항상 최신, 전력 표시 안정화, 상태 경고 기준, 사용자 지정 팬 제어.
- No Settings footer: remove self-power and Created by jjundev. 기본값으로 되돌리기 is the final Settings element.
- Final test: xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test.
- Final build: xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build.

## File Structure

| File | Responsibility |
|---|---|
| Wattly/Settings/Settings.swift | Remove persisted memory occupancy state; decode legacy threshold data; produce selected polling-policy copy and result-focused mode labels. |
| Wattly/Core/CardPresentation.swift | Make memory coloring depend only on a kernel pressure verdict. |
| Wattly/Models/MetricSample.swift | Document pressure-only memory status behavior. |
| Wattly/Providers/MemoryProvider.swift | Correct the no-fallback pressure policy comment. |
| WattlyTests/ThresholdTests.swift | Prove pressure-only behavior, nil-pressure behavior, and legacy decoding. |
| WattlyTests/PanelPresentationTests.swift | Prove automatic and fixed polling copy. |
| WattlyTests/SettingsResetTests.swift | Retain reset coverage for the narrower threshold model. |
| Wattly/Views/SettingsComponents.swift | Add disabled, non-interactive behavior and caller-supplied visible/VoiceOver disabled reasons to setting toggles/chips. |
| Wattly/Views/SettingsView.swift | Reorder groups; revise copy; show capability/dependency states; merge update controls; confirm reset; remove footer. |

## Decision Checkpoint

No execution-level decision remains. The interview settled hierarchy, copy, feature removals, dependent/unsupported state, and reset behavior. Thresholds already manually decodes a dictionary, so ignoring unknown old JSON fields is safe.

---

### Task 1: Make memory status and polling descriptions truthful at pure seams

**Files:**

- Modify: Wattly/Settings/Settings.swift:20-140,231-271
- Modify: Wattly/Core/CardPresentation.swift:84-113
- Modify: Wattly/Models/MetricSample.swift:40-55
- Modify: Wattly/Providers/MemoryProvider.swift:41-48
- Modify: Wattly/Views/SettingsView.swift:620-650,770-790
- Modify: WattlyTests/ThresholdTests.swift:22-93
- Modify: WattlyTests/PanelPresentationTests.swift:53-67
- Modify: WattlyTests/SettingsResetTests.swift:29-58

**Interfaces:**

- Consumes: MemorySample.pressure, PollInterval, PowerMode, and persisted Thresholds raw JSON.
- Produces: pollingDescription(for:mode:) -> String; Thresholds(cpu:temp:); memory thresholdLevel returns a level only for non-nil pressure.

- [ ] **Step 1: Write failing pressure-only and polling-copy tests**

In WattlyTests/ThresholdTests.swift, replace the five memory tests that assert occupancy behavior or memColorByPressure persistence with:

~~~swift
@Test func memoryColorAlwaysUsesKernelPressure() {
    let th = Defaults.thresholds
    #expect(CardPresentation.thresholdLevel(.mem, mem(used: 8, total: 16, pressure: .critical), th) == .crit)
    #expect(CardPresentation.thresholdLevel(.mem, mem(used: 14, total: 16, pressure: .normal), th) == .normal)
    #expect(CardPresentation.thresholdLevel(.mem, mem(used: 8, total: 16, pressure: .warn), th) == .warn)
}

@Test func memoryColorIsNilWithoutKernelPressure() {
    #expect(CardPresentation.thresholdLevel(.mem, mem(used: 14, total: 16, pressure: nil), Defaults.thresholds) == nil)
}

@Test func thresholdsIgnoreRemovedMemoryFieldsWhenDecodingLegacyData() {
    let legacy = #"{"cpu":{"warn":70,"crit":90},"mem":{"warn":70,"crit":85},"temp":{"warn":70,"crit":90},"memColorByPressure":false}"#
    #expect(Thresholds(rawValue: legacy) == Thresholds(
        cpu: ThresholdPair(warn: 70, crit: 90),
        temp: ThresholdPair(warn: 70, crit: 90)))
}
~~~

Keep the equality test but mutate changed.temp.warn. Keep CPU, temperature, no-value, and ThresholdPair tests.

In WattlyTests/PanelPresentationTests.swift, replace the old automatic-only tests with:

~~~swift
@Test func automaticEcoPollingCopyMatchesProviderBudget() {
    #expect(pollingDescription(for: .auto, mode: .eco) ==
        "자동 · 절전: 패널을 열면 CPU·전력은 1초, 온도는 2초, 메모리·배터리는 5초마다 갱신합니다. 패널을 닫으면 메뉴바에 표시한 지표만 2초마다 갱신하며, 메뉴바 텍스트를 끄면 지표 갱신을 멈춥니다.")
}

@Test func automaticAlwaysLatestPollingCopyMatchesProviderBudget() {
    #expect(pollingDescription(for: .auto, mode: .performance) ==
        "자동 · 항상 최신: 패널을 열면 활성 지표를 1초마다 갱신합니다. 패널을 닫으면 메뉴바 텍스트 표시 시 2초마다, 끄면 5초마다 갱신합니다.")
}

@Test func fixedPollingCopyNamesTheSelectedInterval() {
    #expect(pollingDescription(for: .s1, mode: .eco) == "패널 상태와 관계없이 활성 지표를 1초마다 갱신합니다.")
    #expect(pollingDescription(for: .s2, mode: .performance) == "패널 상태와 관계없이 활성 지표를 2초마다 갱신합니다.")
    #expect(pollingDescription(for: .s5, mode: .eco) == "패널 상태와 관계없이 활성 지표를 5초마다 갱신합니다.")
}
~~~

- [ ] **Step 2: Run focused tests and verify they fail**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/ThresholdTests -only-testing:WattlyTests/PanelPresentationTests
~~~

Expected: compilation errors because Thresholds(cpu:temp:) and pollingDescription(for:mode:) do not exist; existing code also yields an occupancy-derived level when pressure is nil.

- [ ] **Step 3: Implement the narrower thresholds model and dynamic polling copy**

In Wattly/Settings/Settings.swift, change PowerMode labels to:

~~~swift
var label: String {
    switch self {
    case .eco: "절전"
    case .performance: "항상 최신"
    }
}
~~~

Replace pollingDescription with:

~~~swift
func pollingDescription(for setting: PollInterval, mode: PowerMode) -> String {
    switch setting {
    case .s1: "패널 상태와 관계없이 활성 지표를 1초마다 갱신합니다."
    case .s2: "패널 상태와 관계없이 활성 지표를 2초마다 갱신합니다."
    case .s5: "패널 상태와 관계없이 활성 지표를 5초마다 갱신합니다."
    case .auto:
        switch mode {
        case .eco:
            "자동 · 절전: 패널을 열면 CPU·전력은 1초, 온도는 2초, 메모리·배터리는 5초마다 갱신합니다. 패널을 닫으면 메뉴바에 표시한 지표만 2초마다 갱신하며, 메뉴바 텍스트를 끄면 지표 갱신을 멈춥니다."
        case .performance:
            "자동 · 항상 최신: 패널을 열면 활성 지표를 1초마다 갱신합니다. 패널을 닫으면 메뉴바 텍스트 표시 시 2초마다, 끄면 5초마다 갱신합니다."
        }
    }
}
~~~

Replace Thresholds with this schema. It deliberately ignores old unknown keys:

~~~swift
struct Thresholds: Equatable, Sendable, RawRepresentable {
    var cpu: ThresholdPair
    var temp: ThresholdPair

    init(cpu: ThresholdPair, temp: ThresholdPair) {
        self.cpu = cpu
        self.temp = temp
    }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cpuObject = object["cpu"] as? [String: Double],
              let tempObject = object["temp"] as? [String: Double],
              let cpuWarn = cpuObject["warn"], let cpuCrit = cpuObject["crit"],
              let tempWarn = tempObject["warn"], let tempCrit = tempObject["crit"]
        else { return nil }
        self.init(cpu: ThresholdPair(warn: cpuWarn, crit: cpuCrit),
                  temp: ThresholdPair(warn: tempWarn, crit: tempCrit))
    }

    var rawValue: String {
        let object: [String: [String: Double]] = [
            "cpu": ["warn": cpu.warn, "crit": cpu.crit],
            "temp": ["warn": temp.warn, "crit": temp.crit],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    static func == (lhs: Thresholds, rhs: Thresholds) -> Bool {
        lhs.cpu == rhs.cpu && lhs.temp == rhs.temp
    }
}
~~~

Change Defaults.thresholds to:

~~~swift
static let thresholds = Thresholds(
    cpu: ThresholdPair(warn: 70, crit: 90),
    temp: ThresholdPair(warn: 70, crit: 90))
~~~

- [ ] **Step 4: Make presentation pressure-only and align documentation**

In Wattly/Core/CardPresentation.swift, replace the memory case in thresholdLevel with:

~~~swift
case (.mem, .memory(let sample)):
    return sample.pressure?.thresholdLevel
~~~

Delete comments mentioning memColorByPressure or occupancy fallback. In Wattly/Models/MetricSample.swift, document that pressure nil produces no warning/critical memory color. In Wattly/Providers/MemoryProvider.swift, replace the pressure comment with:

~~~swift
// Kernel memory-pressure verdict. A failed sysctl yields nil; presentation keeps the
// memory card neutral rather than substituting an occupancy-based warning level.
~~~

Update SettingsResetTests only where it constructs or compares Thresholds; it must still assert decoded reset data equals Defaults.thresholds. To keep this task buildable after the public model API removal, make only these compatibility edits in Wattly/Views/SettingsView.swift: delete memoryThresholdBlock and memPressureBinding, remove the memory divider/block from thresholdSection, and call pollingDescription(for: pollInterval, mode: powerMode) in the still-separate pollSection. Do not reorder sections, change Settings control copy, or modify reusable components in this task; those remain Task 2 work.

- [ ] **Step 5: Run focused tests and verify they pass**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/ThresholdTests -only-testing:WattlyTests/PanelPresentationTests -only-testing:WattlyTests/SettingsResetTests
~~~

Expected: PASS. This proves fixed intervals no longer say automatic, legacy JSON remains readable, memory color never derives from used GB, and reset retains valid threshold data.

- [ ] **Step 6: Commit**

~~~bash
git add Wattly/Settings/Settings.swift Wattly/Core/CardPresentation.swift Wattly/Models/MetricSample.swift Wattly/Providers/MemoryProvider.swift WattlyTests/ThresholdTests.swift WattlyTests/PanelPresentationTests.swift WattlyTests/SettingsResetTests.swift
git commit -m "feat(settings): simplify memory status and polling copy"
~~~

### Task 2: Restructure Settings and make every control's state truthful

**Files:**

- Modify: Wattly/Views/SettingsComponents.swift:46-156,211-248
- Modify: Wattly/Views/SettingsView.swift:70-827

**Interfaces:**

- Consumes: monitor.isPresent(_:), pollingDescription(for:mode:), SettingsReset.applyDefaults(login:).
- Produces: SettingsToggleRow(isOn:divider:isEnabled:disabledReason:label:) and WattlyChip(label:isOn:isEnabled:disabledReason:action:); Settings ordered General → Display → Behavior → Advanced → confirmed reset.

- [ ] **Step 1: Add enabled state to reusable setting controls**

Give WattlyToggle and SettingsToggleRow a required isEnabled Bool (default true only on SettingsToggleRow). Give SettingsToggleRow disabledReason: String? = nil. Pass isEnabled into the switch and use this interaction block:

~~~swift
.contentShape(Rectangle())
.onTapGesture { guard isEnabled else { return }; toggle() }
.focusable(isEnabled)
.focused($focused)
.onKeyPress(.space) { guard isEnabled else { return .ignored }; toggle(); return .handled }
.onKeyPress(.return) { guard isEnabled else { return .ignored }; toggle(); return .handled }
.opacity(isEnabled ? 1 : 0.5)
.wattlyFocusRing(focused, cornerRadius: 11)
.accessibilityHidden(true)
~~~

At the end of SettingsToggleRow use:

~~~swift
.opacity(isEnabled ? 1 : 0.55)
.accessibilityElement(children: .combine)
.accessibilityValue(isOn ? "켜짐" : "꺼짐")
.accessibilityAddTraits(isEnabled ? .isButton : .isStaticText)
.accessibilityHint(isEnabled ? "" : (disabledReason ?? "사용할 수 없습니다"))
.accessibilityAction { guard isEnabled else { return }; isOn.toggle() }
~~~

Give WattlyChip a stored isEnabled Bool defaulting to true and disabledReason: String? = nil. Guard tap, Space, Return, and accessibility actions; use focusable(isEnabled), opacity(isEnabled ? 1 : 0.45), and this accessibility hint:

~~~swift
.accessibilityHint(isEnabled ? "" : (disabledReason ?? "사용할 수 없습니다"))
~~~

Disabled chips must never mutate their selected setting.

- [ ] **Step 2: Build after the reusable-control API change**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
~~~

Expected: fix the internal switch construction to WattlyToggle(isOn: $isOn, isEnabled: isEnabled), then receive ** BUILD SUCCEEDED **.

- [ ] **Step 3: Rebuild group order and remove obsolete visual sections**

Replace SettingsView body content with:

~~~swift
VStack(alignment: .leading, spacing: 18) {
    generalSection
    displayGroup
    behaviorGroup
    advancedGroup
    resetButton
}
~~~

Keep Display order as themeSection, layoutSection, showSection, memoryProcessLimitSection, menubarSection. Define:

~~~swift
private var behaviorGroup: some View {
    VStack(alignment: .leading, spacing: 18) {
        SettingsGroupHeader(title: "동작")
        backgroundUpdateSection
        smoothingSection
    }
}

private var advancedGroup: some View {
    VStack(alignment: .leading, spacing: 18) {
        SettingsGroupHeader(title: "고급")
        thresholdSection
        if monitor.isPresent(.fan) { fanCurveSection }
    }
}
~~~

Delete powerModeSection, pollSection, footer, and selfPowerText. Task 1 has already removed memoryThresholdBlock and memPressureBinding; do not reintroduce them. Rename smoothing title and row title to 전력 표시 안정화 and use:

~~~swift
"순간적인 변동을 줄여 지속적인 전력 사용량을 보기 쉽게 표시합니다. 측정 방식은 바뀌지 않습니다."
~~~

Rename thresholdSection to 상태 경고 기준. Keep CPU and temperature blocks only; delete memory block and adjacent divider.

- [ ] **Step 4: Implement agreed display-state behavior and copy**

Add and render layoutDescription below the layout segment:

~~~swift
private var layoutDescription: String {
    switch panelMode {
    case .a:
        "각 지표를 세로로 표시합니다. 카드 펼침과 순서 변경을 사용할 수 있습니다."
    case .b:
        "여러 지표를 한눈에 비교하기 좋습니다. 카드 순서는 스택 행 레이아웃에서 팝오버의 편집 버튼으로 변경할 수 있습니다."
    case .c:
        "선택한 지표를 크게 보고 나머지는 목록으로 표시합니다. 카드 순서는 스택 행 레이아웃에서 팝오버의 편집 버튼으로 변경할 수 있습니다."
    }
}
~~~

Add metricToggle and use it for all eight card rows:

~~~swift
private func metricToggle(_ card: CardKind, isOn: Binding<Bool>, divider: Bool,
                          title: String, suffix: String? = nil) -> some View {
    let isAvailable = monitor.isPresent(card)
    return SettingsToggleRow(isOn: isOn, divider: divider, isEnabled: isAvailable,
                             disabledReason: isAvailable ? nil : "이 Mac에서는 사용할 수 없습니다") {
        VStack(alignment: .leading, spacing: 2) {
            if let suffix { rowTitleWithSuffix(title, suffix) } else { rowTitle(title) }
            if !isAvailable {
                Text("이 Mac에서는 사용할 수 없음")
                    .font(WattlyFont.at(11.5, weight: .regular))
                    .foregroundStyle(t.faint)
            }
        }
    }
}
~~~

The power metric uses title 프로세서 전력. For every unavailable metric row, call SettingsToggleRow with disabledReason: "이 Mac에서는 사용할 수 없습니다" and render the same sentence below its title. Battery efficiency directly follows battery and has 14-point left indentation. Compute its exact disabled state before rendering:

~~~swift
private var batteryEfficiencyDisabledReason: String? {
    if !showBattery { return "배터리 표시를 켜면 사용할 수 있습니다." }
    if !monitor.isPresent(.battery) { return "이 Mac에서는 사용할 수 없습니다" }
    return nil
}
~~~

Pass isEnabled: batteryEfficiencyDisabledReason == nil and disabledReason: batteryEfficiencyDisabledReason to the row, and render that same non-nil reason below its title. Preserve the efficiency value when disabled.

Rename the memory section to 메모리 카드 펼침 목록, its label to 표시할 앱 수, and add:

~~~swift
"메모리 카드를 펼쳤을 때 사용량이 큰 앱부터 표시합니다."
~~~

For panelMode == .b add 카드 그리드에서는 메모리 카드 펼침 목록을 볼 수 없습니다. Keep the 3...7 segment and storage.

For every card-backed menu chip, compute the disabled reason through this helper, then pass both isEnabled: disabledReason == nil and disabledReason: disabledReason to WattlyChip:

~~~swift
private func menuChipDisabledReason(for card: CardKind) -> String? {
    if !menubarText { return "텍스트 표시를 켜면 선택한 지표가 아이콘 옆에 표시됩니다." }
    if !monitor.isPresent(card) { return "이 Mac에서는 사용할 수 없습니다" }
    return nil
}
~~~

For CPU cluster-clock chips, pass the text-display reason when menubarText is false and nil otherwise. When menubarText is false, display:

~~~swift
"텍스트 표시를 켜면 선택한 지표가 아이콘 옆에 표시됩니다."
~~~

Change fan copy to:

~~~swift
rowTitle("사용자 지정 팬 제어")
Text("Wattly가 macOS 기본 제어 대신 아래 곡선을 적용합니다. 처음 켤 때 관리자 인증이 필요합니다.")
~~~

Do not alter fan live status, installer, graph, or zero-RPM help.

- [ ] **Step 5: Merge background controls and add reset confirmation**

Replace the two update sections with:

~~~swift
private var backgroundUpdateSection: some View {
    SettingsSection(title: "백그라운드 갱신") {
        SettingsCard(padding: Tokens.cardPadding) {
            VStack(alignment: .leading, spacing: 10) {
                WattlySegment(selection: $powerMode, options: [
                    (.eco, PowerMode.eco.label),
                    (.performance, PowerMode.performance.label),
                ])
                Rectangle().fill(t.line).frame(height: 1)
                Text("갱신 주기")
                    .font(WattlyFont.at(11.5, weight: .regular))
                    .foregroundStyle(t.faint)
                WattlySegment(selection: $pollInterval,
                              options: PollInterval.allCases.map { ($0, $0.label) },
                              pillVPadding: 6)
                Text(pollingDescription(for: pollInterval, mode: powerMode))
                    .font(WattlyFont.at(11.5, weight: .regular))
                    .foregroundStyle(t.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
~~~

Add:

~~~swift
@State private var isResetConfirmationPresented = false

private func applyDefaults() {
    SettingsReset.applyDefaults(login: loginItem)
    loginMirror = loginItem.isEnabled
}
~~~

The reset button only sets isResetConfirmationPresented = true. Attach this alert:

~~~swift
.alert("모든 Wattly 설정을 기본값으로 되돌릴까요?",
       isPresented: $isResetConfirmationPresented) {
    Button("기본값으로 되돌리기", role: .destructive) { applyDefaults() }
    Button("취소", role: .cancel) {}
} message: {
    Text("카드 표시, 메뉴바, 경고 기준, 팬 커브 및 자동 실행 설정이 초기화됩니다.")
}
~~~

Under 로그인 시 자동 실행 add Mac에 로그인하면 Wattly가 메뉴 막대에서 자동으로 시작됩니다. Update the top comment to describe 일반 · 표시 · 동작 · 고급 · 되돌리기.

- [ ] **Step 6: Build and perform the required manual Settings pass**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
~~~

Expected: ** BUILD SUCCEEDED **.

Launch the Debug app and verify:

- Order is 일반 → 표시 → 동작 → 고급 → 기본값 복원, with no footer.
- A explains card expansion/reorder; B and C say reorder lives in the stack layout.
- Hiding 배터리 dims and blocks 배터리 효율 보기 without losing its stored value.
- Disabling menu text dims/blocks chips, preserves selections, and shows the agreed help text.
- In a fanless/desktop scenario, the fan curve is hidden while a not-present metric is visible, disabled, and says 이 Mac에서는 사용할 수 없음.
- With VoiceOver enabled, focus a battery-efficiency row disabled by its parent, a menu chip disabled by text visibility, and a menu chip disabled by unavailable hardware. Each must announce its own matching disabled reason, never one of the other two reasons.
- Memory controls are absent from 상태 경고 기준; CPU and temperature remain.
- Fixed 1/2/5-second settings never show 자동; reset Alert Cancel does nothing and destructive reset restores all values.

- [ ] **Step 7: Commit**

~~~bash
git add Wattly/Views/SettingsComponents.swift Wattly/Views/SettingsView.swift
git commit -m "feat(settings): clarify controls and reset safety"
~~~

### Task 3: Run regression checks and inspect the delivered screen

**Files:**

- Modify: none unless verification finds a defect in Tasks 1 or 2.
- Test: complete WattlyTests bundle.

**Interfaces:**

- Consumes: completed Tasks 1 and 2.
- Produces: functional and visual verification evidence, no API.

- [ ] **Step 1: Run the complete Swift Testing suite**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
~~~

Expected: ** TEST SUCCEEDED **. A build does not substitute for this test evidence.

- [ ] **Step 2: Run target-scoped whitespace validation**

Run:

~~~bash
git diff --check HEAD~2..HEAD -- Wattly/Settings/Settings.swift Wattly/Core/CardPresentation.swift Wattly/Models/MetricSample.swift Wattly/Providers/MemoryProvider.swift Wattly/Views/SettingsComponents.swift Wattly/Views/SettingsView.swift WattlyTests/ThresholdTests.swift WattlyTests/PanelPresentationTests.swift WattlyTests/SettingsResetTests.swift
~~~

Expected: no output and exit code 0. If the implementation uses a different number of commits, replace HEAD~2..HEAD with the explicit range of Tasks 1 and 2.

- [ ] **Step 3: Capture visual QA evidence**

With the app running in a representative laptop scenario, capture the 440-point Settings window showing group headers, always-expanded advanced sections, and reset. Repeat in a fanless/desktop scenario for the unavailable metric state. Inspect captures at full size for clipped Korean copy, broken separators, unwanted wrapping, or a footer.

- [ ] **Step 4: Commit only a verification fix if needed**

If a correction is required:

~~~bash
git add Wattly/Views/SettingsView.swift Wattly/Views/SettingsComponents.swift
git commit -m "fix(settings): correct verified control state"
~~~

If no correction is required, do not create an empty commit.

## Self-Review

### Spec coverage

- Order, always-visible advanced settings, merged updates, and final reset: Task 2, Steps 3 and 5.
- Battery/menu dependencies, layout/reorder explanation, memory-list copy, and unavailable controls: Task 2, Step 4.
- Copy changes for general, power, polling, thresholds, and fan control: Tasks 1 and 2.
- Pressure-only memory behavior and full removal of its obsolete settings: Task 1 and Task 2, Step 3.
- Reset confirmation and footer removal: Task 2, Step 5.
- Unit, build, suite, diff, and visual validation: Tasks 1 through 3.

### Placeholder scan

No unfinished marker, generic error-handling instruction, or unspecified test placeholder remains. Every code action has exact source, code, copy, and a verification command.

### Type consistency

- pollingDescription(for:mode:) is introduced in Task 1 and consumed by backgroundUpdateSection in Task 2.
- Thresholds(cpu:temp:) is introduced in Task 1 and used by its legacy-decoding test.
- SettingsToggleRow and WattlyChip isEnabled/disabledReason parameters are introduced before updated Settings call sites in Task 2.
