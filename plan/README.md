# Wattly — 프로토타입 기준 구현 계획 (`plan/`)

> 출처: **최종 인터랙티브 프로토타입** [`Wattly Interactive.dc.html`](../interactive/project/Wattly%20Interactive.dc.html) + `grill-yourself` 결정표
> 근거 문서: [PRD.md](../PRD.md) · 디자인 토큰 [colors_and_type.css](../interactive/project/_ds/wanted-design-system-019dded1-528c-7148-a04f-66cac240e314/colors_and_type.css)
> 관계: [`../issues/`](../issues/)는 **PRD 기반** 분해(참고용). 이 `plan/`은 **프로토타입 기반**이며 프로토타입이 더 넓다.

---

## 진실의 소스 규칙

프로토타입과 PRD가 충돌하면 **프로토타입이 UX·범위의 진실의 소스**다(사용자 지시: "이와 동일하게 구현"). **PRD는 네이티브 엔지니어링·무권한 데이터 소스·동시성 경계의 근거**다. HTML 프로토타입은 **시각·인터랙션 명세**일 뿐 그대로 포팅하지 않고, **네이티브 SwiftUI macOS 앱**으로 재현한다.

화면 하단 `CONTROL STRIP`(시나리오/배터리/테마/모드/히어로)과 바깥 페이지 헤더는 **데모 하니스**이지 앱 기능이 아니다. 단 **레이아웃 모드 A/B/C는 정식 기능**으로, 설정 창의 "레이아웃" 세그먼트로 선택한다(→ [19](19-popover-layout-select-mode-b.md)/[20](20-popover-mode-c-hero.md), 결정 [#29](#보류-결정-사용자-확인-필요)가 #23을 정정). 데모의 "팝오버 모드"·"히어로 강조" 컨트롤은 그 설정으로 이전된 것.

## 프로토타입이 PRD에 추가/변경한 것

| 항목 | PRD | 프로토타입 | 처리 |
|---|---|---|---|
| 배터리 온도 카드 | Out of scope | 있음 | **포함** (AppleSmartBattery, 저위험) → [08](08-temperature-cpu-gpu-battery.md) |
| 메모리 펼침 = 프로세스 Top | Out of scope | Chrome/Xcode/Figma | **포함(보류 #21)** → [05](05-memory-and-top-processes.md) |
| 그래프 임곗값 + 색상 코딩 | 없음 | warn/crit 슬라이더 | **포함** → [10](10-thresholds-color-coding.md) |
| 테마 라이트/다크/시스템 | 없음 | 있음 | **포함** → [11](11-theme-light-dark-system.md) |
| 카드 드래그 재정렬(편집모드) | 없음 | 있음 | **포함** → [12](12-card-reorder-edit-mode.md) |
| 메뉴바 텍스트에 온도 | "추가 안 함" | 온도 칩 있음 | **포함**(프로토타입 우선) → [14](14-menubar-text-metrics.md) |
| 팝오버 레이아웃 3종 | 1종 암시 | A/B/C | **A/B/C 정식 구현**(설정 선택) → [02](02-popover-mode-a-cards.md)/[19](19-popover-layout-select-mode-b.md)/[20](20-popover-mode-c-hero.md) |

---

## 이슈 인덱스

| # | 이슈 | 막힘(의존) | 커버 |
|---|---|---|---|
| 01 | [앱 스켈레톤 · 디자인 토큰 · 상태 모델](01-app-skeleton-tokens.md) | None | 기반(15,21,24), MetricSample/State seam |
| 02 | [팝오버 모드 A · 카드 · 헤더](02-popover-mode-a-cards.md) | 01 | 2,15,16,17 |
| 03 | [스파크라인 + 60초 추이](03-sparkline-history.md) | 01 | 9,19 |
| 04 | [CPU 척추(real) + 코어별](04-cpu-spine.md) | 01,02,03 | 1,6,7,15,24 |
| 05 | [메모리 + 프로세스 Top-3](05-memory-and-top-processes.md) | 01,02,03 | 8 |
| 06 | [전력 · IOReport(SoC)](06-power-ioreport-soc.md) | 01,02,03 | 3,5,16,23 |
| 07 | [전력 · 배터리(노트북)](07-power-battery.md) | 01,02,03 | 4,16 |
| 08 | [온도 · CPU/GPU/배터리](08-temperature-cpu-gpu-battery.md) | 01,02,03 | 25,26 |
| 09 | [적응형 폴링 + 저전력](09-adaptive-polling.md) | 01,03 | 11,19 |
| 10 | [그래프 임곗값 + 색상 코딩](10-thresholds-color-coding.md) | 02,03 | (프로토타입) |
| 11 | [테마 라이트/다크/시스템](11-theme-light-dark-system.md) | 01 | (프로토타입) |
| 12 | [카드 재정렬 + 편집모드](12-card-reorder-edit-mode.md) | 02 | (프로토타입) |
| 13 | [설정 창 + 로그인 항목](13-settings-window-login-item.md) | 01,09,10,11,14 | 10,12,13,14 |
| 14 | [메뉴바 텍스트(다중 지표)](14-menubar-text-metrics.md) | 01,04 | 10 |
| 15 | [접근성](15-accessibility.md) | 02,04 | 18 |
| 16 | [자체 전력 회귀 가드](16-self-power-guard.md) | 06 | 20 |
| 17 | [패키징 · 공증 · 배포](17-packaging-notarization.md) | 01–16 | 21,22 |
| 18 | [테스트 전략](18-testing.md) | 병렬 | 전 구간 |
| 19 | [팝오버 레이아웃 선택 + 모드 B](19-popover-layout-select-mode-b.md) | 02,03,11,13 | (프로토타입 모드 B) |
| 20 | [팝오버 모드 C · 히어로+리스트](20-popover-mode-c-hero.md) | 19,02,03,10,13 | (프로토타입 모드 C) |

**빌드 순서:** `01 → 02·03`(셸) → `04`(진짜 MVP) → `05·06·07·08·11·12` 병렬 → `09·10` → `14 → 13` → `15·16` → `17` → `19 → 20`. `18`은 전 구간 병렬.

---

## 결정 레지스터 (grill-yourself 요약)

전체 결정표는 이 대화의 grill-yourself 출력에 있다. 각 이슈는 `결정표 매핑`으로 해당 번호를 참조한다.

**Confident #1–20:** 1 진실의소스, 2 네이티브SwiftUI, 3 ~~모드A만~~→레이아웃A/B/C(#29 정정, [19](19-popover-layout-select-mode-b.md)/[20](20-popover-mode-c-hero.md)), 4 드래그재정렬, 5 테마3종, 6 임곗값+색상, 7 배터리온도, 8 메뉴바온도텍스트, 9 배터리부호W, 10 코어 perflevel, 11 자체소비푸터, 12 데이터소스맵, 13 상태모델, 14 스파크라인60s, 15 단일seam, 16 설정scene, 17 적응형주기, 18 패키징, 19 시각토큰, 20 메뉴바아이템.

### 보류 결정 (사용자 확인 필요)

| # | 질문 | 추천 | 영향 이슈 |
|---:|---|---|---|
| 21 | 메모리 펼침 프로세스 Top-3 **실제** 구현? | **예** (`libproc` phys_footprint) | [05](05-memory-and-top-processes.md) |
| 22 | CPU/GPU 온도 **Phase 0 실기 검증 spike** 수용? | **예** (검증 전 카드 `unavailable`) | [08](08-temperature-cpu-gpu-battery.md) |
| 23 | ~~레이아웃 **모드 A만** 출시?~~ **정정됨 → #29** (사용자 지시로 B/C 정식화) | ~~예~~ | [02](02-popover-mode-a-cards.md) |
| 24 | 폰트 **Pretendard JP 번들**? | **예** (픽셀 일치) | [01](01-app-skeleton-tokens.md) |
| 25 | 배포 채널 (개인 ad-hoc / 공유 Developer ID 공증) | 둘 다 | [17](17-packaging-notarization.md) |
| 26 | macOS 14→26 IOReport 채널 편차 → 런타임 탐색+graceful degrade | 수용 | [06](06-power-ioreport-soc.md) |
| 27 | 비공개 API(IOReport+SMC/HID) 위험 수용 (비-MAS) | 수용 | [06](06-power-ioreport-soc.md),[08](08-temperature-cpu-gpu-battery.md) |
| 28 | 배터리 온도 키/스케일 온디바이스 확인 | 포함 | [08](08-temperature-cpu-gpu-battery.md) |
| 29 | 레이아웃 **A/B/C 정식 구현**(설정 선택, #23 정정) — 기본값 A 유지 | **예** | [19](19-popover-layout-select-mode-b.md),[20](20-popover-mode-c-hero.md) |

가장 답이 급한 건 **#21·#22** — 범위·일정이 여기서 갈린다. (#23은 #29로 정정 완료.)

## 공통 시각 토큰 (모든 이슈 참조)

- accent `#0066ff` · 상태색 녹 `#00bf40` / 주황 `#ff9200` / 빨강 `#ff4242`
- 라이트 `c`: panelBg `#fff`, text `#171719`, sub `rgba(46,47,51,.6)`, faint `rgba(46,47,51,.45)`, cardBg `rgba(112,115,124,.06)`, line `rgba(112,115,124,.14)`
- 다크 `c`: panelBg `#212225`, text `#f7f7f8`, sub `rgba(247,247,248,.6)`, faint `rgba(247,247,248,.45)`, cardBg `rgba(174,176,182,.10)`, line `rgba(174,176,182,.16)`, settingsBg `#1b1c1e`, titlebar `#242527`
- 숫자는 전부 tabular-nums. 한국어 카피는 프로토타입 그대로. 푸터 "Wattly 1.0 · Created by jjundev".
- 기본 상태: 테마 dark, 전 지표 ON, 메뉴바 텍스트 ON(지표=CPU만), 주기 자동, 로그인 ON, 임곗값 CPU 70/90·메모리 70/85·온도 70/90, 카드순서 `[power, battery, cpu, mem, cpuTemp, gpuTemp, batTemp]`.
