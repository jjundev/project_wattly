# 20 — 팝오버 모드 C (히어로 + 리스트)

> 막힘: **19**,02,03,10,11,13 · 커버: 프로토타입 모드 C · 결정표 매핑: #29
> 프로토타입 근거: 모드 C 히어로+리스트 line 205–222 · 히어로/리스트 데이터 line 693–725 · 데모 컨트롤(히어로) line 384–391
> 짝 plan: 레이아웃 선택 인프라 + 모드 B는 → [19](19-popover-layout-select-mode-b.md)

## 목표

[19](19-popover-layout-select-mode-b.md)가 깐 레이아웃 선택 인프라 위에 **모드 C(히어로 + 리스트)** 를 **순수 추가**한다. 상단 다크 **히어로 카드**(강조 지표 1종, 40px) + 나머지는 **라벨/값 리스트**, **리스트 행 탭 → 히어로 승격**. 설정 세그먼트에 **C 옵션**과 **히어로 지표 픽커**를 추가한다.

## 배경

모드 C만이 가진 net-new는 **히어로 선택 상태**다. 프로토타입(line 693–725): `heroMetric` 한 지표를 히어로로 띄우고, 나머지 가시 지표는 리스트로. 영속 히어로가 숨김/부재면 **첫 가시 카드로 폴백**(line 694). 리스트 행을 누르면 그 지표가 히어로가 된다(`promote`, line 720). 데모는 별도 "히어로 강조" 컨트롤(line 384–391)도 두지만, 실제 앱의 1차 경로는 **팝오버 행 탭**이다.

19의 모드 A/B 분리(02 레이아웃 / 12 인터랙션)와 같은 결로, C의 **레이아웃 + 히어로 인터랙션·상태**를 한 plan으로 묶는다.

## 그릴 결정 (예비 — 빌드 전 grill-yourself/review 권장)

순 신규는 **히어로 상태 1종 + 순수 헬퍼 2종 + 히어로 뷰 1종 + 설정 픽커 1개 + 세그먼트 C 가지 점등**.

**Confident**
1. **히어로 지표는 `CardKind`를 `@AppStorage`로 저장**(`heroMetric`, 기본 `.power`). `CardKind`도 String-raw enum이라 그대로 저장(테마/폴링 패턴).
2. **표현 로직은 순수 헬퍼로 추출**(테스트가 SwiftUI 대신 건너는 seam — 코드베이스 규약). `CardPresentation`에:
   - `resolveHero(persisted:visible:) -> CardKind?` — 영속 히어로가 `visible`에 없으면 **첫 가시 카드**, 빈 가시면 `nil`(프로토타입 line 693–695). → `HeroSelectionTests`.
   - `compactRowText(_:_:) -> String` — 리스트 행 텍스트(프로토타입 `rowOf` line 678–682: CPU `%`/온도 `°C`는 값+단위, mem `/ N GB`, 그 외 `W`; loading/unavailable은 단축). → `PanelPresentationTests`.
3. **`cText` 토큰 배선 첫 소비처가 이 plan.** plan 11이 forward-declared로 남긴 토큰의 실제 용도는 **모드 C 리스트 라벨**이었다 → plan 11 주석 정정.
4. **히어로 카드는 양 테마 모두 다크(#171719) 고정**(프로토타입 line 208이 두 테마 동일) — §열린 결정 E로 표시(라이트에서 재검토).
5. **히어로 색**은 임곗값 색 맵(프로토타입 705–712)을 따른다 — 카드의 `thresholdLevel`을 재사용해 스파크 stroke/fill 결정(전력=accent 계열, 그 외 상태색/중립).
6. **리스트 행은 값만(스파크 없음)** — 프로토타입 충실(§열린 결정 D).

## 범위 (In)

### 1. 모델 — `Wattly/Settings/Settings.swift`
- `StorageKey.heroMetric = "heroMetric"`, `Defaults.heroMetric = CardKind.power`. (`PanelMode` 자체는 19에서 이미 a/b/c 전체 정의됨.)

### 2. 순수 헬퍼 — `Wattly/Core/CardPresentation.swift`
- `resolveHero(persisted:visible:)` + `compactRowText(_:_:)`(위 그릴 2). Korean copy는 기존 관례대로 이 모듈에.

### 3. 설정 — `Wattly/Views/SettingsView.swift`
- "레이아웃" 세그먼트 옵션에 **`(.c, "히어로+리스트")`** 추가(19의 A·B → A·B·C).
- **모드 C 선택 시에만** "히어로 지표" 하위 픽커: `WattlyChip` **단일선택** 그리드(가시 카드 중 1종, `menuChipGrid` 패턴 재사용). 팝오버 행-탭 승격과 **동일 `heroMetric` 키**.

### 4. 모드 분기 — `PopoverContentView.swift`
- 19의 `switch`에서 `.c` 폴백을 **`PopoverHeroView`로 교체**.

### 5. 모드 C 뷰 — 신규 `Wattly/Views/PopoverHeroView.swift`
- **히어로 카드**(프로토타입 208): bg `#171719` 고정, radius 14, padding 16. 라벨 11.5px/600(흰 0.6) → 값 40px/700 흰색 + 단위 16px/600(흰 0.6) → 스파크(height 32, area+line, 색=히어로 임곗값 맵) → 서브 11px(흰 0.55).
- **히어로 unavailable**(프로토타입 211): 다크 카드 + 사유.
- **리스트**(프로토타입 213–220): `visible − hero`를 `cardOrder` 순서로. 각 행: 라벨 13px/600 **`t.cText`** ↔ 값 14px/600(`compactRowText`), 하단 `t.line` 구분선. **행 탭 → `heroMetric` = 그 카드**. unavailable 행은 단축 사유 + `t.faint`.
- 접근성: 히어로 + 각 행 단일 VO 요소(`Accessibility.cardLabel`/`stateWord`). 리스트 행은 `.isButton` + 동작 라벨("히어로로 강조").

### 6. 되돌리기 — `Wattly/Core/SettingsReset.swift`
- `applyDefaults`에 `heroMetric`를 `Defaults.heroMetric`로 재기록 추가. `SettingsResetTests`에 단언 추가.

### 7. 테스트 — `WattlyTests/`(plan 18 패턴, 순수 seam)
- `HeroSelectionTests` — `resolveHero` 폴백(영속 히어로 숨김 → 첫 가시), 빈 가시 → nil.
- `PanelPresentationTests` — `compactRowText`가 카드×상태(전력 W·CPU %·온도 °C·메모리 `/N GB`·loading "—")별 정확.
- `SettingsResetTests` — `heroMetric` 포함.

### 8. 문서 동기화
- `plan/README.md` 이슈 인덱스 **20행** 추가 + 빌드 순서(19 뒤).
- `plan/11` §3 `cText` 주석 → "plan 20에서 배선".

## 범위 (Out)
- 레이아웃 선택 인프라·모드 B → [19](19-popover-layout-select-mode-b.md).
- 히어로 카드의 펼침(코어/Top-3). 모드별 카드 순서 분리. 전환 애니메이션.

## 수용 기준
- 설정 세그먼트에 C가 보이고, 선택 시 **히어로 지표 픽커**가 나타남. C 전환이 팝오버에 즉시 반영, 재시작 후 유지.
- **모드 C**: 라이트/다크에서 히어로(40px)+리스트가 프로토타입과 픽셀 일치.
- **리스트 행 탭 → 히어로 승격**이 동작하고 선택이 영속(설정 픽커와 양방향 동기).
- 영속 히어로가 숨김이면 **첫 가시 카드로 폴백**(빈 히어로·크래시 없음). 데스크톱 시 배터리/배터리온도 제외 반영.
- VoiceOver가 히어로·각 행을 카드당 단일 요소로 읽고, 리스트 행은 승격 동작 노출.
- "되돌리기"가 `heroMetric`를 `.power`로 복원.

## 열린 결정 (사용자 확인 필요)
| # | 질문 | 추천 |
|---:|---|---|
| B | 히어로 선택을 **설정 칩 + 팝오버 탭** 둘 다? vs **팝오버 탭만**(설정 픽커 생략)? | 둘 다(발견성) |
| D | 리스트 행은 **값만**(스파크 없음) 유지? | 예(충실) |
| E | 히어로 카드 라이트 테마에서도 **다크 고정**? vs 라이트엔 밝은 카드? | 고정(충실) — 라이트 재검토 |

## 메모
- 모드 C도 **신규 데이터 없음** — 기존 monitor surface 그대로. net-new는 **히어로 선택 상태 + 두 순수 헬퍼 + 한 뷰**.
- 히어로 선택의 진실의 소스는 `@AppStorage(heroMetric)` 하나 — 팝오버 탭과 설정 픽커가 같은 키를 쓰므로 양방향 동기가 공짜.
- 표기(라벨/값/단위/서브/스파크 색)는 `CardPresentation`/`SparklineView` 공유라 A/B/C가 자동 일치.
