# 02 — 팝오버 모드 A · 카드 · 헤더

> 막힘: 01 · 커버: #2,15,16,17 · 결정표 매핑: #3, #13, #19
> 프로토타입 근거: line 62–174(패널·모드 A 카드), line 580–584(토큰)

## 목표

팝오버 패널과 **모드 A(스택 행)** 카드 레이아웃을 픽셀 일치로 만든다. 모드 A는 기본 레이아웃이며, B/C는 같은 셸 위에 별도 plan으로 추가된다(→ [19](19-popover-layout-select-mode-b.md)/[20](20-popover-mode-c-hero.md), 결정 #29가 #23을 정정).

## 범위 (In)

1. **패널 셸** — 폭 `320px`, radius `16`, padding `14`, border 1px `c.panelBorder`, bg `c.panelBg`, 패널 그림자(README 토큰). `max-height: calc(100% - 50px)`, 본문 세로 스크롤. (연결 화살표 삼각형은 cosmetic — `MenuBarExtra .window`가 기본 제공 안 하면 생략/근사. 메모 참조.)
2. **헤더** (padding `2 4 12`)
   - 좌: 번개 글리프(14px, fill `c.text`) + "Wattly"(13px/700) + **상태 점**(6px, pulse 2.4s, 녹 `#00bf40` 정상 / 주황 `#ff9200` 콜드·실패).
   - 우: ✎ 편집 버튼(26×26, radius 7, 활성 시 bg 파랑틴트+color accent → [12](12-card-reorder-edit-mode.md)) · ⚙︎ 설정 버튼(26×26, color `c.faint` → [13](13-settings-window-login-item.md) 엶).
3. **카드(범용)** — padding `11 12`, radius `12`, gap `8`, bg `c.cardBg`.
   - 헤더 행: 라벨(11.5px/600 `c.sub`) ↔ 값(19px/700 tnum) + 단위(12px/600 `c.sub`). 값 정렬 baseline.
   - 스파크라인(높이 26px, → [03](03-sparkline-history.md)).
   - sub 행(11px `c.sub`).
4. **카드 7종** (순서 `cardOrder`)
   - **프로세서 전력**: 값 색 = accent. 값 = Combined(CPU+GPU+ANE). sub "CPU x.x W · GPU y.y W · ANE z.z W". (→ [06](06-power-ioreport-soc.md))
   - **배터리**: 값 `c.text`, 부호 W, sub "±mA · V · 충전/방전 중", 스파크 area 없음. 데스크톱 숨김. (→ [07](07-power-battery.md))
   - **CPU**(클릭 → 펼침): 헤더에 chevron. sub "S xx% · E yy%". 펼침 시 코어 막대(→ [04](04-cpu-spine.md)).
   - **메모리**(클릭 → 펼침): 값 + "/ {total} GB". sub "고정 X.X GB · 압축 Y.Y GB". 펼침 시 Top-3(→ [05](05-memory-and-top-processes.md)).
   - **CPU 온도 / GPU 온도 / 배터리 온도**: 값 + °C(→ [08](08-temperature-cpu-gpu-battery.md)). 배터리 온도는 데스크톱 숨김.
5. **unavailable 카드**
   - 전력 실패: bg `rgba(255,146,0,.07)` border `rgba(255,146,0,.22)`, 경고삼각형 `#d47800`, 라벨 + 사유("Energy Model 그룹을 읽을 수 없음 — 이 macOS에서 채널이 바뀌었을 수 있습니다.").
   - 배터리 미가용: transparent + dashed border, slash-circle 아이콘 `c.faint`, 사유("배터리 없음 — 데스크톱 Mac"). *모드 A에선 데스크톱 시 배터리/배터리온도 카드를 아예 숨김.*
6. **카드 표시 규칙** — `card.visible`: 배터리·배터리온도는 `toggle && !desktop`, 나머지는 toggle. 가시성·순서는 `SystemMonitor`/`@AppStorage` 기반.

## 범위 (Out)

- 모드 B(그리드 → [19](19-popover-layout-select-mode-b.md))·모드 C(히어로+리스트 → [20](20-popover-mode-c-hero.md))는 **별도 plan**. 드래그 동작([12](12-card-reorder-edit-mode.md)). 색상 코딩([10](10-thresholds-color-coding.md)).

## 수용 기준

- 라이트/다크 양쪽에서 7종 카드가 프로토타입과 픽셀 일치(여백·radius·폰트 크기·색).
- 데스크톱 시나리오에서 배터리·배터리온도 카드가 사라지고 나머지 유지.
- 전력 실패 시 주황 경고 카드, 나머지 정상.
- CPU/메모리 카드 클릭 시 펼침 영역 토글(내용은 04/05).

## 메모

- `MenuBarExtra(.window)`는 화살표를 그리지 않을 수 있다. **내부는 픽셀 일치**시키고 연결 화살표는 cosmetic이라 생략 가능. 패널 폭/모서리/그림자는 윈도우 스타일로 재현.
