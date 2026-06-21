# 13 — 설정 창 + 로그인 항목

> 막힘: 01,09,10,11,14 · 커버: 스토리 10,12,13,14 · 결정표 매핑: #16, #11
> 프로토타입 근거: 설정 창 line 228–336

## 목표

표시 지표·테마·임곗값·메뉴바·폴링·로그인 항목을 한 창에서 설정한다. SwiftUI `Settings` scene + `@AppStorage`.

## 범위 (In)

1. **창 셸** — SwiftUI `Settings` scene. 폭 `440px`(`max-width: calc(100% - 32px)`). 신호등 타이틀바(40px, ●red(닫기 가능)·●yellow·●green, "Wattly 설정" 13px/600). bg `c.settingsBg`, titlebar `c.titlebar`. 본문 세로 스크롤(padding 18, gap 18).
2. **섹션 (프로토타입 순서)**
   - **일반** — "로그인 시 자동 실행" 토글 → `SMAppService.mainApp` (`@AppStorage` 미러). 검증: SDK `SMAppService` `API_AVAILABLE(macos(13.0))`.
   - **테마** — 세그먼트 라이트/다크/시스템 설정([11](11-theme-light-dark-system.md)).
   - **표시 지표** — 토글 7행: 프로세서 전력(IOReport)·배터리·CPU 사용률·메모리·CPU 온도(·최고값)·GPU 온도(·최고값)·배터리 온도. 두 온도 모두 OFF면 온도 provider 미폴링([09](09-adaptive-polling.md)).
   - **전력 표시** — "전력 평활(EMA)" 토글 + 부제 "값을 부드럽게 평균내 표시(실제 지속 소모에 맞게). 측정 정확도는 그대로". `@AppStorage(StorageKey.powerSmoothed)` (기본 ON, 이미 존재). **프로세서 전력 + 배터리 카드 둘 다** 적용. **백엔드는 이미 구현됨**([06](06-power-ioreport-soc.md) 평활 layer): `Core/PowerSmoothing.swift`(연속시간 EMA τ=4s, `emaStep` 스칼라 공유), `SystemMonitor.powerCardState`/`batteryCardState`/`*HistoryValues(smoothed:)`. 이 plan에서 남은 일은 **Toggle 바인딩 한 줄 + 행 UI**뿐 — 끄면 두 카드가 raw 1초 순간값으로 표시. (선택) τ 프리셋(3/4/5초) 세그먼트는 차후.
   - **그래프 임곗값** — CPU(%)·메모리(%)·온도·CPU·GPU(°C) warn/crit 슬라이더([10](10-thresholds-color-coding.md)).
   - **메뉴바** — "텍스트 표시" 토글 + 부제 "아이콘 옆에 선택한 지표를 함께 표시" + "표시할 지표(복수 선택)" 칩([14](14-menubar-text-metrics.md)).
   - **업데이트 주기** — 세그먼트 자동/1초/2초/5초 + 힌트([09](09-adaptive-polling.md)).
   - **기본값으로 되돌리기** — 모든 토글·임곗값·메뉴바·주기·로그인·카드순서 리셋(프로토타입 `resetDefaults`).
   - **푸터** — "Wattly 1.0 · 자체 소비 **X.XX W**"([16](16-self-power-guard.md)) + "Created by jjundev".
3. **컴포넌트 스펙** — 토글 38×22/radius 11/knob 18(on=accent, left 2↔18). 세그먼트 track `c.segTrack`, 활성 bg(dark `#3a3b3e`/light `#fff`)+라이트 그림자. 행 border `c.rowBorder`, bg `c.rowBg`, 구분선 `c.line`.
4. **영속** — 모든 항목 `@AppStorage`. 변경은 팝오버에 즉시 반영.

## 범위 (Out)

- 레이아웃 모드 토글(모드 A 고정 — 결정 #23). 단위(°C/°F) 선택.

## 수용 기준

- 7개 섹션이 프로토타입과 픽셀 일치(라이트/다크).
- "전력 평활(EMA)" 토글이 프로세서 전력 카드의 헤드라인+스파크라인을 평활↔raw로 즉시 전환(`powerSmoothed`), 재시작 후 유지.
- 로그인 토글이 실제 `SMAppService` 등록/해제와 동기, 재부팅 후 자동 실행.
- 모든 설정이 팝오버에 즉시 반영되고 재시작 후 유지. "되돌리기"가 전부 기본값 복원.
- 푸터 자체 소비 W 가 라이브 갱신.
