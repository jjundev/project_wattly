# 19 — 팝오버 레이아웃 선택 + 모드 B (카드 그리드)

> 막힘: 02,03,11,13 · 커버: 프로토타입 모드 B + 레이아웃 선택 인프라 · 결정표 매핑: **#23 정정 → #29**
> 프로토타입 근거: 모드 B 그리드 line 176–203 · 모드 데이터 line 683–692 · 데모 컨트롤(레이아웃) line 377–383
> 짝 plan: 모드 C는 → [20](20-popover-mode-c-hero.md) (이 plan의 인프라 위에 추가)

## 목표

팝오버 레이아웃을 **사용자 선택(현재 A 고정 → A·B·C)** 으로 바꾸는 **공유 인프라**를 깔고, 그 위에 **모드 B(카드 그리드)** 를 구현한다. 모드 C는 같은 인프라를 쓰는 별도 plan([20](20-popover-mode-c-hero.md)). 출시 **기본값은 A 유지**(기존 사용자 무변화).

이 plan은 **결정 #23("모드 A만 출시")을 정정**한다 — 사용자 지시로 레이아웃 모드를 정식 기능화. README/02/12의 "B/C 미구현" 서술을 동기화한다(§문서 동기화).

## 배경

`PopoverContentView`는 현재 **모드 A만** 렌더한다([PopoverContentView.swift:9](../Wattly/Views/PopoverContentView.swift) 주석 `mode A`). 프로토타입은 `panelMode` 상태로 A/B/C를 `sc-if` 분기. 모드 B는 기존 7개 카드의 **순수 재배치**다 — 신규 데이터·상태·인터랙션 없음.

| 모드 | 레이아웃 | 본 plan |
|---|---|---|
| A · 스택 행 | 전체 폭 카드 세로 스택(펼침·드래그) | 기존([02](02-popover-mode-a-cards.md)/[12](12-card-reorder-edit-mode.md)) |
| **B · 카드 그리드** | 2열 컴팩트 타일. 10.5px 라벨 + 24px값 + 미니 스파크(h22) | **이 plan** |
| C · 히어로+리스트 | 다크 히어로 + 리스트(탭 승격) | [20](20-popover-mode-c-hero.md) |

## 그릴 결정 (예비 — 빌드 전 grill-yourself/review 권장)

순 신규는 **모델 1종 + 설정 1섹션 + 분기 1곳 + 그리드 뷰 1종**. 표현 계층([CardPresentation.swift](../Wattly/Core/CardPresentation.swift))·세그먼트([SettingsComponents.swift](../Wattly/Views/SettingsComponents.swift) `WattlySegment`)·스파크([SparklineView](../Wattly/Views/SparklineView.swift))·토큰([Tokens.swift](../Wattly/DesignSystem/Tokens.swift) `gridBorder`)·가시성/게이팅은 모두 이미 존재.

**Confident**
1. **`PanelMode` 모델은 처음부터 a/b/c 전체를 정의**(저장 스키마 안정 — 20에서 모델 변경 없음). 단 이 plan의 **설정 세그먼트는 A·B만 노출**, 분기는 `.c`를 **방어적으로 `.a`로 폴백**(20이 `.c` 가지·픽커를 점등). `ThemeMode`/`PollInterval`과 동일 패턴(`@AppStorage`가 String-raw `RawRepresentable` 지원).
2. **`gridBorder` 토큰 배선 첫 소비처가 이 plan.** plan 11이 *"forward-declared, plan 10/13에서 배선"* 으로 남긴 토큰의 실제 용도는 **모드 B 타일 보더**였다 → plan 11 주석 정정.
3. **편집(드래그 재정렬)은 모드 A 전용.** 비-A에서 **연필 버튼을 숨긴다**(무의미 토글 방지). `cardOrder`는 모드 공유(B 타일도 같은 순서로 나열).
4. **공통 셸 유지** — 헤더(번개+Wattly+상태점, ⚙︎, ⏻)와 화면-높이 캡 스크롤([PopoverContentView.swift:187](../Wattly/Views/PopoverContentView.swift) `cardsRegion`, issue 17 후속)을 **본문 분기 바깥**으로 일반화해 세 모드가 공유. 모드 본문만 `switch`.
5. **가시성·데스크톱 규칙 동일** — `visibleCards = cardOrder ∩ isPresent ∩ isShown`(배터리/배터리온도 데스크톱 숨김). B도 같은 가시 집합.
6. **per-process 열거 게이팅**(`.task(id: memExpanded)`/`powerExpanded`)을 `panelMode == .a && expanded`로 조건화 — B엔 펼침이 없으니 모드 전환 시 누수 방지.
7. **모드 B 값은 기존 `CardPresentation.display(_:_:)` 재사용** — 신규 순수 헬퍼 없음(B는 픽셀 일치가 전부, 표기는 모드 A와 자동 일치).

## 범위 (In)

### 1. 모델 — `Wattly/Settings/Settings.swift`
- `enum PanelMode: String, CaseIterable, Identifiable, Sendable { case a="A", b="B", c="C" }` + `var label`("스택 행"/"카드 그리드"/"히어로+리스트").
- `StorageKey.panelMode = "panelMode"`, `Defaults.panelMode = .a`.

### 2. 설정 — `Wattly/Views/SettingsView.swift`
- **신규 "레이아웃" 섹션**(테마와 표시 지표 사이): `WattlySegment(selection: $panelMode, options: [(.a,"스택 행"),(.b,"카드 그리드")])` — **A·B만**(C는 20). 기존 컴포넌트라 a11y·포커스 링·테마 자동.

### 3. 모드 분기 — `PopoverContentView.swift`
- `@AppStorage(StorageKey.panelMode) var panelMode = Defaults.panelMode` 추가.
- 본문을 `switch panelMode { case .a: 기존 cardsRegion; case .b: PopoverGridView; case .c: 기존 cardsRegion(폴백) }`.
- 공통 셸(헤더 + 높이캡 래퍼)을 분기 바깥으로. 연필 버튼은 `panelMode == .a`에서만 렌더.
- 열거 `.task`를 `.a && expanded`로 게이팅.

### 4. 모드 B 뷰 — 신규 `Wattly/Views/PopoverGridView.swift`
- `LazyVGrid` 2열, gap 8. 타일: padding 12, radius 12, **border 1px `t.gridBorder`**.
- 타일 내용(프로토타입 179–201): 라벨 10.5px/600 `t.sub` → 값 24px/700 tnum(전력=accent, 그 외 `t.text`) + 단위 12px/600 `t.sub` → `SparklineView`(height 22, area 없음 — 폴리라인만). 라벨/값/단위는 `CardPresentation.display` 재사용.
- **unavailable 타일**(프로토타입 182–183): dashed border `t.panelBorder` + 라벨 + 단축 사유. 펼침·드래그 없음.
- 접근성: 타일당 단일 VO 요소 `Accessibility.cardLabel` + `stateWord`(모드 A 카드와 동일 규약, issue 15 §2).

### 5. 되돌리기 — `Wattly/Core/SettingsReset.swift`
- `applyDefaults`에 `panelMode`를 `Defaults.panelMode`로 재기록 추가. `SettingsResetTests`에 단언 추가.

### 6. 문서 동기화
- `plan/README.md`: §진실의소스 13행 + §"PRD 추가/변경" 표 마지막 행 + §보류결정 **#23 → #29**("레이아웃 모드 정식 구현, 19=선택+B / 20=C") + 이슈 인덱스 **19행** + 빌드 순서.
- `plan/02`·`plan/12` §범위(Out) "모드 B/C 미구현" → "→ [19](19-popover-layout-select-mode-b.md)/[20](20-popover-mode-c-hero.md)".
- `plan/11` §3 `gridBorder` 주석 → "plan 19에서 배선"(미사용 → 사용).

## 범위 (Out)
- **모드 C 전부** → [20](20-popover-mode-c-hero.md)(히어로/리스트/heroMetric/승격/폴백/히어로 픽커). 이 plan의 세그먼트는 A·B만.
- 모드별 카드 순서 분리(세 모드가 `cardOrder` 하나 공유). 모드 B의 펼침·드래그. 단위(°C/°F). 전환 애니메이션.

## 수용 기준
- 설정 "레이아웃" 세그먼트로 A↔B 전환이 **팝오버에 즉시 반영**되고 재시작 후 유지. 기본값 A.
- **모드 B**: 라이트/다크에서 2열 그리드가 프로토타입과 픽셀 일치(보더·여백·24px값·미니 스파크). 데스크톱 시 배터리/배터리온도 타일 제외. 전력 실패 시 dashed unavailable 타일.
- 비-A에서 연필 비표시, 드래그/펼침 비활성, per-process 열거 미폴링.
- VoiceOver가 B 타일을 카드당 단일 요소로 읽음(모드 A와 동일).
- "되돌리기"가 `panelMode`를 A로 복원. (heroMetric 복원은 20.)

## 열린 결정 (사용자 확인 필요)
| # | 질문 | 추천 |
|---:|---|---|
| A | 출시 **기본 모드** = A 유지? | **예**(기존 사용자 무변화) |
| C(B관련) | 모드 B 타일도 탭 시 펼침을 줄까? | 아니오(프로토타입 충실, 펼침 전무) |

## 메모
- 모드 B는 **신규 데이터 없음** — `monitor.cardState`/`historyValues`/`isPresent`/`thresholds` 그대로 소비. 위험은 픽셀 일치에 한정.
- `MetricCardView`(모드 A)는 건드리지 않는다 — B는 별도 경량 뷰. 표기는 `CardPresentation`/`SparklineView` 공유라 모드 간 자동 일치.
- 데모 컨트롤 스트립(line 377–383 "팝오버 모드")은 하니스 — 실제 앱은 설정 창으로 옮긴다.
