# 03 — 스파크라인 + 60초 추이

> 막힘: 01 · 커버: 스토리 9,19 · 결정표 매핑: #14
> 프로토타입 근거: `spark()` (`interactive/project/Wattly Interactive.dc.html:549-564`),
> `.wa-spark` CSS (`:15`, **height 26px**), area/poly 사용 카드들
> 상태: grill-review SHIP (수정본 반영). 잔여 1건은 §남은 플래그 참조.

## 목표

각 지표의 최근 추이를 미니 그래프로 그린다. 순간값뿐 아니라 흐름을 보여주되, 패널이 닫히면 렌더를 멈춰 자원을 쓰지 않는다.

## 선행 사실 (이미 구현·green — 이 이슈의 작업 아님)

- **추이 저장**: `HistoryBuffer`가 monotonic `ContinuousClock.Instant` 기준 60초 창 + 256 상한 유지(`Wattly/Core/History.swift:14-31`). 두 경계 모두 `HistoryTests.swift:7-24`로 검증됨. → 본 이슈는 저장 코드를 **추가하지 않는다**.
- **색/채움 바인딩**: `MetricCardView`가 `sparkStroke`(전력→accent, 그 외 `t.spark`), `sparkFill`(전력→`rgba(0,102,255,.10)`, 그 외 `t.sparkFill`), `hasSparkArea = card != .battery`를 이미 계산하고, battery엔 `fill: nil`을 넘긴다(`MetricCardView.swift:155-160,29`).
- **콜드 게이트**: 카드는 `hasValue`일 때만 `SparklineView`를 mount한다(`MetricCardView.swift:28`).

따라서 본 이슈는 **(1) `SparklineView` 실제 렌더 구현**(현재는 1px 플레이스홀더 `SparklineView.swift:13-18`)과 **(2) 패널 닫힘 시 렌더 정지**로 축소된다.

## 범위 (In)

1. **순수 기하 (`Wattly/Core/Sparkline.swift`, 신규)**
   - `geometry(_ values: [Double]) -> (line: [CGPoint], area: [CGPoint])?`, **120×28 viewBox 좌표계**.
   - `n = values.count`; `n < 2`면 `nil`.
   - `mn = min`, `mx = max`; `mx - mn < 1e-6`이면 `mx = mn + 1`(분모 보정).
   - `x = i/(n-1) * 120` (항상 풀폭으로 신축 — 우측 정렬·좌측 여백 없음).
   - `y = 3 + (1 - (v-mn)/(mx-mn)) * (28 - 6)` (상하 패딩 3, viewBox 단위).
   - `area = [(0,28)] + line + [(120,28)]`.
   - 순수·`Sendable`·SwiftUI import 없음(결정론적 단위 테스트 대상 → [18](18-testing.md)).
   - 프로토타입 `spark()`의 `.toFixed(1)` 문자열 반올림은 **의도적으로 생략**(CGPoint엔 부적합). 테스트의 "정확 좌표" 기대값은 반올림 없는 공식으로 계산.
2. **스파크라인 렌더 (`SparklineView`, 플레이스홀더 교체)**
   - `Canvas { ctx, size in … }`. `Sparkline.geometry(values)` 호출, `nil`이면 아무것도 그리지 않음.
   - 좌표 매핑: `px = x/120 * size.width`, `py = y/28 * size.height` (x·y 독립 신축 = `preserveAspectRatio="none"`).
   - **밴드 높이 26px**: viewBox는 28-unit, 26px 프레임으로 squash — 라이브 프로토타입(28-unit viewBox → 26px 요소)과 동일. `.frame(height: 26)` 유지. (`ht=28`은 좌표 높이일 뿐 렌더 높이가 아니므로 26 vs 28 충돌은 없음.)
   - **area + line**: `fill != nil`이면 area Path를 채우고, 그 위에 line Path를 stroke.
   - stroke: `StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)`. Path를 **디바이스 좌표로 빌드한 뒤** stroke하므로 1.5pt는 squash되지 않음 = 프로토타입 `vector-effect="non-scaling-stroke"` 재현.
3. **색/채움 바인딩** (이미 카드 계층에 구현됨 — §선행 사실)
   - 전력: stroke = accent, area = `rgba(0,102,255,.10)`. / 배터리: stroke = `t.spark`(중립), **area 없음**(`fill: nil`). / CPU·메모리·온도: 임곗값 색([10](10-thresholds-color-coding.md)) 전까지 중립색. `SparklineView`는 색에 무관(넘겨받은 stroke/fill만 사용).
4. **콜드/미가용** — `count < 2`(또는 미warm)면 빈 그래프. 카드의 `hasValue` 게이트를 이중 보강.
5. **렌더 정지** — 패널이 닫히면 `MenuBarExtra(.window)`가 popover 콘텐츠 뷰를 언마운트한다(`WattlyApp.swift:19,27`). 그러면 `PopoverContentView` 본문과 그 안의 모든 `SparklineView`가 뷰 트리에서 빠지므로 Canvas 렌더가 돌지 않는다. per-frame 타이머가 없고(렌더는 오직 `@Observable` 폴 틱으로만 구동), **명시적 `panelVisible` 플래그를 두지 않는다** → `MetricCardView` 무수정 유지(§3). 데이터 폴링 자체를 낮추는 것은 [09](09-adaptive-polling.md).

## 범위 (Out)

- Activity Monitor급 풀 히스토리 차트(60초 슬라이딩까지만). 임곗값 색 산출 로직([10](10-thresholds-color-coding.md)). 적응형 폴링·폴링 주기 감소([09](09-adaptive-polling.md)).
- 데스크톱/모드-B 그리드 스파크의 인라인 `height:22px` 오버라이드(`…dc.html:179+`) — 해당 카드 구현 시 처리.

## 구현 단계

A. `Wattly/Core/Sparkline.swift` 추가 (§In-1).
B. `SparklineView` 플레이스홀더를 Canvas 구현으로 교체 (§In-2).
C. `WattlyTests/SparklineTests.swift` — 기하 표 테스트: 평탄 입력 ⇒ `mx=mn+1`·NaN 없음 / 알려진 3점 입력 ⇒ 정확 좌표(반올림 없는 공식) / `count<2` ⇒ `nil` / area 첫·끝 = `(0,28)`/`(120,28)`.
D. **간격 독립 테스트(신규)** — `HistoryBuffer`에 동일 60초 span을 1·2·5초 간격(주입 instant)으로 넣어 보관 span ≈60초·count ≤256 검증. (기존 `HistoryTests`는 60초 드롭·256 상한 경계만 다룸 — 간격 가변은 미커버.)
E. **렌더 정지 검증(단위 테스트 아님)** — 현 seam으로는 단위 테스트 불가. Canvas draw 클로저의 계측 카운터(또는 os_signpost)로 패널 닫힘 후 draw가 멈추는지 수동 확인. (수용 기준이며 명시적 수동 단계.)
F. 오토스케일·area+line 모양을 프로토타입과 시각 대조.
G. 파일 추가 후 xcodegen 재생성(클래식 비동기 소스 리스트) → `xcodebuild` build + test.

## 수용 기준

- 폴링 주기를 1/2/5초로 바꿔도 항상 직전 60초가 표시되고 sample이 256개를 넘지 않는다. (단계 D)
- 패널을 닫으면 그래프 렌더가 멈춘다(자원 미사용). (단계 E, 수동 검증)
- 오토스케일·area+line 모양이 프로토타입과 일치. (단계 F)

## 남은 플래그 (가정 아님 — 검증 대상)

- §In-5는 `MenuBarExtra(.window)`가 닫힘 시 실제로 콘텐츠를 언마운트한다는 런타임 동작에 의존한다(정적으로 검증 불가). 단계 E에서 on-device 확인 필수. 만약 콘텐츠가 살아있으면(warm 유지) `onDisappear` 게이트로 폴백하며, 그 경우 `MetricCardView`에 `isVisible` 파라미터를 추가해야 하므로 §3의 "무수정"이 깨진다.

## 메모

- history 60초 보장·간격 독립은 순수 함수로 분리해 결정론적 단위 테스트(시각 주입) 대상([18](18-testing.md)). 스파크라인 기하도 동일하게 순수 분리.
