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
   - **표시 지표** — 토글 7행: SoC 전력(IOReport)·배터리·CPU 사용률·메모리·CPU 온도(·최고값)·GPU 온도(·최고값)·배터리 온도. 두 온도 모두 OFF면 온도 provider 미폴링([09](09-adaptive-polling.md)).
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
- 로그인 토글이 실제 `SMAppService` 등록/해제와 동기, 재부팅 후 자동 실행.
- 모든 설정이 팝오버에 즉시 반영되고 재시작 후 유지. "되돌리기"가 전부 기본값 복원.
- 푸터 자체 소비 W 가 라이브 갱신.
