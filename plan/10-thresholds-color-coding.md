# 10 — 그래프 임곗값 + 색상 코딩

> 막힘: 02,03 · 커버: (프로토타입 추가) · 결정표 매핑: #6
> 프로토타입 근거: `pickColor` line 574–578, 임곗값 슬라이더 line 266–290, 적용 line 601/606/616–621

## 목표

CPU·메모리·온도가 사용자 설정 임곗값을 넘으면 카드 값/스파크라인 색으로 경고한다. (PRD에 없던 프로토타입 추가 기능.)

## 범위 (In)

1. **임곗값 모델 (`@AppStorage`)**
   - `cpu { warn, crit }`, `mem { warn, crit }`, `temp { warn, crit }`(온도는 CPU·GPU 공용).
   - 기본값: CPU 70/90, 메모리 70/85, 온도 70/90.
2. **색상 매핑** (`pickColor`)
   - `v ≥ crit` → 빨강 `#ff4242` (fill `rgba(255,66,66,.12)`)
   - `v ≥ warn` → 주황 `#ff9200` (fill `rgba(255,146,0,.12)`)
   - else → 녹색 `#00bf40` (fill `rgba(0,191,64,.12)`)
   - 적용 대상: CPU%, 메모리 **%**(used/total×100 기준), CPU·GPU 온도°C. **전력=accent 고정, 배터리=중립 고정**(임곗값 미적용).
3. **설정 슬라이더 UI**(→ [13](13-settings-window-login-item.md) 안에 배치)
   - 행: 색점(주의=주황/부족·과열=빨강) + 라벨 + `range` + 값.
   - 범위: CPU/메모리 warn `10–95`·crit `20–100`; 온도 warn `40–100`·crit `50–110`.
   - 슬라이더 accent: 주의 `#ff9200`, 부족/과열 `#ff4242`.
   - 클램프: `warn`이 `crit` 초과 시 `crit=warn`, `crit`이 `warn` 미만 시 `warn=crit`(프로토타입 `setThreshold`).

## 범위 (Out)

- 온도 threshold **알림**(Out of Scope — 색상 코딩까지만). 지표별 개별 온도 임곗값(CPU·GPU 공용 하나).

## 수용 기준

- 값이 임곗값을 넘으면 카드 값·스파크라인 stroke/fill 색이 즉시 바뀐다(라이트/다크 모두).
- 슬라이더 조정이 패널에 실시간 반영되고 재시작 후에도 유지(`@AppStorage`).
- warn/crit 역전 입력이 클램프된다.
- `pickColor`·클램프 순수 함수 단위 테스트([18](18-testing.md)).
