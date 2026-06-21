# 05 — 메모리 + 프로세스 Top-3

> 막힘: 01,02,03 · 커버: 스토리 8 · 결정표 매핑: #12, #21(추천 yes·사용자 확인) · 로컬결정 M1–M21
> 프로토타입 근거: 메모리 카드 line 130–147, 펼침 Top-3 line 609–615 (`Wattly Interactive.dc.html`)
> 상태: grill-yourself → grill-review(deep, Sonnet) **SHIP (Rev 2)**. 표시(값·sub·펼침 affordance)는 02/04에서 이미 구현됨 — 본 이슈의 신규 작업은 **실 `MemoryProvider` + `libproc` 펼침**이다.

## 목표

메모리 사용량·총량을 무권한으로 표시하고(렌더는 기존 존재), 카드를 펼치면 메모리 점유 상위 3개 프로세스를 `libproc`로 보여준다. **펼침이 화면에 있을 때만** 프로세스를 열거한다.

## 범위 (In)

1. **Seam 확장** — [`MetricSample.swift`](../Wattly/Models/MetricSample.swift)
   - `struct ProcessUsage: Sendable, Equatable, Identifiable { var pid: Int32; var name: String; var footprintBytes: UInt64; var iconPath: String?; var id: Int32 { pid } }`. (`iconPath`=책임 앱 경로 — NSImage는 non-Sendable이라 경로 String만 seam을 넘는다.)
   - `MemorySample`에 `processes: [ProcessUsage] = []` 추가.
   - **`Equatable` 필수(M17)**: `MetricSample`→`MetricState`/`ProviderReading` 동치 합성과 테스트 비교가 의존 — 빠지면 체인 전체 컴파일 실패.

2. **순수 함수** — `Wattly/Core/MemoryUsage.swift` ([`CPUUsage.swift`](../Wattly/Core/CPUUsage.swift) 미러)
   - `usedBytes(active:wire:compressor:pageSize:) -> UInt64` = `(active + wire + compressor) × pageSize` ← 단위 테스트 대상.
   - `memorySample(...)` — GB는 **GiB(÷1024³)**, used/total/wired/compressed/process 공통(16 GiB → "16", M5).
   - `topProcesses(_:limit:3)` footprint 내림차순.
   - `barFraction(footprint:maxBytes:)` — **0-나눗셈 가드** `maxBytes > 0 ? … : 0` ([`CPUUsage.swift:43`](../Wattly/Core/CPUUsage.swift) `pct` 패턴, M19).
   - `appBundlePath(forExecutable:)` — 실행 경로 → **최외곽 `.app`**(책임 앱) 해석. 비공개 responsible-pid API 없이 Chrome 헬퍼→Chrome.app, lldb-rpc-server→Xcode.app. `.app` 없으면 실행 경로 그대로(일반 아이콘).

3. **`MemoryProvider`** (actor, [`CPUProvider`](../Wattly/Providers/CPUProvider.swift) 패턴) — 무권한
   - 매 poll: `host_statistics64(HOST_VM_INFO64)`(caller 구조체, **free 불필요**) + 자체 `sysctlUInt64("hw.memsize")` → totals(싸다). *`CPUProvider.sysctlInt`은 `private static`라 직접 호출 불가 — 자체 헬퍼 복사 또는 Core로 추출(M6).*
   - 페이지 크기: 런타임 `vm_kernel_page_size`(또는 `host_page_size`) — 하드코딩 금지(M4).
   - `enumerating`일 때만: `proc_listpids(PROC_ALL_PIDS)` **2-pass**(size→`[pid_t]`→fill, Swift 배열이라 **free 불필요**) → pid별 `proc_pid_rusage(RUSAGE_INFO_V0)` 실패 skip(M10) → `ri_phys_footprint` + `proc_name`(→`proc_pidpath` basename→`"PID n"`, M9) → `topProcesses(limit: 3)`.
   - **`vm_deallocate` 대상 없음(M20)**: 메모리 경로는 전부 caller 할당. (`vm_deallocate`는 `CPUProvider`의 `host_processor_info` 전용.) `import Foundation`(Darwin 재노출).
   - ⚠️ `proc_pid_rusage` 리바인드 한 줄(`withUnsafeMutablePointer → rusage_info_t?.self`)은 가장 깨지기 쉬움 → **최초 컴파일에서 확인**.

4. **열거 게이팅(M11/M18)** — 자체 전력 보호
   - `protocol ProcessEnumerating: MetricProvider { func setEnumerating(_ on: Bool) async }`; `MemoryProvider` 준수.
   - [`SystemMonitor`](../Wattly/Core/SystemMonitor.swift)가 init에서 `providers.compactMap { $0 as? ProcessEnumerating }.first` 보관; `setMemoryProcessEnumeration(_:)`가 전달 + true 시 즉시 `pollOnce()`(≤2 s 빈 목록 방지, M15).
   - [`PopoverContentView`](../Wattly/Views/PopoverContentView.swift)(monitor 소유)에 `.task(id: memExpanded && shown)`/`.onDisappear` 부착. 팝오버 닫힘 = 콘텐츠 언마운트(**issue 03 §In-5** render-stop, [`SparklineView.swift`](../Wattly/Views/SparklineView.swift); [09](09-adaptive-polling.md) 적응형 폴링이 소비) → 자동 off.
   - 기본 poll(닫힘/접힘)은 totals만 — `proc_listpids` 스윕 비용 0.

5. **펼침 뷰** — [`MetricCardView`](../Wattly/Views/MetricCardView.swift)의 stub(≈line 79) 교체
   - `memExpand(_ s: MemorySample)`: `ForEach(s.processes)` → **신규 `processRow`**.
   - 행: **15px 앱 아이콘**(`NSWorkspace.icon(forFile: iconPath)`, AppKit·메인; nil이면 faint 플레이스홀더) · 이름(11px/600, **width 74 ellipsis**) · 막대(`GeometryReader`, height 6 / radius 3, 폭 = `barFraction`(1위 대비 비례), 색 = 스파크라인 stroke) · GB(10.5px/600, **width 46 우정렬**, `"X.X GB"`).
   - `MemoryProvider.topMemoryProcesses`는 **footprint만 먼저 수집→Top-3 추린 뒤** 이름·경로·아이콘을 해석(매 폴링 수백 회 `proc_name` 호출 방지).
   - `coreRow`(label 22 / value 26 / %-의미)는 비호환 → **구조만 차용**, 직접 재사용 불가(M13).
   - 빈 결과 → faint "프로세스를 읽을 수 없음"(`t.faint` 관용구, M16).

6. **배선 + fake 패리티(M14/M21)**
   - [`FakeProviders.all`](../Wattly/Providers/FakeProvider.swift): `.memory` → `MemoryProvider()`(`.cpu`와 동일, `-WattlyScenario` 무시).
   - `FakeProvider.makeSample` `.memory`에 합성 프로세스 2–3개 유지(ScriptedProvider/테스트 경로용).
   - **회귀(수용)**: 실 provider는 scenario를 무시하므로 `-WattlyScenario desktop`은 가짜 64 GB가 아닌 **실제 RAM**을 표시(데스크톱 시나리오 목적은 배터리 부재). 문서화로 수용.

7. **xcodegen 재생성 → 빌드 → 테스트**(파일 추가 후 필수).

## 범위 (Out)

- SSD/메모리 온도. Activity Monitor급 프로세스 패널(상위 3개까지만). 별도 macOS memory-pressure API(M7). 앱 단위 coalescing(A2 미전환 시).

## 수용 기준

- **05 단독**: 사용 GB/총량 실시간 · 펼침 시 실제 footprint 상위 3개가 폭 비례로 표시 · 닫으면/접으면 열거 중단 · 막대·값은 중립색(`t.spark`) · `usedBytes` 합성 입력 단위 테스트 통과(`WattlyTests/MemoryUsageTests.swift`, [18](18-testing.md)) · 기존+신규 테스트 그린.
- **05+10 통합 후(별도 게이트)**: used% 임곗값 색상 코딩이 값·스파크라인·프로세스 막대에 적용([10](10-thresholds-color-coding.md)). *05 시점엔 임곗값색 미구현이라 05 단독 사인오프 게이트에서 제외(빌드순서 05 < 10).*

## 리스크

- **무권한 한계**: 타 사용자/시스템 프로세스(WindowServer·kernel_task 등)는 불투명 → Top-3에서 빠질 수 있음(접근 가능한 것만, 조용히 제외).
- **per-process**: Chrome 등 멀티프로세스 앱은 헬퍼가 개별 행으로 보임(A2).
- **desktop 시나리오 메모리 총량 회귀**(M21, 수용).

## 결정 로그 (grill-yourself + grill-review SHIP)

**Confident M1–M21** — M1 #21=yes(libproc/phys_footprint) · M2 seam=`MemorySample.processes` · M3 used=(active+wire+compressor)×page · M4 런타임 page size · M5 GiB · M6 자체 sysctl 헬퍼 · M7 압력=used% 임곗값색 · M8 `RUSAGE_INFO_V0`로 충분(per-process) · M9 `proc_name`→pidpath→PID · M10 실패 skip · M11 펼침-온스크린 게이팅 · M12 막대=스파크라인 stroke · M13 신규 `processRow` · M14 실 provider 교체 · M15 토글·지속성 기존+즉시 refresh 신규 · M16 빈 상태 faint · M17 `ProcessUsage: Equatable` · M18 enumerator 캐스트+`.task` 부착 위치 · M19 0-가드 · M20 free 대상 없음 · M21 desktop 총량 회귀 수용.

**사용자 결정(미결)** — **#21(=A1)**: 프로세스 Top-3 출시 여부(PRD Out-of-Scope). `#21=no`면 펼침 제거·메모리 카드 비펼침(클릭 비활성). · **A2**: per-process vs 앱 합산명 — `M8=coalesce`(비공개 responsible-pid API 필요)로 전환 가능.

**grill-review 정정 반영** — M8(V2→V0), M11(render-stop 출처 = issue 03 §In-5, issue 16 아님), M13(coreRow 재사용 불가→신규), M20("Mach 포인터 해제" 오기 제거), 수용기준 분리(05/05+10), 게이팅 캐스트·`.task` 위치 명시.
