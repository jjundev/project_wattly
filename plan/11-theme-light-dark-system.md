# 11 — 테마 라이트 / 다크 / 시스템

> 막힘: 01 · 커버: (프로토타입 추가) · 결정표 매핑: #5, #19
> 프로토타입 근거: 테마 세그먼트 line 244–251, `c` 팔레트 line 580–584, systemDark line 477–481

## 현실 (grill 결과)

테마는 **이미 ~80% 구현·배선되어 있다**. 이 plan은 신규 구축이 아니라 **검증 · 테스트 · 잔여 갭 마감**이다.

| 범위 항목 | 현황 |
|---|---|
| 1. 테마 모델 `@AppStorage` | ✅ `ThemeMode` + `Defaults.theme = .dark` + `StorageKey.theme` (`Theme.swift:6`, `Settings.swift:138,166`) |
| 2. 토큰 스왑 라이트/다크 | ✅ `Tokens.dark` / `Tokens.light` 전체, 프로토타입 `c`(581–582) 픽셀 일치 검증 완료 (`Tokens.swift:44`) |
| 3. 시스템 모드 (matchMedia → colorScheme) | ✅ `ThemeResolver.tokens`가 `dark = system ? systemDark : (mode==dark)` 그대로 재현 (`Theme.swift:31`) |
| 4. 팝오버·설정에 `preferredColorScheme` 적용 | ✅ 양 scene 모두 `ThemedRoot`로 래핑 (`WattlyApp.swift:25,37`) |
| 5. 설정 UI 세그먼트(피커) | ❌ **미구현** — `SettingsView`는 스켈레톤. 테마 피커 부재. |

## 목표

라이트/다크/시스템 3가지 테마. 기본은 다크. 이 plan은 위 표의 **❌ 1건 + 검증·테스트**를 마감한다.

## 범위 (In)

1. **`ThemeResolver` 단위 테스트** (`ThemeResolverTests.swift`) — 미배선 로직 중 유일하게 테스트 가치가 있는 순수 함수.
   - `preferredColorScheme`: light→`.light`, dark→`.dark`, system→`nil`
   - `tokens(mode, scheme)`: 3모드 × 2스킴 매트릭스 — system은 scheme를 따르고 light/dark는 무시함을 단언, 반환셋이 `Tokens.light`/`.dark`와 동일함을 단언.
2. **테마 피커 세그먼트** (결정 A) — `Picker(.segmented)`를 `@AppStorage(StorageKey.theme)`에 바인딩, `ThemeMode.allCases` 순회. `PollIntervalSetting`(`PollIntervalSetting.swift:19`)과 동일 패턴. 당장은 `SettingsView`에 배치(13에서 7섹션 레이아웃으로 재배치). 네이티브 스타일 사용, 커스텀 pill 칩은 이연(결정 B).
3. **토큰 위생** — `gridBorder`/`cText`/`segTrack`/`titlebar`는 **프로토타입 충실 토큰이나 Swift 뷰에서 아직 미사용**(graph grid·code text는 plan 10/13에서 배선). "forward-declared, plan 10/13에서 배선"이라는 주석을 달아 미래 독자가 비프로토타입으로 오인하지 않게 한다 (결정 C 정정).

## 범위 (Out)

- 커스텀 seg-pill 칩(→ [13](13-settings-window-login-item.md)), 7섹션 설정 레이아웃(→ 13), 메뉴바 아이콘 적응(→ [14](14-menubar-text-metrics.md)).
- 커스텀 강조색/색맹 팔레트, 카드별 개별 테마.

## 수용 기준

- [단위] `ThemeResolver` 매트릭스 테스트 그린.
- [수동] 피커가 팝오버·설정에 즉시 반영, 재시작 후 유지.
- [수동] 시스템 모드에서 macOS 외관을 바꾸면 앱도 라이브로 따라간다. (MenuBarExtra는 토큰 주도 렌더라 견고 — 결정 C; 설정 창 타이틀바만 별도 확인.)
- [검증완료] 라이트/다크 토큰이 프로토타입과 픽셀 일치 (이 grill에서 확인).

## 메모

- 다크가 기본이지만 메뉴바 아이콘은 template 이미지라 메뉴바 외관에 자동 적응(→ [14](14-menubar-text-metrics.md)).
- `preferredColorScheme` + `@Environment(\.colorScheme)` 동일-뷰 순서는 **구성상 정확**(light/dark는 scheme 무시, system은 nil) — 버그 아님. `ThemedRoot`의 외부=preferredColorScheme, 내부 `Resolver`=colorScheme 읽기 구조 유지(`Theme.swift:48-62`).
- `MenuBarExtra(.window)`는 `preferredColorScheme`를 무시할 수 있으나 팝오버가 주입 토큰 `t.panelBg`로 자체 배경을 그리므로(`PopoverContentView.swift:42`) 시각적으로 무해. 색상이 window 유효 외관이 아니라 mode에서 선택되기 때문.
- 가정 A(피커를 11 vs 13)는 코드상 성립하나 범위 경계 결정 — 11은 resolver+테스트로만 닫고 수용기준을 13으로 이연하려면 `#A=close-on-tests-only`로 뒤집기.
