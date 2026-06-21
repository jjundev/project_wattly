# 12 — 카드 재정렬 + 편집 모드

> 막힘: 02 · 커버: (프로토타입 추가) · 결정표 매핑: #4
> 프로토타입 근거: ✎ 편집 버튼 line 69, 드래그 카드 line 79–80, `reorderCards` line 453–467, grip line 80

## 목표

사용자가 모드 A의 카드 순서를 드래그로 바꾼다. 편집 모드(✎)에서만 활성화. (PRD에 없던 프로토타입 추가.)

## 범위 (In)

1. **편집 모드 토글** — 패널 헤더 ✎ 버튼. 활성 시 bg 파랑틴트 + color accent, grip 핸들 표시. 설정 열면 편집 모드 해제(프로토타입 `openSettings`).
2. **드래그 핸들(grip)** — 편집 모드에서만 카드 좌측에 6-dot grip(width 14, color `c.faint`, cursor grab). 드래그 중 카드 opacity 0.45.
3. **재정렬 로직** — `cardOrder` 배열에서 from→target 위치 재배치(프로토타입 `reorderCards`: 아래로/위로 이동 분기). SwiftUI `onDrag`/`onDrop` 또는 `draggable`/`dropDestination`.
4. **영속** — `cardOrder`를 `@AppStorage`(JSON 인코딩 등). 기본 `[power, battery, cpu, mem, cpuTemp, gpuTemp, batTemp]`. "기본값으로 되돌리기"가 순서도 리셋([13](13-settings-window-login-item.md)).

## 범위 (Out)

- 모드 B/C(미구현). 카드 크기 조절·숨김(숨김은 설정 표시지표 토글로).

## 수용 기준

- ✎ 활성 시 grip 표시, 드래그로 순서 변경, 재시작 후 유지.
- 비편집 모드에선 드래그 불가, grip 숨김.
- 설정을 열면 편집 모드가 꺼진다.
- 재정렬 순수 로직 단위 테스트(from/target 위/아래 케이스, [18](18-testing.md)).
