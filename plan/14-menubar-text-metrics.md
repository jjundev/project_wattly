# 14 — 메뉴바 텍스트 (다중 지표)

> 막힘: 01,04 · 커버: 스토리 10 · 결정표 매핑: #8, #20
> 프로토타입 근거: 메뉴바 아이템 line 52–55, 메뉴바 칩 line 300–308, 조립 line 662–669
> 상태: grill-yourself → grill-review(deep auto sonnet) **SHIP** (1회 REVISE 후) → 구현 대상

## 목표

메뉴바 아이콘 옆에 선택한 지표를 텍스트로 표시(옵션). 패널을 열지 않고 핵심 수치를 본다. (프로토타입은 PRD의 "메뉴바에 온도 미표시"를 덮어쓰고 온도 칩도 제공.)

## 범위 (In)

1. **메뉴바 아이템** — 번개 글리프(브랜드 `LightningGlyph` 인라인 stroke, `.foregroundStyle(.primary)`로 메뉴바 명암 자동 적응) + 선택 지표 텍스트(11px/600, tnum). 클릭 = 팝오버 토글.
   - *목업의 배터리 아이콘(100%)·시계는 macOS 시스템 크롬이지 Wattly 아님 — 렌더하지 않는다(결정 #20).*
2. **텍스트 표시 토글** — `menubarTextEnabled`(`@AppStorage`, 기본 ON). OFF면 아이콘만.
3. **표시 지표 다중 선택** — `menu.<card>` 칩(복수): CPU(%)·전력(W)·메모리(GB)·CPU 온도(°C)·GPU 온도(°C)·배터리 온도(°C). 기본 CPU만 ON. (배터리 net-power는 메뉴바 비대상 — 칩 없음.)
4. **조립 규칙**(프로토타입 line 662–669) — 선택된 지표를 `  ·  `(공백2·중점·공백2)로 join. 웜: "CPU 42%", "8.4 W", "9.2 GB", "CPU 54°C", "GPU 48°C", "배터리 31°C". 콜드/미가용: 장형 라벨 + " —" ("CPU —", "전력 —", "메모리 —", "CPU 온도 —", "GPU 온도 —", "배터리 온도 —"). 전력 미가용·콜드 → "전력 —", 배터리 온도 데스크톱(=`.unavailable(.notPresent)`) → "배터리 온도 —".
5. **폴링 영향** — 텍스트 ON이면 닫힘 폴링을 2초로(텍스트 갱신 위해, [09](09-adaptive-polling.md)) — 이미 라이브. 이번 이슈는 `menubarNeeds`를 선택 칩 집합으로 일반화.
6. **접근성** — 메뉴바 라벨에 VoiceOver 접근성 라벨([15](15-accessibility.md)).

## 범위 (Out)

- 메뉴바 sparkline/그래프(텍스트만). 아이콘 커스터마이즈.

## 수용 기준

- 칩 선택대로 메뉴바 텍스트가 조합·갱신되고, 토글 OFF 시 아이콘만.
- 콜드/미가용 지표가 "— " 형식으로 안전 표기.
- 템플릿 아이콘이 라이트/다크 메뉴바에서 모두 또렷.
- 조립 문자열 순수 함수 단위 테스트([18](18-testing.md)).

## 설계 결정 (grill SHIP)

| # | 결정 |
|---|---|
| 1 | 조립 로직은 **새 순수 `enum MenuBarText`**(`Wattly/Core/MenuBarText.swift`) — `CardPresentation`/`PollPolicy` 관용구. 단위 테스트 대상. |
| 2 | `CardPresentation.display`/`label` **재사용 안 함**. 메뉴바는 자체 카피 테이블. 근거: `CardPresentation.label(.power)`="프로세서 전력"인데 메뉴바 콜드는 "전력 —". |
| 3 | 웜: cpu·temp = 정수 라운딩, power·mem = 1소수(`CardPresentation.f1`); power는 라벨 없음("8.4 W"); 온도 웜=단형("CPU"), 콜드=장형("CPU 온도"). `MenuBarText.longLabel`은 독립 테이블. |
| 4 | join 구분자 `"  ·  "`. |
| 5 | 콜드/웜은 지표별로 각 카드의 `MetricState`에서 결정. `monitor.cardState(card)`(팬아웃된 카드 상태) 사용 → 데스크톱 batTemp가 `.unavailable(.notPresent)`로 자동 "배터리 온도 —". |
| 6 | 메뉴바 순서 = 고정 정준 순서 `[.cpu,.power,.mem,.cpuTemp,.gpuTemp,.batTemp]`. |
| 7 | 칩 0개 → `assemble` nil → 아이콘만. 텍스트 표시 ⇔ `textEnabled && assembled != nil`. |
| 8 | 전력값은 `cardState(.power, smoothed: powerSmoothed)`로 카드 헤드라인과 일치. `smoothed:`는 전 카드 균일 전달, `isSmoothable` 가드로 power 외 무해한 no-op. |
| 9 | `SystemMonitor.recomputeGating`: `[.cpu]` → `menubarMetrics`. `menubarMetrics` 필드(초기 시드 `[.cpu]`) + `setMenubarMetrics(_:) async`(gating-only, **reschedule 안 함** — `setShownCards` 미러). `activeProviders` 변경 없음(이미 파라미터화). |
| 10 | `PollPolicyBridge` +6 `@AppStorage(menu.*)` + 계산 `menubarMetrics`. **seed-before-start**(B5): `.task`에서 `setMenubarMetrics`를 `start()` 앞에 배치. `.onChange(of: menubarMetrics)`. |
| 11 | 글리프: 브랜드 `LightningGlyph` **인라인 stroke**(`ImageRenderer`/template `NSImage` 폐기 — Swift 6 non-Sendable `static let NSImage` 위험 + 캐시 미지정). 텍스트는 시스템 라벨 색(하드코딩 흰색 아님). |
| 12 | 폰트 `WattlyFont.at(11, weight: .semibold).monospacedDigit()`. |
| 13 | accessibilityLabel `"Wattly" + (assembled ? " · "+assembled)`. 전체 VoiceOver는 [15]. |
| 14 | cadence는 raw `menubarTextEnabled`로만 분기. "텍스트 ON + 칩 0개"는 아이콘만이지만 닫힘 2초 유지 — 의도된 트레이드오프(기본이 CPU 선택, 빈 선택은 드문 과도기; 빈 분기는 09 결정성 재오픈). |
| 15 | 새 `MenuBarTextTests` + `SystemMonitorTests`에 "숨긴 카드 + 메뉴바 지표 → 제공자 계속 폴링" 게이팅 케이스. |

## 구현 맵

- **신규** `Wattly/Core/MenuBarText.swift` — `order` / `part(_:_:)` / `assemble(selected:states:)` / private `longLabel`·`tempPart`.
- **수정** `Wattly/Views/MenuBarLabel.swift` — 6 `menu.*` + `menubarTextEnabled` + `powerSmoothed` 읽어 `selected`/`states` 조립; 인라인 `LightningGlyph` stroke + 옵션 `Text`.
- **수정** `Wattly/Core/SystemMonitor.swift` — `menubarMetrics` 필드 + `setMenubarMetrics(_:) async` + `recomputeGating`의 `[.cpu]`→`menubarMetrics`.
- **수정** `Wattly/Views/PollPolicyBridge.swift` — 6 `@AppStorage(menu.*)` + 계산 `menubarMetrics` + seed-before-start + onChange.
- **신규** `WattlyTests/MenuBarTextTests.swift` · **수정** `WattlyTests/SystemMonitorTests.swift`.
- 파일 추가 후 `xcodegen generate` 재실행.

## 미해결 (needs-you · best-guess로 진행)

- **A**(#11) 메뉴바 글리프: 브랜드 인라인 stroke ↔ `bolt.fill`(표준·위험 최소).
- **B**(#12) 메뉴바 폰트: Pretendard ↔ 네이티브 SF.
- **C**(#8) 전력값: EMA 평활 ↔ raw 순간값.
- **D**(#14) "텍스트 ON + 칩 0개" cadence: 2초 ↔ 5초.
