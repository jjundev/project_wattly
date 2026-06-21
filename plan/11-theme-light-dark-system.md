# 11 — 테마 라이트 / 다크 / 시스템

> 막힘: 01 · 커버: (프로토타입 추가) · 결정표 매핑: #5, #19
> 프로토타입 근거: 테마 세그먼트 line 244–251, `c` 팔레트 line 580–584, systemDark line 477–481

## 목표

라이트/다크/시스템 3가지 테마를 제공한다. 기본은 다크(프로토타입 기본). (PRD에 없던 프로토타입 추가.)

## 범위 (In)

1. **테마 모델 (`@AppStorage`)** — `themeMode = light | dark | system`. 기본 `dark`.
2. **토큰 전환** — [01](01-app-skeleton-tokens.md)의 `c` 팔레트를 테마에 따라 스왑(라이트/다크 값은 README 공통 토큰 + 프로토타입 line 581–582 그대로). accent·상태색은 공통.
3. **시스템 모드** — macOS 외관 변화 관찰(SwiftUI `colorScheme` / `NSApp.effectiveAppearance`). 시스템 다크/라이트 전환 시 즉시 반영(프로토타입 `matchMedia` 대응).
4. **적용 범위** — 팝오버·설정 창 전체. `preferredColorScheme`로 강제(light/dark) 또는 nil(system).
5. **설정 UI** — 세그먼트 라이트/다크/시스템 설정(→ [13](13-settings-window-login-item.md)).

## 범위 (Out)

- 커스텀 강조색/색맹 팔레트. 카드별 개별 테마.

## 수용 기준

- 세 모드 전환이 팝오버·설정에 즉시 반영, 재시작 후 유지.
- 시스템 모드에서 macOS 외관을 바꾸면 앱도 따라 바뀐다.
- 라이트/다크 토큰이 프로토타입과 픽셀 일치.

## 메모

- 다크가 기본이지만 메뉴바 아이콘은 template 이미지라 메뉴바 외관(밝음/어두움)에 자동 적응(→ [14](14-menubar-text-metrics.md)).
