# 12 — 카드 재정렬 + 편집 모드

> 막힘: 02 · 커버: (프로토타입 추가) · 결정표 매핑: #4
> 프로토타입 근거: ✎ 편집 버튼 line 69, 드래그 카드 line 79–80, `reorderCards` line 453–467, grip line 80

## 목표

사용자가 모드 A의 카드 순서를 드래그로 바꾼다. 편집 모드(✎)에서만 활성화. (PRD에 없던 프로토타입 추가.)

## 상태 (grill→review SHIP, 2026-06-22)

씨앗(seam)은 02·11에서 이미 깔려 있다 — `editMode` `@State` + ✎ 토글 버튼, `GripGlyph`(편집 모드에서만 표시), `@AppStorage(CardOrder)` 영속, `Defaults.cardOrder`, `visibleCards` 필터. 본 plan의 순수 신규 작업은 (1) 드래그 와이어링, (2) 순수 재정렬 함수 + 테스트, (3) 드래그 카드 dim, (4) 설정 열 때 편집 모드 해제 갭 닫기뿐이다.

## 범위 (In)

1. **순수 재정렬 로직** — `CardOrder.reordering(_ from:onto:) -> CardOrder` (Settings.swift, `CardOrder` 옆). 프로토타입 `reorderCards`(line 453) 분기 그대로: 아래로 드래그하면 `from`이 `target` **뒤**, 위로면 **앞**. 값-반환 순수 함수(`ThresholdPair.setting` 패턴) — `from==target`/미존재 시 `self` 반환. 전체 `cards` 배열 기준(숨김 카드 상대 위치 보존; from·target은 둘 다 visible이라 항상 존재). §26 단위 테스트 대상.
2. **드래그 와이어링** — `cardsStack`(PopoverContentView). **`DragGesture`** 기반(시스템 드래그앤드롭 아님 — 아래 NOTE). `@State draggingCard / dragOffset / homeShift / cardFrames` + `@Environment(\.accessibilityReduceMotion)` 추가. 제스처는 **편집 모드 분기에만** 부착(`if editMode { row.opacity(…).offset(…).gesture(dragGesture).animation(value: cardOrder) } else { row }`) → 비편집 행은 제스처 없음(프로토타입 `if(!editMode)return` 대응). 각 행은 `.background(GeometryReader)`로 자기 레이아웃 슬롯을 `CardFrameKey` preference에 발행. **실시간 재정렬**(`liveReorder`): 드래그 중 커서가 이웃 카드 중앙(`midY`)을 넘으면 한 칸씩 `cardOrder.reordering(card, onto: 이웃)` 즉시 적용, 밀려나는 카드는 `.animation(value: cardOrder)`로 슬라이드. 좌표계 `"wattly.cards"`.
   - **NOTE(런타임 결정 — 실측 후 #1 수정):** `MenuBarExtra(.window)` 팝오버 안에서는 `.onDrag`/`.draggable` 시스템 드래그 세션이 시작되지 않아 조용히 무반응(on-device 확인됨). 그래서 pasteboard 드래그앤드롭을 버리고 팝오버에서도 동작하는 `DragGesture`로 교체. 순수 `CardOrder.reordering`은 그대로 재사용(드롭-온-타깃 의미 동일).
   - **스워프 무-스터터(`homeShift`):** 드래그 카드의 렌더 오프셋 = `translation − homeShift`. 스왑마다 홈 슬롯이 이동한 양(`이웃.height + 8`)을 `homeShift`에 누적 → 1-프레임 지연되는 레이아웃 프레임을 읽지 않고도 커서에 정확히 붙어, 스왑 순간 끊김이 없다. 드래그 카드만 위치 애니메이션 없음(즉시), 나머지 카드만 슬라이드.
   - **드래그 카드 dim/플로팅/hit-test**: `.opacity(… ? 0.45 : 1)`(프로토타입 `dragKey → 0.45`) + `.offset(y: dragOffset)`(커서 추종) + `.zIndex(1)` + `.contentShape(Rectangle())`(grip 14px 빈 영역도 드래그 시작 가능).
   - **편집 모드 확장 탭 억제**: `onToggleExpand: editMode ? nil : (card.isExpandable ? { toggleExpand(card) } : nil)` — 드래그 중 카드 높이 변동 방지(강제 접힘은 안 함).
   - **재정렬 애니메이션**: `withAnimation(reduceMotion ? nil : .default)` 로 감싼다. (Reduce Motion 존중. NOTE: 코드베이스 첫 `withAnimation` — 기존 reduce-motion 선례는 `StatusDot`의 `.animation(…,value:)` 모디파이어뿐이라 *신규* 패턴이다.)
3. **편집 모드 해제** — `openSettingsRaised()`가 열기 전에 `editMode = false` (+ `draggingCard = nil`). 프로토타입 `openSettings`가 `editMode:false`를 설정하던 것과 일치(수용 기준 3).
4. **드래그 상태 정리** — `DragGesture.onEnded`가 `draggingCard = nil; dragOffset = 0`으로 항상 리셋(취소/슬롯-밖 드롭 포함)하므로 `.onDrag`류의 종료-콜백-부재 잔여 dim 문제가 없다. ✎ 토글·설정 열기도 `draggingCard = nil`.
5. **영속** — 기존 `@AppStorage(StorageKey.cardOrder)` (`CardOrder` RawRepresentable, CSV) 그대로 재사용. `cardOrder = newOrder` 대입이 자동 영속. 신규 영속 코드 없음. "기본값으로 되돌리기"가 순서도 리셋하는 UI는 [13](13-settings-window-login-item.md) 소관.

## 범위 (Out)

- 모드 B/C(미구현). 카드 크기 조절·숨김(숨김은 설정 표시지표 토글로).
- "기본값으로 되돌리기"의 순서 리셋 UI → [13](13-settings-window-login-item.md).

(NOTE: 실시간 셔플은 당초 Out이었으나 사용자 요청으로 IN 으로 전환 — `liveReorder` 구현. 위 #2 참조.)

## 수용 기준

- ✎ 활성 시 grip 표시, 드래그로 순서 변경, 재시작 후 유지.
- 비편집 모드에선 드래그 불가(드래그 모디파이어 미부착), grip 숨김.
- 설정을 열면 편집 모드가 꺼진다.
- 재정렬 순수 로직 단위 테스트(from/target 위/아래·인접·양끝·no-op·미존재 가드, [18](18-testing.md)) + `CardOrder` rawValue 왕복/빈문자·미지토큰 거부(기존 미커버).
