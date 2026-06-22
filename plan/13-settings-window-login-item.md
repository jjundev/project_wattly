# 13 — 설정 창 + 로그인 항목

> 막힘: 01,09,10,11,14 · 커버: 스토리 10,12,13,14 · 결정표 매핑: #16, #11
> 프로토타입 근거: 설정 창 line 228–336

## 목표

표시 지표·테마·임곗값·메뉴바·폴링·로그인 항목을 한 창에서 설정한다. SwiftUI `Settings` scene + `@AppStorage`.

## 그릴 결정 (grill-yourself + grill-review deep/auto, 2회 반복 후 SHIP)

기존 코드가 plan 가정보다 앞서 있음 — `Settings` scene·게이팅 배선(`PollPolicyBridge`)·EMA 백엔드·임곗값/테마/폴링 순수 로직은 이미 존재. 13의 순 신규 작업은 **커스텀 크롬 UI + 로그인 항목 + 되돌리기 + 푸터**.

**Confident**
1. **창 크롬** — 프로토타입의 가짜 신호등 타이틀바는 웹 프로토타입 아티팩트. 네이티브 `Settings` 창 크롬을 그대로 사용(닫기만 활성 = 프로토타입과 동일). 가짜 40px 바를 렌더하지 않음.
2. 스캐폴드 3종(`ThemeSetting`/`PollIntervalSetting`/`ThresholdSettings`, 네이티브 컨트롤)을 커스텀 크롬으로 교체 — "픽셀 일치" 수용기준 + `segTrack` 등 토큰이 이 용도로만 존재.
3. 재사용 컴포넌트 추출: `WattlyToggle`(38×22/radius 11/knob 18, on=accent, left 2↔18) + `WattlySegment` + `SettingsSection`/`SettingsRow`. → `Wattly/Views/SettingsComponents.swift`.
4. **전력 표시(EMA)** 섹션을 표시 지표와 그래프 임곗값 사이에 추가. `StorageKey.powerSmoothed` 토글 한 줄 — 백엔드 완료(`cardState(_:smoothed:)`).
5. 표시 지표 토글은 `show.<card>` 키만 기록 — 모니터 게이팅은 `PollPolicyBridge`가 이미 관찰/푸시(신규 배선 불필요).
6. **되돌리기** — `Wattly/Core/SettingsReset.swift`의 **동기** `applyDefaults(into:login:)`가 `CardKind.allCases`를 순회해 모든 `show.*`/`menu.*` + `cardOrder` + `expandedCards`("") + 테마/폴링/EMA/임곗값을 `Defaults`에서 다시 기록하고, 로그인은 토글과 **동일한 에러-원복 경로**(`LoginItem`)로 `Defaults.loginItem`(true)에 재동기. `UserDefaults` 주입으로 단위 테스트 가능.
7. 되돌리기 확인 다이얼로그 없음(프로토타입 `resetDefaults` 즉시 동작).
8. 로그인 토글: `@AppStorage(loginItem)`은 **표시 미러**, `SMAppService.mainApp`이 authoritative. `.task`에서 `service.status`로 미러 reconcile. 토글 시 register/unregister, **예외 시 미러 원복**. → `Wattly/Core/LoginItem.swift`(동기 `setEnabled(_:) throws` — `SMAppService.register()`는 `throws`이지 `async throws` 아님).
9. 임곗값 crit 라벨은 현재 **주의/위험** 유지(프로토타입 "부족/과열"은 복사 버그).
10. 메뉴바 칩 멀티셀렉트 UI를 지금 구현(`menu.<card>` 기록). 단 **메뉴바 가시 효과는 plan 14**(조립 미구현)까지 보류 — 영속만 동작.
11. 창 크기: 폭 440 고정, `ScrollView` 본문(padding 18, gap 18), `TabView` 없음. `WattlyApp`의 `Settings` scene에 `.windowResizability(.contentSize)` 추가로 폭 고정.
12. **팝오버 즉시 반영(F1)** — `PopoverContentView.isShown()`이 `UserDefaults.standard`를 직접 읽어 외부 쓰기에 재렌더되지 않음. `show.*` 7개 `@AppStorage` 프로퍼티를 추가해 `visibleCards`가 라이브 재계산.

**가정 / 확인 필요**
- **A (푸터 자체소비)** — plan 16 미구현·`SystemMonitor.selfPower` 부재. 푸터는 "Wattly 1.0 · 자체 소비 **—**" + "Created by jjundev"로 출하, plan 16에서 라이브 값 점등.
- **B (서명)** — `CODE_SIGN_IDENTITY = "-"`(ad-hoc)·entitlements 없음. "재부팅 후 자동 실행" 수용기준은 **Developer-ID 서명 빌드(plan 17)에서만 검증**. 13 범위 수용기준은 "register/unregister가 crash 없이 호출/동기"로 축소.
- **C** — 되돌리기가 `expandedCards`도 ""로 초기화(팝오버 펼침 상태 리셋).
- **D** — 배포 타깃 **14.0**(13.0 아님). `SMAppService`는 13+ 가용 → `#available` 불필요.

**프로젝트 통합(F2)** — `SettingsComponents.swift`(Views), `LoginItem.swift`·`SettingsReset.swift`(Core), `SettingsResetTests.swift`(Tests)를 `project.pbxproj`에 등록하고 스캐폴드 3종을 동일 변경에서 제거. `ServiceManagement`는 `SDKROOT=macosx` 자동 링크(명시 링크 불필요).

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

- 섹션이 프로토타입과 픽셀 일치(라이트/다크). (창 타이틀은 네이티브 `Settings`가 `CFBundleDisplayName`="Wattly"를 사용 — best-effort.)
- "전력 평활(EMA)" 토글이 프로세서 전력 카드의 헤드라인+스파크라인을 평활↔raw로 즉시 전환(`powerSmoothed`), 재시작 후 유지.
- 로그인 토글이 `SMAppService` register/해제를 crash 없이 호출하고 미러를 동기화(예외 시 원복). **재부팅 후 자동 실행은 Developer-ID 서명 빌드(plan 17)에서 검증**(가정 B).
- 표시 지표 토글이 **팝오버에 즉시 반영**(F1)되고 재시작 후 유지. "되돌리기"가 전부 기본값 복원(`expandedCards` 포함).
- 푸터: 자체 소비는 plan 16 점등 전까지 "—"(가정 A). "Created by jjundev" 표기.
