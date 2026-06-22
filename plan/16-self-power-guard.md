# 16 — 자체 전력 회귀 가드 (도그푸드)

> 막힘: 06 · 커버: 스토리 20 · 결정표 매핑: #11
> 프로토타입 근거: 설정 푸터 "자체 소비 X.XX W" line 331, `selfWatt` line 587
> grill-yourself → grill-review(deep auto) SHIP (iter 3), 2026-06-22

## 목표

본 앱이 **자기 전력 소비를 스스로 측정**해 회귀를 감시한다. 업데이트가 모니터를
전력 먹는 앱으로 만들지 않게 — PRD "전력 도구가 전력을 많이 쓰면 모순"(PRD.md:11)의
안전장치다. 측정값으로 **적응형 폴링 cadence(09)** 가 실제로 우리 소비를 낮추는지
도그푸드 검증한다. (팝오버를 닫으면 `MenuBarExtra(.window)`가 뷰 트리를 unmount하지만
명시적 "render-stop"은 아니다 — 측정 델타는 cadence가 지배하므로 벤치마크는 cadence
중심으로 잡는다. issue 03을 출하된 협력자로 주장하지 않는다.)

## 측정 메커니즘 (06의 IOReport 경로가 **아님**)

IOReport "Energy Model"은 **SoC 전체** 단위라 프로세스별 채널이 없다(06 findings 확인).
대신 `proc_pid_rusage(getpid(), RUSAGE_INFO_V6).ri_energy_nj` — **프로세스별 누적 에너지
카운터(나노줄)** 를 쓴다. 공개·무권한 API로, `MemoryProvider`가 이미 쓰는 libproc 표면과
동일하다. 두 스냅샷 차분 ÷ 경과시간 = 평균 자체 전력(W). `PowerEnergy`와 같은 에너지→W
형태이되 169채널 딕셔너리가 아니라 스칼라 하나라 별도의 작은 파일에 둔다.

기기 검증(M-시리즈, 2026-06-22): 바쁜 루프 ≈ 6.6 W, 잠듦 ≈ 0 W. 카운터는 task-scoped라
Wattly 자신의 CPU+GPU 작업은 잡지만 우리 창을 합성하는 WindowServer(별도 프로세스) 비용은
**포함하지 않는다** — 자기 회귀 가드에 맞는 범위.

## 범위 (In)

1. **자체 측정** — `Core/SelfEnergy.swift`: `SelfEnergySampling` 프로토콜(테스트 페이크용
   심) + libproc 래핑 `LiveSelfEnergy`. `Core/SelfPower.swift`(순수):
   `watts(prevNanojoules:currNanojoules:dt:) -> Double?` = `Double(curr-prev)/1e9/dt`,
   이상치(dt≤0 / dt>30s 갭(슬립·웨이크; `ContinuousClock`은 슬립 중 전진) / curr<prev
   카운터 리셋)에는 nil → 리베이스라인. `PowerProvider`의 자세와 동일.
2. **샘플링 위치** — `SystemMonitor.sampleSelfPower(at:)` 내부 메서드를 **타이머 폴 루프
   본문**(`start()`)에서 `pollOnce()` 뒤에 1회 호출. `pollOnce()` 내부에서 부르지 **않음** —
   out-of-band 호출자 3곳(`setMemoryProcessEnumeration` / `recomputeGating` / reschedule
   진입 폴)이 sub-interval dt 샘플을 주입하는 걸 막는다. 이 메서드는 `ManualClock`으로
   **테스트가 직접 호출** 가능(기존 `pollOnce()` 직접 구동 패턴과 동일). MetricProvider/
   ProviderKind/CardKind 아님 — 5→7 카드 심 불변.
3. **표시** — 설정 푸터 "Wattly 1.0 · 자체 소비 **X.XX W**"(소수 2자리, `monitor.selfPower`).
   콜드/대기 시 "—". `SystemMonitor.selfPower: Double?`(@Observable). 스무딩은
   `PowerSmoothing.emaStep`(τ≈4s) 재사용 — interval-독립성은 `1−e^(−dt/τ)`에서 공짜 상속
   (별도 설계 불필요); selfPower 자신이 EMA 이전값이 된다.
4. **회귀 기준값** — 수동 spot-check 벤치마크(자동 CI 게이트 아님: CI 인프라 없음, Apple
   Silicon 에너지 카운터는 실기기·통제부하 필요). 기준값을 `docs/self-power-baseline.md`에
   commit+머신+macOS 태깅으로 기록, 회귀 = 3회 평균이 기준 ×1.2 초과.
5. **저전력 검증 연계** — 절전 경로(닫힘·온도 카드 OFF)에서 측정 자체 소비가 내려가는지
   관찰. "온도 OFF" = 온도 카드 2개 숨김(마스터 토글 없음; SMC 게이팅은 per-card cpuTemp/
   gpuTemp 가시성에 연동). 그 절감은 노이즈 수준일 수 있어 down-weight; 헤드라인 증명은
   cadence(열림 vs 닫힘) 단조성.

## 범위 (Out)

- 외부 텔레메트리 전송. powermetrics 기반 정밀 측정(root 필요). 자동 CI 게이팅.

## 회귀 절차 (수동 spot-check)

Release 빌드 · 30초 워밍 후 각 상태 60초 평균 selfPower 기록:
- **OPEN**: 팝오버 열림 → 1초 cadence + 팝오버 렌더링.
- **CLOSED-기본**: 팝오버 닫힘, 메뉴바 텍스트 ON → **2초** cadence (`Defaults.menubarTextEnabled = true`).
- **CLOSED-심층**: 팝오버 닫힘, 메뉴바 텍스트 OFF → **5초** cadence.

기대 `OPEN ≥ CLOSED-2s ≥ CLOSED-5s` (단조, **관찰형** — 숫자만 기록; strict 합부 판정
안 함. 항상 렌더되는 메뉴바 라벨이 닫혀도 폴링·재렌더하므로 델타가 작거나 노이즈일 수 있음).

## 수용 기준

- 워밍 시 푸터에 라이브 자체 소비 W, 콜드 시 "—".
- 3개 기록값이 단조 비증가(open→closed-2s→closed-5s)이며 기준값으로 기록.
- 순수 계산(`SelfPowerTests`) + fake-reader 통합(`SystemMonitorTests`) 유닛 테스트.

## 메모 / 남은 플래그

- 이 가드가 PRD의 "전력 도구가 전력을 많이 쓰면 모순" 원칙을 지키는 안전장치다.
- **needs-you(미검증 가정)**: 표시 단위 `0.00 W`(2자리) vs `mW` 전환(제품 판단); 14.0
  실기기에서 `ri_energy_nj` 런타임 채워짐(여기선 26.5.1만 검증 — Δenergy=0이면 "—"로 우아하게).
- 수용된 nit(C2): `reschedule()` 진입 재실행이 small-positive dt 샘플 1회 생성 → EMA 감쇠로
  무해(이상치 리베이스라인은 dt≤0/>30s만 잡고 small-positive는 통과; 의도된 수용).
