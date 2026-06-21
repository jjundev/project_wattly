# 01 — 앱 스켈레톤 · 디자인 토큰 · 상태 모델

> 막힘: None · 커버: 기반(15,21,24), MetricSample/State seam
> 결정표 매핑(master): #2, #13, #15, #16, #19, #20, #24 · grill 로컬 보강: L1–L19 (아래 §결정 레지스터)
> 프로토타입 근거: [`Wattly Interactive.dc.html`](../interactive/project/Wattly%20Interactive.dc.html) 전체 셸 · 토큰 line 581–584 · 상태 기본값 line 405–417 · 가짜 생성 line 488–547

## 목표

빈 화면 없이 동작하는 **픽셀 일치 셸**을 합성 데이터로 세운다. 이 단계가 끝나면 프로토타입과 동일하게 클릭·토글되는 앱이 뜨고, 이후 이슈는 가짜 provider를 진짜로 교체만 한다. **깨지면 안 되는 4개 seam**: ① enum `MetricSample` 경계, ② 주입식 clock, ③ `Tokens` 환경, ④ host-agnostic 패널 콘텐츠.

## 범위 (In)

1. **Agent 앱 골격**
   - XcodeGen(`project.yml`) → `.xcodeproj` 생성(L16). SPM executable 아님 — `.app` 번들·Info.plist·서명·로그인 항목이 번들을 요구.
   - `Info.plist LSUIElement = YES` (Dock 아이콘 없음).
   - 배포 타깃 macOS 14.0 (`@Observable` 하한, L18).
   - `MenuBarExtra` + `.menuBarExtraStyle(.window)` — 메뉴바 상주 + 클릭 시 팝오버. 콘텐츠는 host-agnostic `PopoverContentView`로 분리해 `NSStatusItem`+`NSPanel` 폴백을 저비용으로(L2).
   - `Settings` scene 빈 골격(내용은 [13](13-settings-window-login-item.md)).
   - `SystemMonitor` 1개를 App `@State`로 생성해 환경 주입(MenuBarExtra/Settings 공유). 메뉴바 = template 번개 아이콘 + 기본 텍스트 "CPU x%"(다중 조립은 [14](14-menubar-text-metrics.md)).
2. **디자인 토큰 레이어**
   - `Tokens` 값 타입 `.light`/`.dark` + `Environment` 주입 + 3-way `ThemeResolver`(L10). asset catalog 아님(강제 light/dark/system 표현 위해).
   - 값은 프로토타입 inline `c`(line 581–584) + README 공통표가 **진실의 소스**, DS CSS와 충돌 시 프로토타입 우선(L11). accent `#0066ff`, 상태색 녹 `#00bf40`/주황 `#ff9200`/빨강 `#ff4242`, 그림자(panel: `0 4px 8px -2px rgba(23,23,23,.18), 0 16px 32px rgba(23,23,23,.28)`).
   - tabular-nums 수식어(`.monospacedDigit()`), 폰트 Pretendard JP 가변 번들(L15 / 보류 #24=L17).
3. **상태 모델 (단일 seam)**
   - `enum MetricSample: Sendable`(L3) — `.cpu/.memory/.power/.battery/.temperature(TemperatureSnapshot)`, 케이스별 Sendable payload + capture `Instant`(L7). **액터 경계를 넘는 유일한 타입.** 원시 C 포인터는 provider 내부에서 즉시 소비·해제.
   - `enum MetricState { case loading | value(MetricSample) | unavailable(MetricUnavailableReason) }`(L5). reason은 타입드 enum(`.notPresent`/`.channelUnreadable`/`.temperature(TemperatureError)`/`.providerError`) + 지역화 카피.
   - `MetricProvider: Sendable` 프로토콜 — 직렬 백그라운드(.utility)에서 동기 C 호출, `MetricSample` 반환, cross-poll 원시 상태는 provider 내부 보유(L6).
   - `SystemMonitor` — `@MainActor @Observable`. 주입식 scheduler로 폴링(L8), 7개 `CardKind`별 `MetricState`를 5개 provider 샘플에서 파생(온도 스냅샷 → cpuTemp/gpuTemp/batTemp 3카드 fan-out, L4), `[CardKind: RingBuffer<(Instant, Double)>]` history(60s+256 계약, L9) 보유, 주입식 `ContinuousClock`(L7). SwiftUI 뷰는 이 모델만 관찰.
4. **가짜 provider** — 프로토타입 `basesFor`/`tick`(line 488–547)을 본떠 laptop/desktop/cold/fail 합성 시계열 생성. 콜드=`—`+상태점 주황(1.7초, **가짜 전용** — 프로덕션 콜드=첫 샘플까지, L14), fail=전력만 `unavailable(.channelUnreadable)`. 생성자 주입(`SystemMonitor(providers:clock:scheduler:)`), dev 시나리오는 launch arg/scheme env로 선택(출시 UI 아님, L14).
5. **`@AppStorage` 스캐폴딩** — 토글·임곗값·카드순서·테마·주기·로그인 키. 스칼라/enum은 개별 키, `cardOrder([CardKind])`·`thresholds`는 JSON `RawRepresentable`(L12). 기본값은 단일 `Defaults` 네임스페이스(앱스토리지 초기값 + "되돌리기" 공용). 기본 상태=프로토타입 line 405–417 + README 공통표(테마 dark, 전 지표 ON, 메뉴바 텍스트 ON=CPU, 주기 auto, 로그인 ON, 임곗값 70/90·70/85·70/90, `cardOrder=[power,battery,cpu,mem,cpuTemp,gpuTemp,batTemp]`).
   - **`loginItem`은 예외(F1):** `SMAppService.mainApp`이 OS 진실의 소스(PRD line 57); `@AppStorage`는 **UI 미러**일 뿐 런치 시 `SMAppService.status`와 reconcile해야 한다(외부에서 바뀌어 있을 수 있음). 배선은 [13](13-settings-window-login-item.md) 소유 — 01은 미러로만 표기하고 권위로 취급하지 않는다. 나머지 키는 `@AppStorage`가 권위.

## 범위 (Out)

- 진짜 시스템 데이터(각 provider 이슈). 카드 시각 디테일([02](02-popover-mode-a-cards.md)). 설정 UI([13](13-settings-window-login-item.md)). 적응형/정지([09](09-adaptive-polling.md)). 데모 하니스 상태(scenario/batteryMode/panelMode/warm, L13).

## 수용 기준

- 메뉴바 번개 아이콘 클릭 → 팝오버 토글. 다크 기본 테마로 뜬다.
- 콜드 스타트 1.7초 가짜 지연 동안 카드가 `—`, 상태점 주황 → 이후 값 채워지고 녹색(주입 clock으로 결정론).
- `fail` 시나리오에서 전력만 unavailable, 나머지 지표 정상(부분 실패 격리).
- 가짜 provider + 수동 clock 주입으로 하드웨어 없이 폴링·상태전이·history 검증 가능(테스트 seam, [18](18-testing.md)).
- `PopoverContentView`가 host 무지(無知) → AppKit 폴백 시 콘텐츠 무수정.

## 메모

- `MetricSample` enum은 onboarding의 핵심. 이후 모든 provider/온도(부분 실패 포함)가 이 한 타입으로만 경계를 넘는다 — 깨지면 동시성 모델 전체가 흔들린다.
- **clock 누락 보완(L7):** 주입식 clock 없이는 [18](18-testing.md)/[03](03-sparkline-history.md)/[09](09-adaptive-polling.md)의 history·적응형 결정론 테스트가 불가능 — 01에서 seam을 깐다.
- **호스트 리스크(L2):** `MenuBarExtra(.window)`가 외곽 그림자/모서리(16)/화살표를 못 맞추면 NSPanel로 교체. 콘텐츠 seam이 비용을 낮춘다. 화살표는 [02](02-popover-mode-a-cards.md)에서 cosmetic으로 인정.
- provider는 stateful(이전 CPU tick 등) — 평면 nonisolated 함수가 아니라 직렬 컨텍스트 확정 상태로 설계(L6).
- 보류 #24(폰트, =L17): SF Pro로 가면 한글 자간/굵기가 프로토타입과 달라 픽셀 일치가 깨진다. Pretendard JP 번들 추천(실현=L15).

## 결정 레지스터 (grill 로컬 L# — master 번호와 별개, F2)

> README 레지스터(line 60)의 master 번호와 bare 정수가 충돌하지 않도록 `L` 접두를 쓴다.
> 크로스워크: **L2** ⊂ master #2(네이티브 SwiftUI) · **L3/L4/L6** = master #15(단일 seam)+#13(상태모델) 구체화 · **L15** = master #24(폰트)의 "어떻게" · **L16** = master에 없음(신규).

### Confident

| L# | 결정 | 근거 |
|---:|---|---|
| L1 | Swift 6 full 언어 모드(strict concurrency complete) | 툴체인 6.3.2/Xcode 26.5(PRD line 4,53); Sendable seam 전제 |
| L2 | 셸 = `MenuBarExtra(.window)` + host-agnostic 콘텐츠, NSPanel 폴백 | 콘텐츠 SwiftUI라 호스트 교체 저비용; 화살표 cosmetic([02](02-popover-mode-a-cards.md)) |
| L3 | `MetricSample` = enum, 케이스별 Sendable payload | PRD line 74 `MetricSample.temperature(...)` 문법과 1:1 일치 |
| L4 | 5 provider 샘플 → 7 카드, 온도 스냅샷 → 3카드 fan-out | 부분 실패 격리(PRD line 74/82) |
| L5 | `unavailable` = 타입드 `MetricUnavailableReason` | 프로토타입이 사유별로 다른 카드 렌더(line 684–685, 718). String 분기 불가. retryable/terminal은 PRD line 83–84(온도)의 개념 — 프로토타입엔 재시도 UI 없음(grep 0건). |
| L6 | provider 직렬 off-Main(.utility) 동기, MetricSample만 MainActor 홉 | 블로킹 C API UI 비차단; `cpuUsage(prev:curr:)`가 stateful 요구(PRD line 61) |
| L7 | 주입식 monotonic clock(ContinuousClock/수동), 샘플이 capture Instant 보유 | [18](18-testing.md)/[03](03-sparkline-history.md)/[09](09-adaptive-polling.md) 결정론 테스트 전제(원본 01 누락) |
| L8 | 01 고정주기 실동작 폴링(주입식 scheduler) | 콜드→웜→값 수용기준; 적응형·tolerance·QoS·정지는 [09](09-adaptive-polling.md) |
| L9 | history `[CardKind: RingBuffer<(Instant,Double)>]`, 60s+256 계약 01 | 스칼라 저장(샘플 전체 X); 렌더·엣지테스트는 [03](03-sparkline-history.md) |
| L10 | 토큰 = `Tokens` 값타입(light/dark)+Environment+3way resolver | 강제 light/dark/system은 asset catalog 불가([11](11-theme-light-dark-system.md)) |
| L11 | 토큰 값 출처 = 프로토타입 `c`(581–584)+README, 충돌 시 프로토타입 우선 | "동일하게 구현"; DS CSS는 상이(예: line .22 vs .18) |
| L12 | `@AppStorage` 스칼라 개별키 + cardOrder/thresholds JSON RawRepresentable, 단일 Defaults | native 배열/딕셔너리 미지원; init/reset 드리프트 차단 |
| L13 | SystemMonitor=지표/추이/폴링; 설정·테마 분리; 데모 하니스 상태 비모델링 | 갓오브젝트 방지([11](11-theme-light-dark-system.md)/[13](13-settings-window-login-item.md)); warm→loading, panelMode 소멸(#23) |
| L14 | 가짜 provider 생성자 주입; dev 시나리오 launch arg; 1.7s=가짜 전용 | CONTROL STRIP=데모 하니스(README line 13) |
| L15 | Pretendard JP 가변 번들 + `ATSApplicationFontsPath`, Wanted Sans 제외 | 프로토타입은 Pretendard만 사용(line 11,21); OFL 라이선스 |

### 가정 / 확인 필요

| L# | 질문 | 기본값 | flip 시 영향 |
|---:|---|---|---|
| L16 | 프로젝트 tooling | XcodeGen → `.xcodeproj` 생성 | PRD line 53은 프로젝트 *타입*(SPM executable 아닌 Xcode 앱 번들)만 지정 — 생성 vs 직접 커밋은 미결, **deviation 아님**. XcodeGen=재현성↑·pbxproj 충돌↓·도구 의존; `#L16=xcodeproj`=도구 무의존 |
| L17 | (master #24) 폰트 **번들 여부** | Pretendard JP 번들(픽셀 일치) | SF Pro=번들無·앱 용량↓·픽셀 불일치 |
| L18 | 배포 최저 macOS | 14.0 유지(PRD) | 온도 M5 전용·개발기 26.5 — 14.0까지 테스트 비용 대비 실익은 제품 판단 |
| L19 | 카피 다국어 | 한국어 단독(프로토타입 그대로), String Catalog 골격만 | i18n 선도입은 비용·범위↑ |

> 결정을 뒤집으려면 `#L<n>=<value>`로 재-grill.
