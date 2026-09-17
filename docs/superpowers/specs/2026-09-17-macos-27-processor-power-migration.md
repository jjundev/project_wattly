# macOS 27 프로세서 전력 이관(Energy Model → PMP 히스토그램) 설계

- 작성일: 2026-09-17
- 실기: MacBook Pro M5 (`Mac17,2`), macOS 27.0 (26A428), 시스템 펌웨어 `20457.1.29`, Xcode 27.0
- 배경 메모리: `macos-27-sensor-audit-facts.md`, `plan-06-ioreport-findings.md`
- 범위: macOS 27 감사에서 드러난 3축 중 **2축(프로세서 전력 카드)**만. 1축(배터리 사실)은 PR #121로 완료, 3축(충전 제한)은 루트 프로브 결과가 선행 조건이라 별도 설계.

## 1. 문제

macOS 27에서 IOReport `Energy Model` 그룹의 mJ 누적 채널(`CPU Energy`, `ECPU*`/`PCPU*`, `ANE`, `DRAM`…)이 **3~5분에 한 번만 갱신**된다(150 s 관찰에서 1회, 4스레드 부하 중에도 델타 0). 채널 이름·단위·개수(169)는 26과 동일해서 `hasEngineChannelSetChanged`/미지 단위 방어에 걸리지 않고, 그 결과:

| 증상 | 원인 |
|---|---|
| CPU 서브값이 거의 항상 0.0 W | `isCPUCoreEnergyChannel` 코어 채널 델타 0 |
| 3~5분마다 헤드라인이 수백 W로 튀거나(사실상 200 W 상한에 걸려 `.pending`) 1초 스파이크 | 갱신 폴에 수 분치 에너지가 한 번에 들어옴 |
| ANE 도 같은 스파이크 | 같은 그룹 |

`GPU Energy`(nJ)만 여전히 매초 갱신된다. `proc_pid_rusage` 기반 앱별 Top-N(`ri_energy_nj`)은 영향 없다.

## 2. 실측된 대체 소스 (IOReport `PMP` 그룹 / `Energy` 서브그룹, 2026-09-17 이 세션 재확인)

`IOReportCopyChannelsInGroup("PMP", "Energy")` → state 포맷(`IOReportChannelGetFormat == 2`) 채널 6개, 각 32빈, unit 라벨 `"events"`:

| 채널 | 빈 폭 | 의미 |
|---|---|---|
| `EACC0` | 0.250 W | E 클러스터 전력 히스토그램(클러스터 공유분 포함) |
| `EACC0 SRAM` | 0.062 W | E 클러스터 SRAM |
| `PACC0` | 1 W | P 클러스터 전력 히스토그램 |
| `PACC0 SRAM` | 0.125 W | P 클러스터 SRAM |
| `AGX` | 1 W | GPU (저전력에서 +35% 편향 — 사용 안 함) |
| `AGX SRAM` | 0.125 W | — |

- 빈 이름은 **균등 폭의 상한**(`" 0.250W"`, `" 0.500W"`, … / `"   1W"`, `"   2W"`, …). 첫 빈 이름을 파싱하면 폭이 나온다. 빈 i는 `(i·w, (i+1)·w]`, 중앙값 `(i+0.5)·w`. 마지막 빈(32번째)은 개방 구간.
- 누적 residency는 샘플 수(≈4.4k/s; 2초 델타 합 8913). 매초 갱신, 부하 즉시 반응.
- 9분 교차검증(EM 갱신 간격 329 s·194 s): 히스토그램 적분 J vs EM 클러스터 J — E 376/373·738/737, P 923/835·2349/2387(±10%). `PACC0`(SRAM 제외) ≈ P 코어 합 +3.5%, `EACC0`는 E 코어 합의 2.6배(클러스터 공유분 포함).
- 이 세션 유휴(프로브 자체 부하) 중앙값 가중 평균: `PACC0` ≈ 1.13 W, `EACC0` ≈ 0.40 W.
- 필요한 심볼 `IOReportStateGetCount`/`IOReportStateGetResidency`/`IOReportStateGetNameForIndex` 존재(앞 둘은 `RealCPUClock`이 이미 쓴다).
- macOS 26 이하에 `PMP`/`Energy`가 존재하는지는 **미확인**(26 실기 없음). 설계는 있어도 없어도 동작해야 한다.

## 3. 결정

1. **소스 선택은 런타임 정체 감지, 스티키.** `Energy Model` 코어 채널(`isCPUCoreEnergyChannel` 집합)의 델타 합이 **연속 2회의 유지된 폴**(`.pending`으로 버린 폴은 세지 않음)에서 0이면 EM을 정체로 판정하고 프로세스 수명 동안 되돌리지 않는다. 판정 중(0이 1회)인 폴은 `.pending`. 근거: 살아 있는 EM은 유휴에서도 E 코어가 매초 수십~수백 mJ 증가하므로 연속 0은 나오지 않고, OS 버전 가정을 두지 않아 26.x/27.x 점 릴리스에 흔들리지 않는다. macOS 26 이하는 오늘과 바이트 단위로 같은 값을 낸다. 정확히는 `cpuW`/`gpuW`/`npuW` 세 엔진 값이 바이트 단위로 동일하고, `totalW`만 mJ 합을 나눈 값 대신 이 세 W 값의 합으로 계산이 바뀌어 이전 출력과 1 ULP 미만 차이가 날 수 있다(사용자에게 보이지 않음).
2. **엔진별 소스(정체 시):** CPU = PMP 클러스터 히스토그램 `^[EP]ACC\d+$` 합(**SRAM 제외**, 다이가 여럿이면 `EACC1`/`PACC1`… 도 합산); GPU = EM `GPU Energy`(nJ, 기존 경로 그대로); ANE = EM `ANE`의 **장주기 평균**(아래 4). SRAM 제외 근거: 26 "코어별 합" 정의에 가장 가깝고 교차검증이 이 조합. 27 유휴 CPU 표시는 26보다 ~0.25 W 높아질 수 있다(`EACC0` 공유분) — 수용.
3. **히스토그램 → W:** 균등 빈, 폭은 구독 init 때 첫 빈 이름에서 1회 파싱, 폴마다 residency만 읽음. 평균 W = Σ Δᵢ·(i+0.5)·w / Σ Δᵢ. 개수 불일치·어떤 Δ<0(리셋)·ΣΔ=0 → nil(그 폴 `.pending` + 재기준). 32번째 빈은 개방 구간이라 중앙값이 과소 추정된다 — 실측한 `Mac17,2`는 도달하지 않는다. 클러스터 전력이 더 높은 상위 파트(P 클러스터가 `32·w`를 넘을 수 있는 M-Max/Ultra급)에서는 **미확인**이며, 그런 기기에서 클러스터가 포화되면 클러스터당 ≈`31.5·w`에서 조용히 과소 추정될 것이다 — 감지는 후속 과제(§4).
4. **ANE 장주기 평균:** 정체 모드에서 EM 코어 채널 델타 > 0 인 폴 = EM 갱신 폴. 직전 갱신 인스턴트가 있으면 `ANE W = ΔJ_ANE / (지금 − 직전 갱신)`을 계산해 다음 갱신까지 유지 표시. 첫 갱신 전은 0. 유휴 ANE는 0 J라 0이 유지된다(스파이크 없음). 갱신 폴이 dt·리셋·미지 단위 방어(감지기가 돌기 전 단계)에 걸려 `.pending`으로 버려지면 그 폴의 줄(J)이 유실될 뿐 아니라 `lastRefresh`도 전진하지 않는다 — 그 결과 **다음** 갱신은 한 주기치 줄을 약 두 주기치 시간으로 나누게 되어, 그다음 3~5분 구간의 ANE가 대략 절반으로 표시된다. (갱신 폴이 단순히 히스토그램 미스에 걸리는 경우는 영향 없음 — ANE율은 히스토그램 방어보다 먼저 관측된다.) 여전히 드물고 수용.
5. **정체인데 PMP 클러스터 채널이 없으면** 기존 주황 `.channelUnreadable` 카드(문구 `PowerProvider.unreadableMessage` 그대로). 0 W를 사실처럼 보여 주지 않는다.
6. **순수/IO 분리 유지:** 히스토그램 수식·정체 상태기계·ANE 장주기는 `Wattly/Core/PowerHistogram.swift`(순수), IOReport I/O는 `Wattly/Providers/PowerHistogramSubscription.swift`(`RealCPUClock` 패턴). `powerSample`은 `PowerOverrides{cpuW, npuW}`를 받아 `totalW = cpuW + gpuW + npuW` 불변식을 유지한다.
7. **EM·PMP 샘플은 같은 `read()` 안에서 연속으로 뜨고 중점 인스턴트 하나를 공유**한다. 기존 이상 판정(dt, EM 리셋, 채널 집합 변화, 미지 단위, 200 W 상한)은 그대로. 정체 모드의 EM 갱신 폴은 CPU가 오버라이드로 가려져 상한에 걸리지 않는다.
8. **`PowerSample` 필드·카드 UI·스무딩·앱별 Top-N·`FakeProvider`·`.channelUnreadable` 문구는 변경하지 않는다.**

## 4. 비범위

- GPU를 `AGX` 히스토그램으로 바꾸기(`GPU Energy` nJ가 살아 있고 AGX는 저전력 편향).
- ANE 대체 채널 탐색(없음).
- 32 W 초과 클러스터 포화 보정(상위 파트 미확인, 후속 과제).
- 스무딩 τ·UI 문구·설정 항목 변경.
- 3축 충전 제한, 1축 잔여 확인 2건.

## 5. 검증 기준

- 순수 함수 테스트: 빈 폭 파싱, 히스토그램 평균(집중·분산·ΣΔ=0·Δ<0·개수 불일치), 클러스터 채널 이름 판정과 다중 채널 합, 정체 상태기계(live / deciding / stale 스티키), ANE 장주기(첫 갱신 0 → 두 번째 갱신에서 ΔJ/Δt → 유지), `powerSample` 오버라이드 시 totalW 재계산과 오버라이드 없을 때 기존 결과 동일.
- 기존 테스트 전부 green.
- 실기(macOS 27): `Wattly -WattlyPowerProbe`가 10폴 출력. 기대: 2폴째 `source=deciding`, 3폴째부터 `source=pmp`, 유휴 CPU ≈ 1~2 W, `yes` 4개 부하에서 다음 폴에 즉시 상승, ANE 0.0. 팝오버 프로세서 전력 카드가 부하에 매초 반응하고 스파이크가 없다.
- 선택(사용자 sudo): `sudo powermetrics --samplers cpu_power -i 1000` 부하 중 CPU 값과 ±10% 정합.

## 6. 실기 결과 (2026-09-17, macOS 27.0 26A428, Mac17,2)

- `-WattlyPowerProbe` 유휴: sample 0 `source=em`(baseline, `pending` — sample 0에서는 감지기가 아직 호출되지 않으므로 이 `em`은 판정이 아니라 DEBUG 필드의 초깃값일 뿐이고, 이 폴 자체는 첫 샘플이라 재기준만 하는 baseline `.pending`이다) → sample 1 `source=deciding`(`pending`) → sample 2부터 `source=pmp`, 이후 `pending` 재발 없음. 관측값:
  ```
  [power-probe] sample 1: source=deciding histCPU=1.62 W · pending
  [power-probe] sample 2: source=pmp histCPU=2.51 W · total 2.57 W · cpu 2.51 · gpu 0.06 · ane 0.00
  [power-probe] sample 3: source=pmp histCPU=7.12 W · total 7.12 W · cpu 7.12 · gpu 0.00 · ane 0.00
  ```
  이 유휴 런은 기계가 실제로 놀고 있지 않았다(같은 머신에서 이 에이전트 세션과 직전 xcodebuild가 동시에 돌고 있었음) — 그래서 CPU가 조용한 기계의 1~2 W가 아니라 **0.8~7.5 W**(sample 6 0.82 W ~ sample 7 7.46 W) 범위에서 흔들렸다. `total ≈ cpu + gpu`는 매 샘플 성립, `ane`는 0.00으로 유지.
- `yes` ×4 부하: `deciding` 폴부터 이미 16.9 W로 튀고, `pmp` 전환 후 다음 샘플들에서 **약 17 W대(16.77~17.14 W)로 안정**. 관측값:
  ```
  [power-probe] sample 1: source=deciding histCPU=16.91 W · pending
  [power-probe] sample 2: source=pmp histCPU=16.88 W · total 16.92 W · cpu 16.88 · gpu 0.04 · ane 0.00
  [power-probe] sample 3: source=pmp histCPU=16.98 W · total 17.10 W · cpu 16.98 · gpu 0.12 · ane 0.00
  ```
  유휴 구간(최대 ~7.5 W)과 부하 구간(~17 W)이 뚜렷이 분리되어, 히스토그램 기반 CPU 값이 실제 부하에 반응하는 것을 확인. `kill` 후 `ps aux | grep "yes$"`로 잔류 프로세스 없음 확인.
- 소스 전환은 유휴·부하 두 런 모두 `em`(baseline) → `deciding` → `pmp`로 동일하게 관측되었고, sample 1(`deciding`) 이후 `pending`이 다시 나타나지 않았다.
- ANE는 유휴·부하 전 구간에서 0.00 W로 유지(장주기 평균 갱신이 10샘플 프로브 창 안에서 발생하지 않았기 때문 — 아래 참고).
- 팝오버 눈 확인(Step 1): **미실행 — 사용자 확인 필요.** 확인 항목: 헤드라인·CPU 서브값이 매초 갱신되는지, `yes` 4개 부하에 다음 폴부터 반응하는지, 스파이크가 없는지, ANE가 0.0 W로 유지되는지.
- powermetrics 정합(Step 2): **미실행 — 사용자 확인 필요.** 확인 방법: 부하 중 `sudo powermetrics --samplers cpu_power -i 1000 -n 10`의 `CPU Power`(mW)와 프로브의 `cpu`(W)를 비교해 ±10% 이내인지.
- 프로브가 실기로 검증하지 못한 부분: 10초짜리 프로브 창 안에서는 Energy Model 갱신(3~5분 주기)이 한 번도 일어나지 않았다. 따라서 ANE 장주기 평균(`StaleANERate`, §3-4)과 그 갱신-폴 경로는 유닛 테스트로만 검증되었고 실기에서는 검증되지 않았다. 정체 상태에서 잠들었다 깨어나는 경로(sleep/wake)도 마찬가지로 실기 미검증.
- 한계 확인: 32 W 상한 빈 미도달(유휴·부하 모두 20 W 미만).
- 리뷰가 잡은 보강: CPU 에너지 채널 자체가 없는 스냅샷은 정체로 판정하지 않는다(`hasCPUEnergyChannel`) — 그런 토폴로지에서는 히스토그램 구독 없이도 기존 Energy-Model-only 경로가 그대로 동작한다. 이 머신은 CPU 에너지 채널이 있어 이 분기는 실기에서 타지 않았고, 회귀 커버리지는 새 유닛 테스트(`cpuEnergyChannelPresence`)가 담당한다.
- 최종 리뷰가 남긴 후속 과제: (a) IOReport 심볼 로더가 4곳(`PowerProvider`, `PowerHistogramSubscription`, `CPUClock`, `GPUClock`)에 중복돼 있음 — 공유 로더로 통합; (b) 정체 상태에서 히스토그램 미스가 반복되는 동안 무한정 `.pending`만 내는 대신 주황 카드로 넘어가는 상한 도입; (c) 상위 파트를 위한 마지막 빈 포화 감지(§3-3/§4).
