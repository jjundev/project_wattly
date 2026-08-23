# 배터리 충전 제한 — 토글 OFF에서도 하위 항목 노출 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 설정 › 배터리 충전 제어에서 "배터리 충전 제한" 토글이 꺼져 있어도 하위 항목(최대 충전 한도 선택기, 상태 표시 줄, 안내 배너)이 계속 보이도록 하고, 꺼짐 상태에서는 조작할 수 없는 부분만 딤 처리한다.

**Architecture:** 표시 여부·딤 여부·상태 점 색/문구를 순수 함수로 뽑아 `Wattly/Core/BatterySectionPresentation.swift`에 두고 테이블 테스트한다(레포의 `CardPresentation`/`Accessibility`/`BatteryControlPolicy` 패턴). 공유 컴포넌트 `WattlySegment`에는 `WattlyChip`/`WattlyToggle`이 이미 갖고 있는 `isEnabled`/`disabledReason` 파라미터를 같은 모양으로 추가한다. `SettingsBatterySection`은 이 둘을 배선만 한다 — 뷰에는 판단 로직을 남기지 않는다.

**Tech Stack:** SwiftUI (macOS 14+), Swift 6 strict concurrency, Swift Testing (`import Testing`), XcodeGen (`project.yml` → `Wattly.xcodeproj`)

## Global Constraints

- 배포 타깃 macOS 14.0, `SWIFT_VERSION 6.0` (strict concurrency complete). 새 API는 14.0에서 사용 가능해야 한다.
- 새 외부 의존성 금지.
- 모든 사용자 노출 문구는 한국어. 기존 문구는 **글자 그대로** 재사용하고 새로 만들지 않는다.
- `project.yml`이 프로젝트 파일의 소스 오브 트루스. 새 파일을 추가한 태스크는 `xcodegen generate`를 실행하고 `Wattly.xcodeproj/project.pbxproj`도 함께 커밋한다.
- 순수 판단 로직은 `Wattly/Core/`에 두고 `WattlyTests/`에서 `@testable import Wattly`로 테스트한다. SwiftUI 뷰 자체를 테스트하는 하네스는 이 레포에 없다.
- 브랜치: `feat/battery-charge-limit` (현재 브랜치 그대로 작업).
- 확정된 UX 결정 3건 (2026-08-23 사용자 결정):
  1. 꺼짐 상태에서 한도 세그먼트는 **보이되 비활성(딤)**.
  2. 꺼짐 상태에서 상태 표시 줄은 **보이되 회색 점**.
  3. 하드웨어 미지원 Mac에서는 하위 항목을 **계속 숨김**(현재 동작 유지).

---

## File Structure

| 파일 | 역할 |
| --- | --- |
| `Wattly/Core/BatterySectionPresentation.swift` (신규) | 순수 판단: 하위 항목 노출 여부, 한도 선택기 활성 여부/비활성 사유, 상태 점+문구, 도우미 설치 버튼 노출 여부, 상태 폴링 여부 |
| `WattlyTests/BatterySectionPresentationTests.swift` (신규) | 위 순수 함수의 테이블 테스트 |
| `Wattly/Views/SettingsComponents.swift` (수정) | `WattlySegment`에 `isEnabled`/`disabledReason` 추가 (`WattlyChip`과 동일한 모양) |
| `Wattly/Views/Settings/SettingsBatterySection.swift` (수정) | 위 둘로 배선. 표시 게이트를 `batteryLimitEnabled` → 하드웨어 지원 여부로 교체 |
| `project.yml` | 수정 없음 (`sources: - path: Wattly`가 폴더 참조라 신규 파일 자동 포함). 단 `xcodegen generate` 재실행 필요 |

### 결정 근거 메모 (구현자가 다시 고민하지 않도록)

- **왜 순수 타입을 새로 만드나:** 뷰 안의 `if`로 두면 검증할 방법이 없다. 이 레포는 `CardPresentation`, `Accessibility`, `MenuBarText`, `BatteryControlPolicy` 전부 같은 방식으로 순수 함수 + 테이블 테스트를 쓴다.
- **왜 꺼짐 상태에서 상태 문구를 상수로 고정하나:** 데몬은 `config.enabled == false`이면 `detail`을 항상 `"충전 제한 비활성화됨"`으로 돌려준다 (`FanControlShared/BatteryControlEngine.swift:208`). 즉 꺼짐 상태의 문구는 원래부터 상수다. 반면 도우미가 아예 설치되지 않았을 때는 클라이언트가 `"도우미에 연결되지 않음"` + `.unavailable`(빨간 점)을 넣는데, 사용자가 **일부러 꺼둔** 기능에 빨간 경고를 띄우는 건 오해를 부른다. 그래서 꺼짐 상태에서는 모드와 무관하게 회색 점 + `"충전 제한 비활성화됨"`으로 고정한다.
- **왜 꺼짐 상태에서는 폴링하지 않나:** 위와 같은 이유로 꺼짐 상태의 상태 줄은 절대 바뀌지 않는다. 폴링은 `batteryStatus` XPC → 데몬의 `sampleBatteryAndEvaluate(force: true)` → IOKit 전원 소스 읽기를 5초마다 유발한다 (`WattlyFanDaemon/FanControlDaemon.swift:161-177`). 바뀌지 않을 값을 위해 IOKit을 돌릴 이유가 없다. 현재 코드도 이미 꺼짐일 때 폴링하지 않으므로 **동작 변경 없음**이다.
- **왜 꺼짐 상태에서 "도우미 설치" 버튼을 숨기나:** 이 버튼은 관리자 암호 프롬프트를 띄운다. 꺼져 있는 기능 때문에 암호를 묻는 건 곤란하고, 토글을 켜는 경로(`onChange`)가 이미 설치를 수행하므로 잃는 기능도 없다.
- **`WattlySegment`의 새 파라미터를 `pillVPadding` 뒤에 두는 이유:** 기존 8개 호출부가 전부 `selection` → `options` → `fontSize` → `pillVPadding` 순의 라벨 인자를 쓴다. 뒤에 붙이면 멤버와이즈 이니셜라이저 순서가 유지되어 한 곳도 고칠 필요가 없다.

---

## Task 1: 순수 표시 판단 타입 `BatterySectionPresentation`

**Files:**
- Create: `Wattly/Core/BatterySectionPresentation.swift`
- Test: `WattlyTests/BatterySectionPresentationTests.swift`

**Interfaces:**
- Consumes: `BatteryControlServiceMode` (`FanControlShared/BatteryControlProtocol.swift:46`) — `.unavailable` / `.charging` / `.inhibited` / `.unsupported`. FanControlShared는 Wattly 타깃에 직접 컴파일되므로 `@testable import Wattly`만으로 접근된다.
- Produces (Task 3이 그대로 호출한다):
  - `BatterySectionPresentation.Dot` — `case green, orange, red, faint` (`String` raw, `Equatable`)
  - `BatterySectionPresentation.Status` — `struct { let dot: Dot; let text: String }` (`Equatable`)
  - `static func areDetailsVisible(isHardwareSupported: Bool?) -> Bool`
  - `static func isLimitPickerEnabled(isLimitOn: Bool) -> Bool`
  - `static func limitPickerDisabledReason(isLimitOn: Bool) -> String?`
  - `static func status(isLimitOn: Bool, isInstalling: Bool, mode: BatteryControlServiceMode, detail: String) -> Status`
  - `static func isInstallButtonVisible(isLimitOn: Bool, mode: BatteryControlServiceMode) -> Bool`
  - `static func shouldPollStatus(isLimitOn: Bool) -> Bool`

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`WattlyTests/BatterySectionPresentationTests.swift` 파일을 새로 만들고 아래 내용을 그대로 넣는다.

```swift
import Testing
import Foundation
@testable import Wattly

@Suite struct BatterySectionPresentationTests {

    // MARK: - 하위 항목 노출

    @Test func detailsAreVisibleWhenHardwareSupportIsTrueOrUnknown() {
        // nil = 도우미가 아직 답하지 않았거나 구버전이라 말해줄 수 없는 상태.
        // "모른다"를 "불가능하다"로 취급하면 정상 Mac에서 UI가 사라진다.
        #expect(BatterySectionPresentation.areDetailsVisible(isHardwareSupported: true) == true)
        #expect(BatterySectionPresentation.areDetailsVisible(isHardwareSupported: nil) == true)
    }

    @Test func detailsAreHiddenOnlyOnAnExplicitNo() {
        #expect(BatterySectionPresentation.areDetailsVisible(isHardwareSupported: false) == false)
    }

    // MARK: - 한도 선택기

    @Test func limitPickerFollowsTheToggle() {
        #expect(BatterySectionPresentation.isLimitPickerEnabled(isLimitOn: true) == true)
        #expect(BatterySectionPresentation.isLimitPickerEnabled(isLimitOn: false) == false)
    }

    @Test func limitPickerExplainsItselfOnlyWhenDisabled() {
        #expect(BatterySectionPresentation.limitPickerDisabledReason(isLimitOn: true) == nil)
        #expect(BatterySectionPresentation.limitPickerDisabledReason(isLimitOn: false)
                == "충전 제한을 켜면 한도를 조절할 수 있습니다.")
    }

    // MARK: - 상태 줄

    @Test func installingOutranksEverything() {
        // 설치 중에는 토글이 이미 ON이지만, 순서가 뒤집히면 설치 진행 표시가 사라진다.
        for isOn in [true, false] {
            let s = BatterySectionPresentation.status(isLimitOn: isOn, isInstalling: true,
                                                     mode: .unavailable, detail: "도우미에 연결되지 않음")
            #expect(s == .init(dot: .orange, text: "도우미 설치 중…"))
        }
    }

    @Test func offStateIsAlwaysGreyAndConstant() {
        // 데몬이 꺼짐 상태에서 돌려주는 문구와 같은 상수. 도우미가 없어서 .unavailable(빨강)이
        // 들어와도 사용자가 일부러 끈 기능에 경고를 띄우지 않는다.
        let modes: [BatteryControlServiceMode] = [.unavailable, .charging, .inhibited, .unsupported]
        for mode in modes {
            let s = BatterySectionPresentation.status(isLimitOn: false, isInstalling: false,
                                                     mode: mode, detail: "무시되어야 하는 문구")
            #expect(s == .init(dot: .faint, text: "충전 제한 비활성화됨"))
        }
    }

    @Test func onStateMapsModeToDotAndPassesDetailThrough() {
        let cases: [(BatteryControlServiceMode, BatterySectionPresentation.Dot)] = [
            (.inhibited, .orange),
            (.charging, .green),
            (.unavailable, .red),
            (.unsupported, .faint),
        ]
        for (mode, dot) in cases {
            let s = BatterySectionPresentation.status(isLimitOn: true, isInstalling: false,
                                                     mode: mode, detail: "데몬 문구")
            #expect(s == .init(dot: dot, text: "데몬 문구"))
        }
    }

    // MARK: - 도우미 설치 버튼

    @Test func installButtonAppearsOnlyWhenTheFeatureIsOnAndTheHelperIsMissing() {
        #expect(BatterySectionPresentation.isInstallButtonVisible(isLimitOn: true, mode: .unavailable) == true)
        #expect(BatterySectionPresentation.isInstallButtonVisible(isLimitOn: true, mode: .charging) == false)
        // 꺼져 있으면 관리자 암호를 물을 이유가 없다 — 토글을 켜는 경로가 설치를 수행한다.
        #expect(BatterySectionPresentation.isInstallButtonVisible(isLimitOn: false, mode: .unavailable) == false)
    }

    // MARK: - 폴링

    @Test func pollingRunsOnlyWhileTheLimitIsOn() {
        // 꺼짐 상태의 문구는 상수라 폴링해도 바뀌지 않는다. 폴링 한 번은 데몬의 IOKit 전원 소스
        // 읽기를 유발하므로, 바뀌지 않을 값을 위해 돌리지 않는다.
        #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: true) == true)
        #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: false) == false)
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

먼저 새 테스트 파일을 프로젝트에 넣는다:

```bash
xcodegen generate
```

그다음:

```bash
xcodebuild test -scheme Wattly -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -30
```

Expected: 컴파일 실패 — `cannot find 'BatterySectionPresentation' in scope`

- [ ] **Step 3: 최소 구현을 작성한다**

`Wattly/Core/BatterySectionPresentation.swift` 파일을 새로 만들고 아래 내용을 그대로 넣는다.

```swift
import Foundation

/// 설정 › 배터리 충전 제어 섹션의 순수 표시 판단. SwiftUI도 I/O도 없다 —
/// `CardPresentation` / `Accessibility` / `BatteryControlPolicy`와 같은 방식으로,
/// 뷰가 내리던 결정을 테이블 테스트가 가능한 함수로 옮겨둔 것이다.
///
/// 배경: 예전에는 하위 항목 전체가 `batteryLimitEnabled` 뒤에 숨어 있어서, 토글을 켜기 전에는
/// 이 기능이 무엇을 하는지 볼 수 없었다. 이제 하위 항목은 항상 보이고, **조작할 수 없는 부분만**
/// 비활성으로 표시한다.
enum BatterySectionPresentation {

    /// 상태 점의 의미. 색이 아니라 의미를 돌려주므로 테스트가 `Color`에 의존하지 않는다.
    enum Dot: String, Equatable {
        case green, orange, red, faint
    }

    struct Status: Equatable {
        let dot: Dot
        let text: String

        init(dot: Dot, text: String) {
            self.dot = dot
            self.text = text
        }
    }

    /// 꺼짐 상태에서 상태 줄에 고정으로 띄우는 문구. 데몬이 `config.enabled == false`일 때
    /// 돌려주는 `detail`과 같은 문자열이다 (`BatteryControlEngine.detailText`).
    static let disabledStatusText = "충전 제한 비활성화됨"

    /// 하위 항목(한도 선택기 · 상태 줄 · 안내 배너)을 그릴지 여부.
    ///
    /// 명시적인 `false`만 숨긴다. `nil`은 "도우미가 아직 답하지 않았다"이며, 답이 없다는 이유로
    /// Mac을 불가능하다고 단정하면 정상 하드웨어에서 UI가 사라진다.
    static func areDetailsVisible(isHardwareSupported: Bool?) -> Bool {
        isHardwareSupported != false
    }

    /// 한도 선택기를 조작할 수 있는지. 꺼짐 상태에서는 보이되 만질 수 없다.
    static func isLimitPickerEnabled(isLimitOn: Bool) -> Bool {
        isLimitOn
    }

    /// 비활성 상태의 사유 문구 (VoiceOver 힌트로도 쓰인다). 활성일 때는 `nil`.
    static func limitPickerDisabledReason(isLimitOn: Bool) -> String? {
        isLimitOn ? nil : "충전 제한을 켜면 한도를 조절할 수 있습니다."
    }

    /// 상태 점 + 문구.
    ///
    /// 순서가 의미를 갖는다. 설치 중이 가장 위 — 설치 중에는 토글이 이미 ON이지만 그 진행을
    /// 덮어쓰면 안 된다. 그다음이 꺼짐: 꺼짐 상태에서는 모드를 아예 보지 않고 회색 점 + 고정
    /// 문구를 쓴다. 도우미가 없을 때 들어오는 `.unavailable`(빨간 점 + "도우미에 연결되지 않음")을
    /// 사용자가 **일부러 끈** 기능 옆에 띄우면 고장으로 읽히기 때문이다.
    static func status(isLimitOn: Bool,
                       isInstalling: Bool,
                       mode: BatteryControlServiceMode,
                       detail: String) -> Status {
        if isInstalling { return Status(dot: .orange, text: "도우미 설치 중…") }
        if !isLimitOn { return Status(dot: .faint, text: disabledStatusText) }
        switch mode {
        case .inhibited: return Status(dot: .orange, text: detail)
        case .charging: return Status(dot: .green, text: detail)
        case .unavailable: return Status(dot: .red, text: detail)
        case .unsupported: return Status(dot: .faint, text: detail)
        }
    }

    /// "도우미 설치" 복구 버튼을 띄울지 여부. 이 버튼은 관리자 암호 프롬프트를 띄우므로,
    /// 사용자가 켜지도 않은 기능 때문에 암호를 묻지 않는다. 토글을 켜는 경로가 이미 설치를
    /// 수행하니 잃는 기능도 없다.
    static func isInstallButtonVisible(isLimitOn: Bool, mode: BatteryControlServiceMode) -> Bool {
        isLimitOn && mode == .unavailable
    }

    /// 설정 화면이 상태를 주기적으로 다시 읽어야 하는지.
    ///
    /// 꺼짐 상태의 문구는 상수라 폴링해도 절대 바뀌지 않는다. 반면 폴링 한 번은
    /// `batteryStatus` XPC → 데몬의 `sampleBatteryAndEvaluate(force: true)` → IOKit 전원 소스
    /// 읽기를 유발한다. 바뀌지 않을 값을 위해 그 비용을 낼 이유가 없다.
    static func shouldPollStatus(isLimitOn: Bool) -> Bool {
        isLimitOn
    }
}
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

```bash
xcodegen generate && xcodebuild test -scheme Wattly -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`. 새 테스트 9개가 추가되어 총 개수가 그만큼 늘어야 한다. 기존 테스트는 하나도 깨지지 않아야 한다(이 태스크는 뷰를 건드리지 않는다).

- [ ] **Step 5: 커밋한다**

```bash
git add Wattly/Core/BatterySectionPresentation.swift WattlyTests/BatterySectionPresentationTests.swift Wattly.xcodeproj/project.pbxproj && git commit -m "feat(battery): add pure presentation rules for the settings section"
```

---

## Task 2: `WattlySegment`에 비활성 상태 추가

**Files:**
- Modify: `Wattly/Views/SettingsComponents.swift:92-139` (`WattlySegment`)

**Interfaces:**
- Consumes: 없음 (독립적인 컴포넌트 변경)
- Produces (Task 3이 쓴다): `WattlySegment(selection:options:fontSize:pillVPadding:isEnabled:disabledReason:)` — `isEnabled: Bool = true`, `disabledReason: String? = nil`

**테스트 없음에 대한 안내 (구현자는 이 문단을 읽고 넘어갈 것):** `WattlySegment`는 SwiftUI 뷰이고 이 레포에는 뷰를 검사하는 테스트 하네스(ViewInspector 등)가 없다. 이미 같은 파라미터를 가진 `WattlyChip`(`SettingsComponents.swift:143`)과 `WattlyToggle`(`:52`)도 단위 테스트가 없다. 그래서 이 태스크의 검증은 "빌드 + 전체 스위트 그린 + 나머지 8개 호출부가 한 글자도 바뀌지 않았음"이다. 새 테스트를 만들어내려고 하지 말 것 — 의미 있는 어서션을 쓸 수 없다.

- [ ] **Step 1: 변경 전 기준선을 기록한다**

```bash
grep -rn "WattlySegment(" --include="*.swift" Wattly/ | grep -v "struct WattlySegment"
```

Expected: 9개 호출부. 이 목록을 적어둔다 — Step 4에서 그대로여야 한다.

```bash
xcodebuild test -scheme Wattly -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **` (Task 1의 테스트 포함)

- [ ] **Step 2: `WattlySegment`를 교체한다**

`Wattly/Views/SettingsComponents.swift`에서 `struct WattlySegment` 전체(현재 92–139행)를 아래로 바꾼다. 새 저장 프로퍼티는 반드시 `pillVPadding` **뒤에** 온다 — 멤버와이즈 이니셜라이저의 인자 순서가 유지되어야 기존 호출부 8곳이 그대로 컴파일된다.

```swift
struct WattlySegment<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, label: String)]
    var fontSize: CGFloat = 12.5
    var pillVPadding: CGFloat = 7
    /// 비활성 상태: 보이되 조작·포커스·VoiceOver 액션이 모두 막힌다. `WattlyChip`/`WattlyToggle`과
    /// 같은 모양이라, 상위 토글에 딸린 컨트롤을 숨기는 대신 딤 처리하는 앱 전반의 패턴을 따른다.
    /// 새 프로퍼티는 `pillVPadding` 뒤에 있어야 한다 — 기존 호출부가 쓰는 멤버와이즈 이니셜라이저의
    /// 인자 순서가 그 앞에서 고정되어 있다.
    var isEnabled: Bool = true
    var disabledReason: String? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.tokens) private var t
    @FocusState private var focusedValue: T?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { option in
                pill(option.value, option.label)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(t.segTrack))
        // 트랙까지 함께 흐려져야 "지금은 못 만진다"가 한 덩어리로 읽힌다.
        // 0.5는 `WattlyToggle`의 비활성 불투명도와 같은 값.
        .opacity(isEnabled ? 1 : 0.5)
    }

    private func pill(_ value: T, _ label: String) -> some View {
        let active = selection == value
        return Text(LocalizedStringKey(label))
            .font(WattlyFont.at(fontSize, weight: .semibold))
            .foregroundStyle(active ? t.text : scheme.segInactiveText)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .allowsTightening(true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 2)
            .padding(.vertical, pillVPadding)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(active ? scheme.segActiveBg : .clear)
                    .shadow(color: active ? scheme.segActiveShadow : .clear, radius: 1, x: 0, y: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                guard isEnabled else { return }
                selection = value
                focusedValue = nil
            }
            .focusable(isEnabled)
            .focused($focusedValue, equals: value)
            .onKeyPress(.space) { guard isEnabled else { return .ignored }; selection = value; return .handled }
            .onKeyPress(.return) { guard isEnabled else { return .ignored }; selection = value; return .handled }
            .wattlyFocusRing(focusedValue == value, cornerRadius: 6)
            .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint(isEnabled ? "" : (disabledReason ?? "사용할 수 없습니다"))
    }
}
```

- [ ] **Step 3: 빌드하고 전체 스위트를 돌린다**

```bash
xcodebuild test -scheme Wattly -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`, 테스트 개수는 Step 1과 동일. 컴파일 에러가 하나라도 나면 새 프로퍼티를 `pillVPadding` 앞에 넣은 것이니 순서를 고친다.

- [ ] **Step 4: 다른 호출부가 손대지 않은 채 그대로인지 확인한다**

```bash
git diff --stat
```

Expected: `Wattly/Views/SettingsComponents.swift` 한 파일만 변경. 다른 설정 섹션 파일이 목록에 있으면 잘못된 것이다.

- [ ] **Step 5: 커밋한다**

```bash
git add Wattly/Views/SettingsComponents.swift && git commit -m "feat(settings): let WattlySegment render a disabled state"
```

---

## Task 3: 배터리 섹션을 재배선한다

**Files:**
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift`

**Interfaces:**
- Consumes: Task 1의 `BatterySectionPresentation` 전부, Task 2의 `WattlySegment(... isEnabled:disabledReason:)`
- Produces: 없음 (최종 소비자)

**바뀌는 동작 요약:**

| | 이전 | 이후 |
| --- | --- | --- |
| 토글 OFF (지원 Mac) | 하위 항목 전부 숨김 | 전부 보임. 한도 선택기와 그 헤더만 딤 + 비활성 |
| 토글 OFF 상태 줄 | (없음) | 회색 점 + "충전 제한 비활성화됨" |
| 토글 OFF 설치 버튼 | (없음) | 계속 없음 (관리자 암호 프롬프트 방지) |
| 토글 OFF 폴링 | 안 함 | 안 함 (변경 없음) |
| 하드웨어 미지원 | 하위 항목 숨김 | 숨김 (변경 없음) |
| 토글 ON | 전부 보임 | 전부 보임 (변경 없음) |

- [ ] **Step 1: 표시 게이트와 구분선을 바꾼다**

`SettingsBatterySection.swift`의 26–41행 부근에서 `divider:` 인자와 하위 항목 `if` 조건을 바꾼다.

바꾸기 전:
```swift
                SettingsToggleRow(isOn: $batteryLimitEnabled,
                                  divider: batteryLimitEnabled && !isHardwareUnsupported,
```
바꾼 뒤:
```swift
                SettingsToggleRow(isOn: $batteryLimitEnabled,
                                  divider: areDetailsVisible,
```

바꾸기 전:
```swift
                if batteryLimitEnabled && !isHardwareUnsupported {
```
바꾼 뒤:
```swift
                if areDetailsVisible {
```

그리고 파일 아래쪽 `isHardwareUnsupported` 계산 프로퍼티(현재 172–176행) 바로 뒤에 다음을 추가한다.

```swift
    /// 하위 항목(한도 선택기 · 상태 줄 · 안내 배너)을 그릴지. 토글의 ON/OFF와는 무관하다 —
    /// 꺼져 있어도 이 기능이 무엇을 하는지는 보여야 한다. 숨기는 경우는 이 Mac에 충전 제어
    /// 레지스터가 아예 없다고 도우미가 명시적으로 답했을 때뿐이다.
    private var areDetailsVisible: Bool {
        BatterySectionPresentation.areDetailsVisible(
            isHardwareSupported: batteryControl.status.isHardwareSupported)
    }
```

- [ ] **Step 2: 한도 선택기 블록을 딤 가능하게 바꾼다**

41–65행의 하위 항목 `VStack` 안에서, 헤더 `HStack`과 `WattlySegment`를 아래로 교체한다.

바꾸기 전:
```swift
                        HStack {
                            Text("최대 충전 한도")
                                .font(WattlyFont.at(12, weight: .medium))
                                .foregroundStyle(t.text)
                            Spacer()
                            Text("\(batteryLimitPercentage)%")
                                .font(WattlyFont.at(12, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(t.text)
                        }

                        WattlySegment(
                            selection: $batteryLimitPercentage,
                            options: presetLimits.map { ($0, "\($0)%") },
                            pillVPadding: 6
                        )
```
바꾼 뒤:
```swift
                        HStack {
                            Text("최대 충전 한도")
                                .font(WattlyFont.at(12, weight: .medium))
                                .foregroundStyle(t.text)
                            Spacer()
                            Text("\(batteryLimitPercentage)%")
                                .font(WattlyFont.at(12, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(t.text)
                        }
                        // 헤더와 세그먼트는 같은 컨트롤로 읽히므로 같은 값(0.5)으로 함께 흐려진다.
                        // 세그먼트 자신의 불투명도는 `isEnabled`가 처리하므로 여기서 또 곱하면
                        // 0.25가 되어 너무 어두워진다 — 그래서 딤은 헤더에만 건다.
                        .opacity(isLimitPickerEnabled ? 1 : 0.5)

                        WattlySegment(
                            selection: $batteryLimitPercentage,
                            options: presetLimits.map { ($0, "\($0)%") },
                            pillVPadding: 6,
                            isEnabled: isLimitPickerEnabled,
                            disabledReason: BatterySectionPresentation
                                .limitPickerDisabledReason(isLimitOn: batteryLimitEnabled)
                        )
```

그리고 `areDetailsVisible` 바로 뒤에 추가한다.

```swift
    private var isLimitPickerEnabled: Bool {
        BatterySectionPresentation.isLimitPickerEnabled(isLimitOn: batteryLimitEnabled)
    }
```

- [ ] **Step 3: 상태 폴링 조건을 순수 함수로 옮긴다**

67–77행의 `.task(id:)` 안에서 `guard batteryLimitEnabled else { return }`를 바꾼다.

바꾸기 전:
```swift
                guard batteryLimitEnabled else { return }
```
바꾼 뒤:
```swift
                guard BatterySectionPresentation.shouldPollStatus(isLimitOn: batteryLimitEnabled) else { return }
```

(동작은 동일하다. 조건을 테스트가 있는 한곳으로 모으는 것이 목적이다. 위쪽의 `await batteryControl.refreshStatus()` 한 번은 그대로 둔다 — 하드웨어 지원 여부를 알아내는 유일한 읽기이고, 이제 그 답이 하위 항목 노출까지 결정한다.)

- [ ] **Step 4: 상태 줄과 설치 버튼을 재배선한다**

116–158행의 `batteryStatusIndicator`와 178–199행의 `statusDotColor` / `statusText`를 아래로 교체한다. `statusDotColor`와 `statusText` 두 프로퍼티는 **삭제**되고 `resolvedStatus` + `dotColor(for:)`가 대신 들어간다.

바꾼 뒤 (`batteryStatusIndicator`):
```swift
    private var batteryStatusIndicator: some View {
        let resolved = resolvedStatus
        return HStack(spacing: 8) {
            Circle()
                .fill(dotColor(for: resolved.dot))
                .frame(width: 7, height: 7)
            Text(resolved.text)
                .font(WattlyFont.at(11, weight: .regular))
                .foregroundStyle(t.sub)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if BatterySectionPresentation.isInstallButtonVisible(isLimitOn: batteryLimitEnabled,
                                                                 mode: batteryControl.status.mode) {
                Button {
                    let window = NSApp.keyWindow
                    let limit = batteryLimitPercentage
                    Task {
                        if let failure = await batteryControl.installAndApply(enabled: batteryLimitEnabled, limitPercentage: limit, window: window) {
                            installErrorMessage = failure.localizedDescription
                            isInstallFailedAlertPresented = true
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if batteryControl.isInstallingHelper {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 10, height: 10)
                        }
                        Text("도우미 설치")
                            .font(WattlyFont.at(11.5, weight: .medium))
                            .foregroundStyle(t.text)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.segTrack))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.rowBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(batteryControl.isInstallingHelper)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
```

바꾼 뒤 (`statusDotColor` / `statusText`를 대체):
```swift
    private var resolvedStatus: BatterySectionPresentation.Status {
        BatterySectionPresentation.status(isLimitOn: batteryLimitEnabled,
                                          isInstalling: batteryControl.isInstallingHelper,
                                          mode: batteryControl.status.mode,
                                          detail: batteryControl.status.detail)
    }

    /// 의미 → 색. 색을 순수 타입에 넣지 않는 이유는 `t.faint`가 테마 토큰이라
    /// `@Environment`에서만 읽히기 때문이다.
    private func dotColor(for dot: BatterySectionPresentation.Dot) -> Color {
        switch dot {
        case .green: return Tokens.statusGreen
        case .orange: return Tokens.statusOrange
        case .red: return Tokens.statusRed
        case .faint: return t.faint
        }
    }
```

- [ ] **Step 5: 빌드하고 전체 스위트를 돌린다**

```bash
xcodebuild test -scheme Wattly -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`. 남아 있는 참조가 있으면 여기서 걸린다:

```bash
grep -n "statusDotColor\|statusText" Wattly/Views/Settings/SettingsBatterySection.swift
```

Expected: 출력 없음 (두 프로퍼티는 삭제되었다)

- [ ] **Step 6: 커밋한다**

```bash
git add Wattly/Views/Settings/SettingsBatterySection.swift && git commit -m "feat(battery): keep the limit details visible while the toggle is off"
```

- [ ] **Step 7: 앱을 띄워 눈으로 확인한다**

```bash
xcodebuild -scheme Wattly -configuration Debug -destination 'platform=macOS,arch=arm64' -quiet build 2>&1 | tail -5 && open "$(xcodebuild -scheme Wattly -configuration Debug -destination 'platform=macOS,arch=arm64' -showBuildSettings 2>/dev/null | awk -F'= ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')/Wattly.app"
```

메뉴바 아이콘 → 설정 → 배터리 충전 제어에서 확인할 항목:

1. 토글 **OFF** 상태에서 "최대 충전 한도", 80/85/90/95 세그먼트, 상태 줄, 안내 배너가 **모두 보인다**.
2. OFF 상태에서 세그먼트가 흐리고, 눌러도 선택이 바뀌지 않는다. 헤더("최대 충전 한도 / 80%")도 같은 정도로 흐리다.
3. OFF 상태의 상태 줄이 **회색 점 + "충전 제한 비활성화됨"** 이다 (초록/빨강 점이 아니다).
4. OFF 상태에서 "도우미 설치" 버튼이 보이지 않는다.
5. 토글을 **ON** 으로 바꾸면 세그먼트가 또렷해지고 눌러서 85%/90% 선택이 된다.
6. ON 상태의 상태 줄이 데몬 문구("목표치(80%)까지 충전 중" / "배터리 전원으로 구동 중" 등)로 바뀐다.
7. 토글 위/아래의 구분선이 OFF 상태에서도 그려진다(하위 항목이 붙어 있으므로).
8. 다른 설정 섹션(테마, 레이아웃, 갱신 주기, 팬 커브 프리셋, 메뉴바)의 세그먼트가 전부 예전처럼 조작된다 — Task 2가 공유 컴포넌트를 건드렸으므로 반드시 확인한다.

**이 Mac에서 확인할 수 없는 것:** 하드웨어 미지원 경로(항목 없이 토글만 비활성). 이 Mac은 `CHTE`를 갖고 있어 항상 지원으로 판정된다. PR에 그대로 적을 것.

- [ ] **Step 8: 확인 결과를 반영한다**

눈으로 본 결과가 위와 다르면 해당 스텝으로 돌아가 고치고 다시 커밋한다. 전부 맞으면 이 태스크는 끝이다.

---

## 참고: 이 계획이 건드리지 않는 것

- `BatteryControlBridge`, `BatteryControlClient`, `BatteryControlPolicy`, 데몬, SMC 레지스터 로직 — 한 줄도 바뀌지 않는다. 꺼짐 상태에서 한도 값을 바꿔도 브리지가 `apply(enabled: false, limitPercentage:)`를 밀어 넣어 무해하지만, 이번 변경에서는 세그먼트가 비활성이라 그 경로 자체가 발생하지 않는다.
- `WattlyChip`, `WattlyToggle`, `SettingsToggleRow` — 이미 같은 파라미터를 갖고 있고 그대로 둔다.
- 현재 브랜치의 미완료 항목(설치된 도우미 강제 교체, 재부팅 지속성 확인)은 이 계획의 범위 밖이며 별개로 남아 있다.
