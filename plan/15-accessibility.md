# 15 — 접근성

> 막힘: 02,04 · 커버: 스토리 18 · 결정표 매핑: #13(상태), DS 접근성
> 프로토타입 근거: 전 카드 라벨/값/사유 구조 · DS 포커스 링 규칙([README](../interactive/project/_ds/wanted-design-system-019dded1-528c-7148-a04f-66cac240e314/README.md))
> grill 확정(2026-06-22): A=칩0개→무낭독 · B=단위 **기호 문자** · D/E=현재 유지 · 포커스 링 AC 하향(아래 수용 기준)

## 목표

VoiceOver 사용자가 메뉴바 라벨과 각 수치를 화면 낭독으로 들을 수 있다.

## 범위 (In)

1. **메뉴바** — 접근성 라벨(예 "Wattly, CPU 42%"). 텍스트 OFF여도 선택 지표를 낭독([14](14-menubar-text-metrics.md)의 `MenuBarText.assemble` 재사용). **선택 칩이 0개면 "Wattly"만 낭독**(결정 A).
2. **카드** — 각 카드에 이름·현재값·단위·(미가용 시)사유를 VoiceOver 라벨로. 예 "프로세서 전력, 8.4 W", "CPU 온도, 사용 불가, 검증된 온도 프로파일 없음". 단위는 **기호 문자**(결정 B): `%`·`W`·`°C`·`GB`.
3. **부분 실패/콜드** — `loading`은 "불러오는 중", `unavailable`은 사유 문구(retryable은 "재시도 중", terminal은 사유). private key/kern code 노출 금지([08](08-temperature-cpu-gpu-battery.md)) — a11y는 `reason.message`만 통과시키므로 SMC 키/kern 코드가 닿지 않는다.
4. **스파크라인** — `.accessibilityHidden`으로 장식 처리. 값은 카드 라벨이 이미 낭독하므로 별도 "추이" 요소는 두지 않는다(결정 E, 중복 낭독 방지).
5. **컨트롤** — 토글/세그먼트/칩에 역할·상태(켜짐/꺼짐, 현재 선택). 토글의 켜짐/꺼짐은 행(`SettingsToggleRow`, `.combine`) 레벨 `accessibilityValue`로 — `.isSelected` 트레잇만으로는 "선택됨"으로만 읽힘. DS **포커스 2px 링**(accent, 2px offset) 가시화.
6. **펼침** — CPU 코어·메모리 Top-3·온도 클러스터 행 라벨은 **현재 유지**(결정 D/E) — 이미 구현됨(`MetricCardView` `coreRow`/`processRow`/`tempGroupRow`).

## 범위 (Out)

- 음성 제어 커스텀 명령. 점자 디스플레이 전용 포맷.

## 수용 기준

- VoiceOver로 메뉴바→팝오버→각 카드→설정 컨트롤을 순회하며 값·상태를 모두 들을 수 있다.
- 미가용/콜드 상태가 사유와 함께 낭독된다.
- **macOS "키보드 탐색"(시스템 설정 › 키보드 › 키보드 탐색)이 켜진 상태에서** 모든 커스텀 컨트롤에 2px 포커스 링이 보인다. (VoiceOver 커서 도달성은 이 설정과 무관하게 항상 보장된다. macOS는 텍스트 외 컨트롤로의 Tab 포커스를 이 시스템 설정 뒤에 게이트하므로 "항상 보인다"는 원안 문구를 이렇게 하향한다.)

## 구현 메모

- **순수 모듈** `Core/Accessibility.swift`: `cardLabel(card,state)`(이름 + 기호 값 + subText 접기 — 전력 카드의 CPU/GPU/NPU 분해는 subText에만 존재하므로 접기 필수), `stateWord`(= `ThresholdLevel.stateWord`), `menuBarLabel`(= `MenuBarText.assemble` 재사용). 값·단위는 `CardPresentation`의 기호 출력을 재사용(결정 B). 테이블 테스트 `WattlyTests/AccessibilityTests.swift`.
- **카드 재배선**(`MetricCardView`): `headerRow`의 기존 `.accessibilityElement(children:.combine)`+`.accessibilityValue`(이전 issue 10 임시 배선)를 **제거** → 요약 컨테이너(헤더+스파크라인+subText)에 `.accessibilityElement(children:.ignore)`+합성 라벨/값. 펼침 가능 카드엔 `.accessibilityAddTraits(.isButton)`+`.accessibilityAction{onToggleExpand}` (VO가 펼침을 작동할 수 있게 — 시각 펼침은 `.onTapGesture`라 VO가 못 누름). `expandRegion`은 `.ignore` **밖** 형제로 두어 코어/프로세스/클러스터 행을 개별 탐색 유지. 미가용 카드 3종에도 `.ignore`+합성 라벨.
- **메뉴바**(`MenuBarLabel`): `textEnabled`와 무관하게 `MenuBarText.assemble` 결과로 `.accessibilityLabel` 구성. ⚠️ `MenuBarExtra`는 `NSStatusItem`(NSAccessibility)로 렌더되어 SwiftUI `.accessibilityLabel`이 VoiceOver에 안 잡힐 수 있음 → 온디바이스 검증, 안 잡히면 `NSStatusBarButton` AppKit 폴백.
- **컨트롤**(`SettingsComponents`): `WattlyToggle`/`WattlySegment`/`WattlyChip`에 `.focusable()`+`@FocusState` 2px 링(`wattlyFocusRing`)+`.onKeyPress(.space/.return)`. 토글 상태는 행 레벨로 이관. 헤더 상태 도트/편집 토글 라벨(`PopoverContentView`).

## 메모

- 접근성 라벨 문자열은 [14](14-menubar-text-metrics.md)의 조립 로직(`MenuBarText`)과 공유한다(테스트 대상).
