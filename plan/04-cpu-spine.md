# 04 — CPU 척추 (real) + 코어별

> 막힘: 01,02,03 · 커버: 스토리 1,6,7,15,24 · 결정표 매핑: #10, #12, #13
> 프로토타입 근거: CPU 카드 line 111–128, 코어 펼침 line 116–126, 로직 line 598–602/623–628
> 그릴 완료(2026-06-21): 신선한 리뷰어 검증 통과(SHIP). 아래 「결정/리스크」 참조.

## 목표

진짜 시스템 데이터로 동작하는 **첫 수직 슬라이스(MVP)**. 무권한·무위험이라 단독 출시 가능. 가짜 CPU provider를 진짜로 교체한다.

## 프레이밍 (그릴 교정)

- `CPUSample{overall, perfLevels}` 와 `PerfLevelUsage{name, usage}` 는 **이미 존재**한다 (`Wattly/Models/MetricSample.swift:17-27`). 이 이슈의 **유일한 신규 필드는 per-core `cores`** 하나다.
- 스펙 "`MetricSample`만 경계 통과"는 *그 타입만 actor 경계를 넘는다*는 뜻이지 *스키마 동결*이 아니다. enum이 감싸는 struct에 필드를 더해도 위반이 아니다.

## 범위 (In)

1. **CPUProvider (무권한)**
   - `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`로 코어별 tick 스냅샷 → 직전 스냅샷과 차분 → 전체/코어별 사용률.
   - 호출 후 `vm_deallocate(mach_task_self_, addr, numCpuInfo * MemoryLayout<integer_t>.stride)`로 배열 해제(누수 금지). 원시 포인터는 provider 내부에서 즉시 소비, `MetricSample`만 경계 통과.
   - 첫 read(직전 스냅샷 없음)는 `.pending` 반환 → 카드는 2번째 폴까지 `.loading`(약 2s).
2. **토폴로지 (하드코딩 금지)**
   - `sysctlbyname`으로 `hw.nperflevels` / `hw.perflevelN.name` / `hw.perflevelN.physicalcpu` 런타임 조회(개발기 M5 = 고성능 4 + 효율 6). provider 첫 read에서 **1회 캐싱**.
   - 성능레벨별 평균 = 카드 sub "P xx% · E yy%"(**런타임 제공 명칭 사용** — #B 확정: 프로토타입의 "Super/S"가 아니라 `sysctl`이 돌려주는 `Performance`/`Efficiency`의 첫 글자 `P`/`E`).
3. **표시**
   - 카드 값 = 전체 CPU % (정수 반올림). 단위 %.
   - 펼침: 코어 막대 행 — 라벨(런타임명 첫글자 + 코어 인덱스, 예 `P0`,`E3`; 10.5px/600 width 22) · 막대(height 6, radius 3, bg `c.sparkFill`, fill width%+색: perflevel **인덱스 0 = accent**, 그 외 = faint) · pct(10.5px/600 width 26 우정렬). perflevel별 그룹 + 헤더(`name` + 평균%). 펼침 상태 `@AppStorage` 보존(#12 참조).
4. **순수 함수** — `cpuUsage(prev:curr:topology:)`: tick 차분, idle 비율, 코어별 합산, 0-델타(동일 스냅샷) 안전 처리. Mach 호출 0개 → 합성 입력으로 단위 테스트 가능. (스펙 원안 `(prev:curr:)`에 `topology:` 추가 — 토폴로지를 인자로 주입해 결정론 유지.)
   - busy = user+system+nice, total = busy+idle (`CPU_STATE_*`).
   - overall = 전체 코어 **tick 가중** Σbusy/Σtotal. 레벨 평균 = 레벨 내 동일 가중.
   - 0-델타(total==0) → 0% 반환(NaN/크래시 금지).
5. **메뉴바 연동** — 별도 작업 없음. `MenuBarLabel`이 이미 `cardState(.cpu).overall`을 읽으므로([14](14-menubar-text-metrics.md)) 실 provider가 붙는 즉시 자동 반영.
6. **접근성** — 카드/값/펼침 행 VoiceOver 라벨([15](15-accessibility.md)). 풀 패스는 issue 15.

## 범위 (Out)

- 코어별 sparkline(전체만). GPU 사용률(Out of Scope).

## 구현 스텝

1. **시드 확장** — `PerfLevelUsage`에 `cores: [Double]`(기본 `[]`) 추가 → perflevel별 그룹핑 내재, 기존 2-인자 호출부 컴파일 유지. **FakeProvider `.cpu`도** per-core 배열 방출 + 레벨명 `"P"`/`"E"`로 갱신(실 HW 정합, 서브텍스트가 순서 기반이라 fake/real 둘 다 정상 렌더).
2. **순수 `cpuUsage(prev:curr:topology:)`** 신규 파일 — tick 차분, busy/idle, per-core/per-level/overall, 0-델타→0, 코어 인덱스→perflevel 파티션 매핑(+ #A fallback).
3. **`CPUProvider` actor** — 토폴로지 캐싱, prev `[CoreTicks]` 보유, `host_processor_info` → 즉시 `vm_deallocate`, 첫 read `.pending`. **배선**: 호출부에서 `.cpu`=real + 나머지 fake로 provider 리스트 구성(`Wattly/App/WattlyApp.swift:15` / `FakeProviders.all`), real provider는 `-WattlyScenario` 무시(cold/fail은 CPU에 적용 안 됨). **파일 추가 후 xcodegen 재생성**(classic source lists).
4. **뷰** — `expandRegion` 자리(`MetricCardView.swift:74`) → per-core 막대 행, perflevel 그룹 헤더(`perfLevels[i].name` + 평균%). 서브텍스트를 `name=="S"` 리터럴 → **순서 기반**(`perfLevels[0]/[1]`)으로 교체하되 표시 텍스트는 `perfLevels[i].name` 사용, **`perfLevels.count >= 2` 가드**(단일 클러스터/Intel out-of-range 방지). 펼침 `@AppStorage` 이전.
5. **접근성** — overall 값 + 각 코어 행 `accessibilityLabel`(예 "P0, 71 percent").

## 결정 / 리스크

- **#B 확정 = 런타임명(`P`/`E`).** 스펙 §2("Super/Performance/Efficiency 가정 금지")를 따른다. 프로토타입의 `S`/Super 비주얼과는 의도적으로 다름.
- **#A (미검증 가정, 온디바이스 확인 필요)** — 코어 인덱스→perflevel 매핑이 연속(누적 `physicalcpu`가 `host_processor_info` 배열을 깔끔히 분할)이라고 가정. **비문서 계약**이라 M5 개발기에서 검증 필요(단일 P코어 부하 시 P그룹만 점등). **Fallback**: 코어 수 ≠ Σphysicalcpu 거나 분할 불가 시, 그룹 없이 평면 `C0..Cn`으로 표시(오라벨 금지).
- **#12 (스코프 주의)** — 펼침 상태는 현재 `PopoverContentView`의 `@State Set<CardKind>`로 **CPU+mem 공유**(`PopoverContentView.swift:14,84`). 이를 `@AppStorage`(`StorageKey.expandedCards`, `CardOrder`식 CSV)로 영속화 → issue 04 최소 스펙(“CPU 자체 펼침 영속”)을 **초과**하며 issue 05 메모리 카드와 결합. 의도적 결정.

## 수용 기준

- 부하를 주면 % 와 코어 막대가 실시간 반영. 펼침 시 perflevel 그룹이 런타임 토폴로지대로 표시(M5: P0–3, E0–5).
- **온디바이스(#A 검증)**: 단일 스레드 부하가 올바른 perflevel 그룹을 점등.
- 서브텍스트가 실 `sysctl` 명칭으로 live `P xx% · E yy%` 표시(공백 아님).
- 동일 스냅샷 2회 호출(0-델타)에서 NaN/크래시 없음.
- `host_processor_info` 호출마다 `vm_deallocate`로 해제 → **수동 `leaks`/Instruments soak(~1h) 누수 없음 확인**(단위 테스트 불가).
- 합성 입력 → 결정론적 출력 단위 테스트 통과: **Swift Testing**(`@Test`/`#expect`)로 `CPUUsageTests` 신규(0-델타→0, busy/idle 수식, 레벨 평균, 파티션 매핑). 기존 11개 `@Test` green 유지(기본값 `cores` 덕)([18](18-testing.md)).

## 메모

- 이 이슈 완료 = "진짜로 쓸 수 있는" 최소 제품. 전력/온도의 비공개 API 리스크는 이 위에서 분리 검증.
