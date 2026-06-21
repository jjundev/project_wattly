# 18 — 테스트 전략

> 막힘: 병렬(전 구간) · 커버: PRD Testing Decisions · 결정표 매핑: #15(seam)
> 근거: PRD Testing Decisions 절

## 목표

라이브 하드웨어에 의존하지 않고 **외부 동작만** 검증한다. 합성 입력 → 결정론적 출력. 구현 디테일(특정 Mach 호출 시퀀스)은 테스트하지 않는다.

## 범위 (In)

1. **프레임워크** — Swift Testing(또는 XCTest) 신규 스위트(greenfield, 기존 테스트 없음).
2. **단일 seam 통합** — 가짜 `MetricProvider`(미리 정한 `MetricSample` 시퀀스 반환)를 `SystemMonitor`에 주입 → 폴링·상태 전이·timestamp 60초 history·적응형 주기를 하드웨어 없이 검증([01](01-app-skeleton-tokens.md)).
3. **순수 함수 단위 테스트(고가치)**
   - `decodeAmperage` — 2의 보수(예 `18446744073709550678` → −938), 양수/음수/0 경계([07](07-power-battery.md)).
   - `cpuUsage(prev:curr:)` — tick 차분·idle 비율·코어 합산·0-델타([04](04-cpu-spine.md)).
   - `usedBytes` — VM 페이지→바이트, wired/compressed 합산([05](05-memory-and-top-processes.md)).
   - 온도 — key-info/FourCC·실측 data type decode·profile 선택·범위 filter·CPU/GPU hottest 집계([08](08-temperature-cpu-gpu-battery.md)).
   - `pickColor`·임곗값 클램프([10](10-thresholds-color-coding.md)), 메뉴바 조립 문자열([14](14-menubar-text-metrics.md)), 카드 재정렬([12](12-card-reorder-edit-mode.md)).
4. **상태 전이 테스트** — `loading→value`, 단일 지표 `unavailable` 시 나머지 유지(부분 실패 격리), 데스크톱(배터리 없음) 전력/배터리 카드 규칙.
5. **온도 상태 전이** — CPU 성공+GPU 실패와 반대, retryable/terminal, 즉시 1회 재연결, 1·2·4·8·16·30초 backoff, wake/enable reset, 두 토글 OFF 시 provider 미호출(호출 카운트, [09](09-adaptive-polling.md)).
6. **history 테스트** — 폴링 간격과 무관하게 60초 초과 sample 제거, 256개 상한 미초과([03](03-sparkline-history.md)).
7. **온도 실기 acceptance** — M5 독립 oracle 오차·각 3회 CPU/GPU 부하 기준 통과, sleep/wake 자동 복구, 한쪽 sensor 부재, 1시간 handle/메모리/wakeup 안정([08](08-temperature-cpu-gpu-battery.md) Phase 0).

## 범위 (Out)

- UI 스냅샷 픽셀 회귀(수동 대조로 충분). 라이브 하드웨어 의존 단위 테스트.

## 수용 기준

- 모든 순수 함수·상태 전이가 합성 fixture로 결정론적으로 통과.
- 온도 acceptance는 실기(M5)에서 별도 통과(자동화 불가 부분은 문서화).
- 가짜 provider/transport로 하드웨어 없이 CI 그린.
