# macOS 27 프로세서 전력 이관(Energy Model → PMP 히스토그램) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macOS 27에서 3~5분에 한 번만 갱신되는 IOReport `Energy Model` CPU 채널 때문에 0 W와 스파이크만 보이는 프로세서 전력 카드를, 매초 갱신되는 `PMP`/`Energy` 클러스터 전력 히스토그램(`EACC0`/`PACC0`)으로 CPU를 대체해 복구한다.

**Architecture:** `PowerProvider`는 기존 `Energy Model` 구독에 더해 `PMP`/`Energy` state 히스토그램 구독을 하나 더 갖는다. 런타임 정체 감지(EM 코어 채널 델타 0이 연속 2폴 → 스티키)로 정체가 확정되면 CPU는 히스토그램 중앙값 가중 평균, ANE는 EM 갱신 간격 평균으로 오버라이드하고, GPU는 살아 있는 `GPU Energy`(nJ)를 그대로 쓴다. 수식·상태기계는 순수 `Core/PowerHistogram.swift`, I/O는 `Providers/PowerHistogramSubscription.swift`(`RealCPUClock` 패턴). `PowerSample`·UI·스무딩은 손대지 않는다. macOS 26 이하는 정체가 감지되지 않으므로 값이 바이트 단위로 동일하다.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI 메뉴바 앱, IOReport 사설 API(`dlopen("libIOReport.dylib")` + `IOReportCopyChannelsInGroup`/`IOReportCreateSubscription`/`IOReportCreateSamples`/`IOReportStateGetCount`/`IOReportStateGetResidency`/`IOReportStateGetNameForIndex`), XcodeGen(`project.yml`이 원본), Swift Testing(`@Test`/`#expect`).

**Spec:** `docs/superpowers/specs/2026-09-17-macos-27-processor-power-migration.md`

## Global Constraints

- 소스 선택은 **런타임 정체 감지, 스티키**: `cpuCoreEnergyDeltaJ <= 0`인 유지된 폴이 연속 `2`회면 정체. 되돌리지 않는다(스펙 §3-1).
- 정체 시 CPU = PMP `^[EP]ACC\d+$` 채널 합, **SRAM 제외**. GPU = EM `GPU Energy`(기존). ANE = EM 갱신 간격 평균(스펙 §3-2·§3-4).
- 히스토그램 평균 W = Σ Δᵢ·(i+0.5)·w / Σ Δᵢ. 개수 불일치·Δ<0·ΣΔ=0 → nil(스펙 §3-3).
- 정체인데 PMP 클러스터 채널이 없으면 `.unavailable(.channelUnreadable(PowerProvider.unreadableMessage))`. 문구 변경 금지(스펙 §3-5).
- `PowerSample`(`Wattly/Models/MetricSample.swift:93-105`) 필드, `CardPresentation`, `PowerSmoothing`, `FakeProvider`, 앱별 Top-N 경로는 변경 금지(스펙 §3-8).
- `totalW == cpuW + gpuW + npuW` 불변식 유지(`PowerEnergyTests.wattsFromEnergyDelta`가 검사).
- Swift 6 strict concurrency: 새 타입은 `Sendable`; CF 핸들은 `@unchecked Sendable` 래퍼 안에만, 액터 격리 안에서만 접근.
- 새 파일은 `Wattly/Core`·`Wattly/Providers`·`WattlyTests` 폴더 소스라 `project.yml` 편집은 불필요하지만 **반드시 `~/bin/xcodegen generate`로 `Wattly.xcodeproj`를 재생성**한다(pbxproj 직접 편집 금지). 데몬 타깃에는 넣지 않는다.
- 커밋 메시지는 Conventional Commits(`feat(power): …`, `test(power): …`) + 마지막 줄 `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- 테스트 실행 후 `git status`에 `docs/assets/**/*.png`가 수정된 것으로 뜨면(스크린샷 생성 테스트의 부산물) **커밋하지 말고** `git checkout -- docs/assets`로 되돌린다.
- 전체 테스트: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | grep -E "Executed|error:|failed|\*\* TEST"` → 마지막 줄 `** TEST SUCCEEDED **`. 워크트리에서 `actool` 권한 오류가 나면 `-derivedDataPath <scratchpad>/dd`를 덧붙인다.
- 단일 스위트: 위 명령에 `-only-testing:WattlyTests/<스위트 struct 이름>` 추가.
- 빌드만: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|\*\* BUILD"`.

---

## 파일 구조

| 파일 | 역할 | 작업 |
|---|---|---|
| `Wattly/Core/PowerHistogram.swift` (신규, 순수) | 빈 폭 파싱 · 히스토그램→W · 클러스터 채널 판정·합 · `EnergyModelStaleness` · `StaleANERate` | Task 1, 2 |
| `WattlyTests/PowerHistogramTests.swift` (신규) | 위 순수 함수 테스트 | Task 1, 2 |
| `Wattly/Core/PowerEnergy.swift` | `cpuCoreEnergyDeltaJ`/`aneEnergyDeltaJ` 헬퍼, `PowerOverrides`, `powerSample(…overrides:)` | Task 3 |
| `WattlyTests/PowerEnergyTests.swift` | 오버라이드 테스트 추가 | Task 3 |
| `Wattly/Providers/PowerHistogramSubscription.swift` (신규) | `IOReportPMPEnergySubscription` — PMP/Energy 구독, 빈 폭 1회 파싱, residency 샘플 | Task 4 |
| `Wattly/Providers/PowerProvider.swift` | 히스토그램 구독·정체 판정·오버라이드 배선, DEBUG `PowerProbe` | Task 5 |
| `Wattly/App/WattlyApp.swift:18` | `PowerProbe.runIfRequested()` 훅 | Task 5 |
| `Wattly/Models/MetricSample.swift:97` | `npuW` 주석 갱신 | Task 5 |
| `docs/superpowers/specs/2026-09-17-macos-27-processor-power-migration.md` §6 | 실기 결과 기록 | Task 6 |

---

### Task 1: 순수 히스토그램 수식 (`PowerHistogram.swift`)

**Files:**
- Create: `Wattly/Core/PowerHistogram.swift`
- Create: `WattlyTests/PowerHistogramTests.swift`

**Interfaces:**
- Consumes: 없음(Foundation만).
- Produces (Task 2·4·5가 그대로 쓴다):
  ```swift
  struct PowerHistogramChannel: Sendable, Equatable { var binWidthW: Double; var bins: [UInt64] }
  func histogramBinWidthW(firstBinName: String) -> Double?
  func histogramMeanWatts(prev: [UInt64], curr: [UInt64], binWidthW: Double) -> Double?
  func isCPUClusterHistogramChannel(_ name: String) -> Bool
  func clusterHistogramCPUWatts(prev: [String: PowerHistogramChannel], curr: [String: PowerHistogramChannel]) -> Double?
  ```

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/PowerHistogramTests.swift`:

```swift
import Testing
@testable import Wattly

/// Pure PMP/Energy histogram math (macOS 27 processor-power migration). The IOReport I/O
/// in `IOReportPMPEnergySubscription` is verified on-device with `-WattlyPowerProbe`, not here.
struct PowerHistogramTests {

    // MARK: histogramBinWidthW — bin names are padded upper bounds like " 0.250W" / "   1W"

    @Test func binWidthParsesPaddedNames() {
        #expect(histogramBinWidthW(firstBinName: " 0.250W") == 0.25)
        #expect(histogramBinWidthW(firstBinName: "   1W") == 1)
        #expect(histogramBinWidthW(firstBinName: " 0.062W") == 0.062)
        #expect(histogramBinWidthW(firstBinName: "0.125W") == 0.125)
    }

    @Test func binWidthRejectsMalformedOrZero() {
        #expect(histogramBinWidthW(firstBinName: "abc") == nil)
        #expect(histogramBinWidthW(firstBinName: "   0W") == nil)
        #expect(histogramBinWidthW(firstBinName: "1") == nil)          // no unit suffix
        #expect(histogramBinWidthW(firstBinName: "") == nil)
        #expect(histogramBinWidthW(firstBinName: "-1W") == nil)
    }

    // MARK: histogramMeanWatts — Σ Δᵢ·(i+0.5)·w / Σ Δᵢ over cumulative residency bins

    @Test func meanOfSingleBinIsThatBinsMidpoint() {
        // all 100 new samples landed in bin 2 of a 1 W-wide histogram → (2+0.5)·1 = 2.5 W
        let prev: [UInt64] = [10, 20, 30, 40]
        let curr: [UInt64] = [10, 20, 130, 40]
        #expect(histogramMeanWatts(prev: prev, curr: curr, binWidthW: 1) == 2.5)
    }

    @Test func meanIsSampleWeightedAcrossBins() {
        // 0.25 W bins: 300 samples at 0.125 W, 100 at 0.375 W → (37.5 + 37.5) / 400 = 0.1875 W
        let prev: [UInt64] = [0, 0, 0]
        let curr: [UInt64] = [300, 100, 0]
        let w = histogramMeanWatts(prev: prev, curr: curr, binWidthW: 0.25)
        #expect(w != nil)
        #expect(abs(w! - 0.1875) < 1e-12)
    }

    @Test func meanIsNilWhenNoSamplesArrived() {
        #expect(histogramMeanWatts(prev: [5, 5], curr: [5, 5], binWidthW: 1) == nil)
    }

    @Test func meanIsNilOnCounterReset() {
        #expect(histogramMeanWatts(prev: [5, 9], curr: [6, 3], binWidthW: 1) == nil)
    }

    @Test func meanIsNilOnShapeMismatchOrEmpty() {
        #expect(histogramMeanWatts(prev: [1, 2], curr: [1, 2, 3], binWidthW: 1) == nil)
        #expect(histogramMeanWatts(prev: [], curr: [], binWidthW: 1) == nil)
        #expect(histogramMeanWatts(prev: [0], curr: [1], binWidthW: 0) == nil)
    }

    // MARK: isCPUClusterHistogramChannel — exactly EACC<n>/PACC<n>; SRAM/AGX never

    @Test func clusterChannelNamesAreExact() {
        #expect(isCPUClusterHistogramChannel("EACC0"))
        #expect(isCPUClusterHistogramChannel("PACC0"))
        #expect(isCPUClusterHistogramChannel("PACC1"))           // multi-die
        #expect(!isCPUClusterHistogramChannel("EACC0 SRAM"))     // SRAM excluded by decision
        #expect(!isCPUClusterHistogramChannel("AGX"))
        #expect(!isCPUClusterHistogramChannel("EACC"))
        #expect(!isCPUClusterHistogramChannel("PACC0 "))
        #expect(!isCPUClusterHistogramChannel(""))
    }

    // MARK: clusterHistogramCPUWatts — sum of matching channels; any nil ⇒ nil

    @Test func clusterWattsSumsEfficiencyAndPerformance() {
        let prev = [
            "EACC0": PowerHistogramChannel(binWidthW: 0.25, bins: [0, 0]),
            "PACC0": PowerHistogramChannel(binWidthW: 1, bins: [0, 0]),
            "EACC0 SRAM": PowerHistogramChannel(binWidthW: 0.062, bins: [0, 0]),
            "AGX": PowerHistogramChannel(binWidthW: 1, bins: [0, 0]),
        ]
        let curr = [
            "EACC0": PowerHistogramChannel(binWidthW: 0.25, bins: [100, 0]),   // 0.125 W
            "PACC0": PowerHistogramChannel(binWidthW: 1, bins: [0, 100]),      // 1.5 W
            "EACC0 SRAM": PowerHistogramChannel(binWidthW: 0.062, bins: [100, 0]),
            "AGX": PowerHistogramChannel(binWidthW: 1, bins: [0, 100]),
        ]
        let w = clusterHistogramCPUWatts(prev: prev, curr: curr)
        #expect(w != nil)
        #expect(abs(w! - 1.625) < 1e-12)                          // SRAM + AGX excluded
    }

    @Test func clusterWattsIsNilWhenAnyClusterIsUnreadable() {
        let prev = [
            "EACC0": PowerHistogramChannel(binWidthW: 0.25, bins: [0, 0]),
            "PACC0": PowerHistogramChannel(binWidthW: 1, bins: [5, 0]),
        ]
        let curr = [
            "EACC0": PowerHistogramChannel(binWidthW: 0.25, bins: [100, 0]),
            "PACC0": PowerHistogramChannel(binWidthW: 1, bins: [1, 0]),        // reset
        ]
        #expect(clusterHistogramCPUWatts(prev: prev, curr: curr) == nil)
        #expect(clusterHistogramCPUWatts(prev: [:], curr: curr) == nil)         // no prev baseline
        #expect(clusterHistogramCPUWatts(prev: prev, curr: [:]) == nil)         // no cluster channel at all
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `~/bin/xcodegen generate && xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/PowerHistogramTests 2>&1 | grep -E "error:|Executed|\*\* TEST"`
Expected: 컴파일 오류 `cannot find 'histogramBinWidthW' in scope` 등(`** TEST FAILED **`).

- [ ] **Step 3: 최소 구현**

`Wattly/Core/PowerHistogram.swift`:

```swift
import Foundation

/// Pure math for the IOReport `PMP` / `Energy` state histograms (macOS 27 processor-power
/// migration). On macOS 27 the `Energy Model` mJ counters refresh only every 3–5 min, so
/// `PowerProvider` derives CPU watts from these per-cluster power histograms instead. No
/// private API here — `IOReportPMPEnergySubscription` does the I/O and hands these functions
/// cumulative residency bins.
///
/// On-device reality (M5 / macOS 27.0, probed 2026-09-17): channels `EACC0`, `PACC0`, `AGX`
/// (+ each ` SRAM`), 32 bins each, ~4.4k samples/s. Bin names are padded UPPER bounds of
/// uniform-width bins (`" 0.250W"`, `" 0.500W"`, … / `"   1W"`, `"   2W"`, …), so bin i spans
/// `(i·w, (i+1)·w]` and its midpoint is `(i+0.5)·w`. The last bin is open-ended (its midpoint
/// under-reads a cluster saturating above `32·w`; Mac17,2 never gets there).

/// One histogram channel: bin width (parsed once from the first bin's name) + cumulative
/// residency (sample counts) per bin.
struct PowerHistogramChannel: Sendable, Equatable {
    var binWidthW: Double
    var bins: [UInt64]
}

/// `" 0.250W"` → 0.25, `"   1W"` → 1. Whitespace-trimmed, must end in `W`, must be a finite
/// positive number — anything else is a topology we don't understand (nil ⇒ channel unusable).
func histogramBinWidthW(firstBinName: String) -> Double? {
    var text = firstBinName.trimmingCharacters(in: .whitespaces)
    guard text.hasSuffix("W") else { return nil }
    text.removeLast()
    guard let width = Double(text), width.isFinite, width > 0 else { return nil }
    return width
}

/// Interval-average watts from two cumulative residency snapshots: Σ Δᵢ·(i+0.5)·w / Σ Δᵢ.
/// nil on shape mismatch, non-positive width, any bin going backwards (counter reset), or no
/// new samples — the caller re-baselines instead of emitting a bogus number.
func histogramMeanWatts(prev: [UInt64], curr: [UInt64], binWidthW: Double) -> Double? {
    guard prev.count == curr.count, !curr.isEmpty, binWidthW > 0 else { return nil }
    var weighted = 0.0, total = 0.0
    for i in curr.indices {
        if curr[i] < prev[i] { return nil }
        let delta = Double(curr[i] - prev[i])
        weighted += delta * (Double(i) + 0.5) * binWidthW
        total += delta
    }
    return total > 0 ? weighted / total : nil
}

/// Exactly `EACC<n>` / `PACC<n>` — the per-cluster CPU power histograms. ` SRAM` siblings and
/// `AGX` deliberately do not match (decision: CPU = clusters without SRAM, closest to the
/// macOS ≤ 26 per-core sum). Multi-die chips contribute `EACC1`/`PACC1`… too.
func isCPUClusterHistogramChannel(_ name: String) -> Bool {
    for prefix in ["EACC", "PACC"] where name.hasPrefix(prefix) {
        let rest = name.dropFirst(prefix.count)
        return !rest.isEmpty && rest.allSatisfy(\.isNumber)
    }
    return false
}

/// CPU watts = sum of every cluster channel's interval mean. nil if no cluster channel is
/// present, a channel lacks a baseline, its width changed, or its mean is nil (reset / no
/// samples) — partial sums would silently under-read.
func clusterHistogramCPUWatts(prev: [String: PowerHistogramChannel],
                              curr: [String: PowerHistogramChannel]) -> Double? {
    var sum = 0.0
    var matched = 0
    for (name, c) in curr where isCPUClusterHistogramChannel(name) {
        guard let p = prev[name], p.binWidthW == c.binWidthW,
              let watts = histogramMeanWatts(prev: p.bins, curr: c.bins, binWidthW: c.binWidthW)
        else { return nil }
        sum += watts
        matched += 1
    }
    return matched > 0 ? sum : nil
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/PowerHistogramTests 2>&1 | grep -E "error:|Executed|\*\* TEST"`
Expected: `Executed 10 tests, with 0 failures` … `** TEST SUCCEEDED **`

- [ ] **Step 5: 커밋**

```bash
git checkout -- docs/assets 2>/dev/null; git add Wattly/Core/PowerHistogram.swift WattlyTests/PowerHistogramTests.swift Wattly.xcodeproj/project.pbxproj
git commit -m "feat(power): pure PMP/Energy histogram math (bin width, weighted mean, cluster sum)

macOS 27 refreshes the Energy Model mJ counters only every 3-5 min; the PMP/Energy
state histograms (EACC0/PACC0) refresh every second. This adds the pure derivation
(uniform bins, midpoint-weighted mean, SRAM-excluded cluster sum) that PowerProvider
will use as the CPU source once staleness is detected.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: 정체 상태기계 + ANE 장주기 평균 (`PowerHistogram.swift` 추가)

**Files:**
- Modify: `Wattly/Core/PowerHistogram.swift` (파일 끝에 추가)
- Modify: `WattlyTests/PowerHistogramTests.swift` (스위트 끝에 추가)

**Interfaces:**
- Consumes: 없음.
- Produces (Task 5가 쓴다):
  ```swift
  struct EnergyModelStaleness: Sendable, Equatable {
      enum Verdict: Equatable { case live, deciding, stale }
      static let threshold: Int   // 2
      private(set) var isStale: Bool
      private(set) var zeroRun: Int
      mutating func observe(cpuCoreDeltaJ: Double) -> Verdict
  }
  struct StaleANERate: Sendable, Equatable {
      private(set) var heldW: Double
      mutating func observe(aneDeltaJ: Double, cpuCoreDeltaJ: Double, at instant: ContinuousClock.Instant) -> Double
  }
  ```

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/PowerHistogramTests.swift`의 `struct PowerHistogramTests {` 닫는 `}` 바로 앞에 추가:

```swift
    // MARK: EnergyModelStaleness — 2 consecutive kept polls with zero CPU-core delta ⇒ stale, sticky

    @Test func liveEnergyModelStaysLive() {
        var s = EnergyModelStaleness()
        #expect(s.observe(cpuCoreDeltaJ: 0.15) == .live)
        #expect(s.observe(cpuCoreDeltaJ: 2.5) == .live)
        #expect(!s.isStale)
    }

    @Test func singleZeroPollIsDecidingAndResetsOnActivity() {
        var s = EnergyModelStaleness()
        #expect(s.observe(cpuCoreDeltaJ: 0) == .deciding)
        #expect(s.observe(cpuCoreDeltaJ: 0.3) == .live)       // run broken → back to live
        #expect(s.zeroRun == 0)
        #expect(!s.isStale)
    }

    @Test func twoZeroPollsBecomeStaleAndStick() {
        var s = EnergyModelStaleness()
        #expect(s.observe(cpuCoreDeltaJ: 0) == .deciding)
        #expect(s.observe(cpuCoreDeltaJ: 0) == .stale)
        #expect(s.isStale)
        // A later Energy Model refresh (big positive delta) must NOT flip back — the refresh
        // itself is the 3–5 min stale cadence, not a recovery.
        #expect(s.observe(cpuCoreDeltaJ: 800) == .stale)
        #expect(s.observe(cpuCoreDeltaJ: 0) == .stale)
    }

    @Test func negativeDeltaCountsAsZero() {
        var s = EnergyModelStaleness()
        #expect(s.observe(cpuCoreDeltaJ: -1) == .deciding)
        #expect(s.observe(cpuCoreDeltaJ: -1) == .stale)
    }

    // MARK: StaleANERate — ANE watts averaged over the Energy Model refresh interval

    @Test func aneRateIsZeroUntilSecondRefresh() {
        var r = StaleANERate()
        let t0 = ContinuousClock.now
        // non-refresh polls (core delta 0) hold the current value
        #expect(r.observe(aneDeltaJ: 0, cpuCoreDeltaJ: 0, at: t0) == 0)
        // first refresh: no previous refresh instant → still 0, but the instant is recorded
        #expect(r.observe(aneDeltaJ: 30, cpuCoreDeltaJ: 500, at: t0.advanced(by: .seconds(1))) == 0)
        // second refresh 300 s later carrying 60 J of ANE energy → 0.2 W
        let w = r.observe(aneDeltaJ: 60, cpuCoreDeltaJ: 700, at: t0.advanced(by: .seconds(301)))
        #expect(abs(w - 0.2) < 1e-9)
        #expect(abs(r.heldW - 0.2) < 1e-9)
    }

    @Test func aneRateHoldsBetweenRefreshesAndUpdatesOnNext() {
        var r = StaleANERate()
        let t0 = ContinuousClock.now
        _ = r.observe(aneDeltaJ: 0, cpuCoreDeltaJ: 500, at: t0)
        _ = r.observe(aneDeltaJ: 100, cpuCoreDeltaJ: 500, at: t0.advanced(by: .seconds(200)))   // 0.5 W
        #expect(r.observe(aneDeltaJ: 0, cpuCoreDeltaJ: 0, at: t0.advanced(by: .seconds(201))) == 0.5)
        #expect(r.observe(aneDeltaJ: 0, cpuCoreDeltaJ: 0, at: t0.advanced(by: .seconds(250))) == 0.5)
        // idle ANE across the next interval → 0
        #expect(r.observe(aneDeltaJ: 0, cpuCoreDeltaJ: 500, at: t0.advanced(by: .seconds(400))) == 0)
    }

    @Test func aneRateIgnoresNegativeEnergyAndZeroElapsed() {
        var r = StaleANERate()
        let t0 = ContinuousClock.now
        _ = r.observe(aneDeltaJ: 0, cpuCoreDeltaJ: 1, at: t0)
        #expect(r.observe(aneDeltaJ: -5, cpuCoreDeltaJ: 1, at: t0.advanced(by: .seconds(10))) == 0)
        _ = r.observe(aneDeltaJ: 10, cpuCoreDeltaJ: 1, at: t0.advanced(by: .seconds(20)))   // 1 W
        #expect(r.observe(aneDeltaJ: 10, cpuCoreDeltaJ: 1, at: t0.advanced(by: .seconds(20))) == 1) // dt 0 → hold
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/PowerHistogramTests 2>&1 | grep -E "error:|Executed|\*\* TEST"`
Expected: 컴파일 오류 `cannot find 'EnergyModelStaleness' in scope`.

- [ ] **Step 3: 최소 구현**

`Wattly/Core/PowerHistogram.swift` 끝에 추가:

```swift
// MARK: - Energy Model staleness (macOS 27)

/// Detects the macOS 27 behaviour where the `Energy Model` CPU-core counters stop advancing
/// between 3–5 min refreshes. A LIVE Energy Model advances every poll even at idle (the E
/// cluster burns ≥ tens of mJ per second), so two consecutive kept polls with a zero core delta
/// can only mean the counters are stale. Sticky: the periodic refresh (one big positive delta)
/// is the stale cadence itself, never a recovery, so we never flip back.
struct EnergyModelStaleness: Sendable, Equatable {
    enum Verdict: Equatable {
        case live       // use Energy Model as on macOS ≤ 26
        case deciding   // one zero poll seen — emit nothing this poll
        case stale      // use the PMP histograms for CPU (sticky)
    }

    static let threshold = 2

    private(set) var isStale = false
    private(set) var zeroRun = 0

    /// Feed one KEPT poll (polls the provider already dropped as anomalies are not observed).
    mutating func observe(cpuCoreDeltaJ: Double) -> Verdict {
        if isStale { return .stale }
        if cpuCoreDeltaJ <= 0 { zeroRun += 1 } else { zeroRun = 0 }
        if zeroRun >= Self.threshold {
            isStale = true
            return .stale
        }
        return zeroRun > 0 ? .deciding : .live
    }
}

/// ANE watts while the Energy Model is stale: the `ANE` counter still refreshes every 3–5 min
/// together with the CPU-core counters, so a poll whose core delta is positive IS a refresh and
/// its ANE delta is the whole energy accrued since the previous refresh. Averaging that over the
/// refresh interval gives an honest (if slow) figure and kills the 1-second spikes; the value is
/// held until the next refresh. Idle ANE (0 J) therefore reads 0, never a spike.
struct StaleANERate: Sendable, Equatable {
    private(set) var lastRefresh: ContinuousClock.Instant?
    private(set) var heldW = 0.0

    mutating func observe(aneDeltaJ: Double, cpuCoreDeltaJ: Double,
                          at instant: ContinuousClock.Instant) -> Double {
        guard cpuCoreDeltaJ > 0 else { return heldW }          // not a refresh poll → hold
        if let last = lastRefresh {
            let d = last.duration(to: instant)
            let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
            if seconds > 0 { heldW = max(0, aneDeltaJ) / seconds }
        }
        lastRefresh = instant
        return heldW
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/PowerHistogramTests 2>&1 | grep -E "error:|Executed|\*\* TEST"`
Expected: `Executed 17 tests, with 0 failures` … `** TEST SUCCEEDED **`

- [ ] **Step 5: 커밋**

```bash
git checkout -- docs/assets 2>/dev/null; git add Wattly/Core/PowerHistogram.swift WattlyTests/PowerHistogramTests.swift
git commit -m "feat(power): Energy Model staleness state machine + ANE refresh-interval rate

Two consecutive kept polls with zero CPU-core delta mark the Energy Model stale
(sticky). While stale, ANE watts are the energy accrued between two Energy Model
refreshes divided by that interval, held until the next refresh.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `powerSample` 오버라이드 + 델타 헬퍼 (`PowerEnergy.swift`)

**Files:**
- Modify: `Wattly/Core/PowerEnergy.swift:94-123`
- Modify: `WattlyTests/PowerEnergyTests.swift` (스위트 끝에 추가)

**Interfaces:**
- Consumes: 기존 `isCPUCoreEnergyChannel`, `classifyEngine` (같은 파일).
- Produces (Task 5가 쓴다):
  ```swift
  struct PowerOverrides: Sendable, Equatable { var cpuW: Double? = nil; var npuW: Double? = nil }
  func cpuCoreEnergyDeltaJ(prev: [String: Double], curr: [String: Double]) -> Double
  func aneEnergyDeltaJ(prev: [String: Double], curr: [String: Double]) -> Double
  func powerSample(prev: [String: Double], curr: [String: Double], dt: Double,
                   overrides: PowerOverrides = PowerOverrides()) -> PowerSample
  ```
  기존 `powerSample(prev:curr:dt:)` 호출은 기본 인자로 그대로 컴파일된다.

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/PowerEnergyTests.swift`의 스위트 닫는 `}` 바로 앞에 추가:

```swift
    // MARK: overrides — macOS 27 stale-Energy-Model path swaps CPU/ANE, total stays Combined

    @Test func cpuCoreDeltaSumsRecognisedCoresOnly() {
        let prev = ["CPU Energy": 10.0, "ECPU0": 1.0, "PCPU0": 2.0, "PCPU0_SRAM": 0.0, "GPU Energy": 0.0]
        let curr = ["CPU Energy": 20.0, "ECPU0": 2.0, "PCPU0": 4.0, "PCPU0_SRAM": 9.0, "GPU Energy": 1.0]
        #expect(cpuCoreEnergyDeltaJ(prev: prev, curr: curr) == 3.0)
    }

    @Test func cpuCoreDeltaFallsBackToRollupWithoutCores() {
        #expect(cpuCoreEnergyDeltaJ(prev: ["CPU Energy": 1.0], curr: ["CPU Energy": 3.5]) == 2.5)
        #expect(cpuCoreEnergyDeltaJ(prev: [:], curr: ["GPU Energy": 3.5]) == 0)
    }

    @Test func aneDeltaSumsNPUChannels() {
        #expect(aneEnergyDeltaJ(prev: ["ANE": 1.0, "GPU": 0.0], curr: ["ANE": 4.0, "GPU": 9.0]) == 3.0)
        #expect(aneEnergyDeltaJ(prev: ["ANE": 5.0], curr: ["ANE": 1.0]) == 0)   // floored like powerSample
    }

    @Test func overridesReplaceCPUAndNPUAndRecomputeTotal() {
        // Stale Energy Model: cores read 0 J, ANE spikes 300 J in this 1 s poll.
        let prev = ["ECPU0": 5.0, "PCPU0": 5.0, "GPU Energy": 1.0, "ANE": 0.0]
        let curr = ["ECPU0": 5.0, "PCPU0": 5.0, "GPU Energy": 1.5, "ANE": 300.0]
        let s = powerSample(prev: prev, curr: curr, dt: 1.0,
                            overrides: PowerOverrides(cpuW: 1.625, npuW: 0.2))
        #expect(s.cpuW == 1.625)
        #expect(s.gpuW == 0.5)                    // GPU still from the live nJ channel
        #expect(s.npuW == 0.2)                    // not the 300 W spike
        #expect(s.totalW == s.cpuW + s.gpuW + s.npuW)
        #expect(abs(s.totalW - 2.325) < 1e-9)
    }

    @Test func partialOverrideKeepsOtherEnginesFromEnergyModel() {
        let prev = ["ECPU0": 0.0, "GPU Energy": 0.0, "ANE": 0.0]
        let curr = ["ECPU0": 2.0, "GPU Energy": 1.0, "ANE": 0.5]
        let s = powerSample(prev: prev, curr: curr, dt: 1.0, overrides: PowerOverrides(cpuW: 7.0))
        #expect(s.cpuW == 7.0)
        #expect(s.gpuW == 1.0)
        #expect(s.npuW == 0.5)
        #expect(s.totalW == 8.5)
    }

    @Test func emptyOverridesMatchLegacyBehaviour() {
        let prev = ["ECPU0": 1.0, "PCPU0": 2.0, "GPU Energy": 0.5, "ANE": 0.0]
        let curr = ["ECPU0": 2.0, "PCPU0": 4.0, "GPU Energy": 1.0, "ANE": 0.25]
        let legacy = powerSample(prev: prev, curr: curr, dt: 0.5)
        let explicit = powerSample(prev: prev, curr: curr, dt: 0.5, overrides: PowerOverrides())
        #expect(legacy == explicit)
        #expect(legacy.cpuW == 6.0)
        #expect(legacy.totalW == 7.5)
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/PowerEnergyTests 2>&1 | grep -E "error:|Executed|\*\* TEST"`
Expected: 컴파일 오류 `cannot find 'PowerOverrides' in scope` / `cpuCoreEnergyDeltaJ`.

- [ ] **Step 3: 구현**

`Wattly/Core/PowerEnergy.swift`의 `/// Watts from two absolute-energy snapshots …` 주석부터 파일 끝(`powerSample` 전체, 현재 94–123행)을 아래로 교체:

```swift
/// Per-engine overrides for the macOS 27 stale-Energy-Model path: `PowerProvider` derives CPU
/// from the PMP histograms and ANE from the refresh-interval average, and hands them in here so
/// the `totalW == cpuW + gpuW + npuW` invariant is kept in ONE place. nil = use the Energy Model
/// delta for that engine (macOS ≤ 26 behaviour).
struct PowerOverrides: Sendable, Equatable {
    var cpuW: Double? = nil
    var npuW: Double? = nil
}

private func energyDeltaJ(_ name: String, prev: [String: Double], curr: [String: Double]) -> Double {
    max(0, (curr[name] ?? 0) - (prev[name] ?? 0))
}

/// Joules the recognised CPU cores accrued between two snapshots — exact per-core channels,
/// or the `CPU Energy` roll-up only when no core channel exists (same selection `powerSample`
/// uses). Doubles as the macOS 27 staleness signal: a live Energy Model never yields 0 here.
func cpuCoreEnergyDeltaJ(prev: [String: Double], curr: [String: Double]) -> Double {
    let coreChannels = curr.keys.filter(isCPUCoreEnergyChannel)
    let cpuChannels = coreChannels.isEmpty
        ? (curr["CPU Energy"] != nil ? ["CPU Energy"] : [])
        : Array(coreChannels)
    return cpuChannels.reduce(0.0) { $0 + energyDeltaJ($1, prev: prev, curr: curr) }
}

/// Joules the ANE channel(s) accrued between two snapshots (floored at 0 like every delta).
func aneEnergyDeltaJ(prev: [String: Double], curr: [String: Double]) -> Double {
    curr.keys.reduce(0.0) { acc, name in
        classifyEngine(name) == .npu ? acc + energyDeltaJ(name, prev: prev, curr: curr) : acc
    }
}

/// Watts from two absolute-energy snapshots (joules) and the elapsed seconds.
/// CPU prefers exact per-core channels; `CPU Energy` is a compatibility fallback when
/// a chip exposes no recognized cores. `GPU`/`GPU Energy` are the same quantity, so one
/// is counted. DRAM/DCS/SoC fabric/PCIe and hierarchical CPU sub-components are excluded.
/// `overrides` replace the CPU/ANE watts (macOS 27 stale path); the total is always the sum
/// of the three engine figures actually emitted.
func powerSample(prev: [String: Double], curr: [String: Double], dt: Double,
                 overrides: PowerOverrides = PowerOverrides()) -> PowerSample {
    func watts(_ j: Double) -> Double { dt > 0 ? j / dt : 0 }

    // Single GPU channel — prefer the precise "GPU Energy", fall back to "GPU".
    let gpuChannel = curr["GPU Energy"] != nil ? "GPU Energy" : (curr["GPU"] != nil ? "GPU" : nil)
    let gpuJ = gpuChannel.map { energyDeltaJ($0, prev: prev, curr: curr) } ?? 0

    let cpuW = overrides.cpuW ?? watts(cpuCoreEnergyDeltaJ(prev: prev, curr: curr))
    let npuW = overrides.npuW ?? watts(aneEnergyDeltaJ(prev: prev, curr: curr))
    let gpuW = watts(gpuJ)

    // Combined Power — per-core CPU + GPU + ANE; the headline is exactly the breakout's sum.
    return PowerSample(totalW: cpuW + gpuW + npuW, cpuW: cpuW, gpuW: gpuW, npuW: npuW)
}
```

- [ ] **Step 4: 전체 `PowerEnergyTests` 통과 확인(기존 13개 + 새 6개)**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/PowerEnergyTests 2>&1 | grep -E "error:|Executed|\*\* TEST"`
Expected: `Executed 19 tests, with 0 failures` … `** TEST SUCCEEDED **`. 특히 `wattsFromEnergyDelta`(총합 == 합), `negativeDeltaFlooredAtZero`, `zeroDtIsZeroNotInfinity`가 그대로 통과해야 한다.

- [ ] **Step 5: 커밋**

```bash
git checkout -- docs/assets 2>/dev/null; git add Wattly/Core/PowerEnergy.swift WattlyTests/PowerEnergyTests.swift
git commit -m "feat(power): powerSample overrides + CPU-core/ANE delta helpers

PowerOverrides lets the provider substitute CPU (PMP histogram) and ANE
(refresh-interval average) watts while keeping total == cpu + gpu + npu in one
place. cpuCoreEnergyDeltaJ doubles as the macOS 27 staleness signal.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: PMP/Energy 히스토그램 구독 (`PowerHistogramSubscription.swift`)

**Files:**
- Create: `Wattly/Providers/PowerHistogramSubscription.swift`
- 참고(복제 원본): `Wattly/Providers/CPUClock.swift:10-92, 117-143`, `Wattly/Providers/PowerProvider.swift:152-246`

**Interfaces:**
- Consumes: Task 1의 `PowerHistogramChannel`, `histogramBinWidthW`, `isCPUClusterHistogramChannel`.
- Produces (Task 5가 쓴다):
  ```swift
  final class IOReportPMPEnergySubscription: @unchecked Sendable {
      init?()                                            // nil ⇒ PMP/Energy absent or no cluster channel
      var channelNames: [String] { get }                 // cluster channels resolved at init (sorted)
      func sample() -> [String: PowerHistogramChannel]?  // nil ⇒ sample failure or a channel vanished
  }
  ```

단위 테스트 없음(사설 API I/O). 빌드 green + Task 5·6의 실기 프로브로 검증한다.

- [ ] **Step 1: 구현**

`Wattly/Providers/PowerHistogramSubscription.swift`:

```swift
import Foundation

/// RAII wrapper around the IOReport private API for the `PMP` group / `Energy` subgroup
/// (macOS 27 processor-power migration). Mirrors `RealCPUClock` (`CPUClock.swift`): dlopen'd
/// symbols + one subscription live only inside this object, touched solely from
/// `PowerProvider`'s actor isolation — hence `@unchecked Sendable`. The CF handles are
/// ARC-managed Swift references; the per-poll sample dict is released at scope exit. The
/// library handle is intentionally never `dlclose`d once a subscription exists (releasing the
/// subscription must not race a `dlclose` of its CF finalizer — same rule as
/// `IOReportEnergySubscription`).
///
/// Only the CPU cluster channels (`EACC<n>`/`PACC<n>`, SRAM excluded) are decoded; their bin
/// widths are parsed ONCE here from the first bin's name (`" 0.250W"` → 0.25) and reused every
/// poll, which then reads residency counts only. All arithmetic lives in pure `PowerHistogram`.
final class IOReportPMPEnergySubscription: @unchecked Sendable {
    private typealias CopyChannelsFn =
        @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscriptionFn =
        @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary,
                        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> Unmanaged<AnyObject>?
    private typealias CreateSamplesFn =
        @convention(c) (AnyObject, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias GetStringFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias StateGetCountFn = @convention(c) (CFDictionary) -> Int32
    private typealias StateGetResidencyFn = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias StateGetNameForIndexFn = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?

    private let subscription: AnyObject
    private let subbedChannels: CFMutableDictionary
    private let createSamples: CreateSamplesFn
    private let getChannelName: GetStringFn
    private let stateGetCount: StateGetCountFn
    private let stateGetResidency: StateGetResidencyFn
    /// Cluster channel → bin width (W), resolved once at init.
    private let binWidths: [String: Double]

    /// Cluster channels this subscription decodes (e.g. `["EACC0", "PACC0"]`), sorted.
    var channelNames: [String] { binWidths.keys.sorted() }

    /// nil if the library, any symbol, the `PMP`/`Energy` subgroup, or every cluster channel is
    /// unavailable (macOS ≤ 26 or non-Apple silicon) — the provider then runs Energy-Model-only,
    /// exactly as before this migration.
    init?() {
        guard let handle = dlopen("libIOReport.dylib", RTLD_LAZY) else { return nil }
        func sym<T>(_ name: String, as type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard
            let copyChannels = sym("IOReportCopyChannelsInGroup", as: CopyChannelsFn.self),
            let createSub = sym("IOReportCreateSubscription", as: CreateSubscriptionFn.self),
            let createSamples = sym("IOReportCreateSamples", as: CreateSamplesFn.self),
            let getName = sym("IOReportChannelGetChannelName", as: GetStringFn.self),
            let getCount = sym("IOReportStateGetCount", as: StateGetCountFn.self),
            let getResidency = sym("IOReportStateGetResidency", as: StateGetResidencyFn.self),
            let getNameForIndex = sym("IOReportStateGetNameForIndex", as: StateGetNameForIndexFn.self)
        else { dlclose(handle); return nil }

        guard let channelsU = copyChannels("PMP" as CFString, "Energy" as CFString, 0, 0, 0) else {
            dlclose(handle); return nil
        }
        let channels = channelsU.takeRetainedValue()          // +1 → ARC owns; freed at init end
        var subbedOut: Unmanaged<CFMutableDictionary>?
        guard let subU = createSub(nil, channels, &subbedOut, 0, nil), let subbedU = subbedOut else {
            dlclose(handle); return nil
        }
        let sub = subU.takeRetainedValue()                  // ARC-managed for this object's life
        let subbed = subbedU.takeRetainedValue()

        // Resolve bin widths from one initial sample. From here on the library handle stays
        // open even on the nil path (a live subscription's finalizer must never race dlclose).
        var widths: [String: Double] = [:]
        if let samplesU = createSamples(sub, subbed, nil) {
            let dict = samplesU.takeRetainedValue()
            if let list = (dict as NSDictionary)["IOReportChannels"] as? [Any] {
                for case let ch as NSDictionary in list {
                    let chCF = ch as CFDictionary
                    guard let name = getName(chCF)?.takeUnretainedValue() as String?,
                          isCPUClusterHistogramChannel(name),
                          getCount(chCF) > 0,
                          let first = getNameForIndex(chCF, 0)?.takeUnretainedValue() as String?,
                          let width = histogramBinWidthW(firstBinName: first)
                    else { continue }
                    widths[name] = width
                }
            }
        }
        guard !widths.isEmpty else { return nil }             // no usable cluster channel

        self.subscription = sub
        self.subbedChannels = subbed
        self.createSamples = createSamples
        self.getChannelName = getName
        self.stateGetCount = getCount
        self.stateGetResidency = getResidency
        self.binWidths = widths
    }

    /// One snapshot of every cluster channel's cumulative residency bins. nil on sample failure
    /// or when any channel resolved at init is missing — a partial set would silently under-read
    /// the CPU sum. Walks `IOReportChannels` directly (block-free, same reason as the other
    /// IOReport wrappers: no Swift 6 data race on an accumulator).
    func sample() -> [String: PowerHistogramChannel]? {
        guard let samplesU = createSamples(subscription, subbedChannels, nil) else { return nil }
        let dict = samplesU.takeRetainedValue()               // +1 consumed; released at scope exit
        guard let list = (dict as NSDictionary)["IOReportChannels"] as? [Any] else { return nil }
        var out: [String: PowerHistogramChannel] = [:]
        out.reserveCapacity(binWidths.count)
        for case let ch as NSDictionary in list {
            let chCF = ch as CFDictionary
            guard let name = getChannelName(chCF)?.takeUnretainedValue() as String?,
                  let width = binWidths[name] else { continue }
            let count = Int(stateGetCount(chCF))
            guard count > 0 else { continue }
            var bins = [UInt64](repeating: 0, count: count)
            for i in 0..<count { bins[i] = UInt64(bitPattern: stateGetResidency(chCF, Int32(i))) }
            out[name] = PowerHistogramChannel(binWidthW: width, bins: bins)
        }
        return out.count == binWidths.count ? out : nil
    }
}
```

- [ ] **Step 2: 프로젝트 재생성 + 빌드**

Run: `~/bin/xcodegen generate && xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|warning: .*PowerHistogramSubscription|\*\* BUILD"`
Expected: `** BUILD SUCCEEDED **`, 이 파일에 대한 warning 없음. 참고: 클래스의 failable init은 stored property를 전부 대입하기 전에도 `return nil`이 허용된다(Swift 2.2+) — 그 지점의 오류가 나면 원인은 다른 데 있다.

- [ ] **Step 3: 커밋**

```bash
git add Wattly/Providers/PowerHistogramSubscription.swift Wattly.xcodeproj/project.pbxproj
git commit -m "feat(power): IOReport PMP/Energy histogram subscription

Subscribes to the PMP group's Energy subgroup, resolves EACC<n>/PACC<n> bin widths
once from the first bin's name, and samples cumulative residency per poll. Mirrors
RealCPUClock's block-free walk; nil when the group is absent (macOS <= 26).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: `PowerProvider` 배선 + DEBUG `-WattlyPowerProbe`

**Files:**
- Modify: `Wattly/Providers/PowerProvider.swift:1-96, 150`
- Modify: `Wattly/App/WattlyApp.swift:18` (훅 1줄)
- Modify: `Wattly/Models/MetricSample.swift:97` (주석)

**Interfaces:**
- Consumes: Task 1 `clusterHistogramCPUWatts`, `PowerHistogramChannel`; Task 2 `EnergyModelStaleness`, `StaleANERate`; Task 3 `PowerOverrides`, `cpuCoreEnergyDeltaJ`, `aneEnergyDeltaJ`, `powerSample(…overrides:)`; Task 4 `IOReportPMPEnergySubscription`.
- Produces: `PowerProvider.read` 동작 변경(외부 시그니처 불변). DEBUG 전용 `PowerProvider.debugSource: String`, `PowerProvider.debugHistogramCPUW: Double?`, `enum PowerProbe { static func runIfRequested() }`.

- [ ] **Step 1: 프로바이더 상태·설정 추가**

`Wattly/Providers/PowerProvider.swift`의 헤더 주석(1–8행)을 아래로 교체:

```swift
import Foundation

/// Real SoC-power provider (issue 06) — no entitlements. Reads the IOReport private
/// API's "Energy Model" group (CPU/GPU/NPU/DRAM/… energy), diffs absolute energy
/// across polls, and divides by elapsed time → watts. Works on battery, AC, and
/// desktop Macs alike (SoC-level, not battery-derived). Only the Sendable
/// `PowerSample` crosses the actor boundary; the IOReport handles never leave the
/// `IOReportEnergySubscription` / `IOReportPMPEnergySubscription` wrappers. All
/// arithmetic lives in pure `PowerEnergy` / `PowerHistogram`.
///
/// macOS 27: the Energy Model CPU/ANE counters refresh only every 3–5 min. Once
/// `EnergyModelStaleness` sees two kept polls with zero CPU-core delta it flips (sticky) to
/// deriving CPU from the `PMP`/`Energy` cluster histograms and ANE from the refresh-interval
/// average; GPU keeps using the still-live `GPU Energy` (nJ) channel. macOS ≤ 26 never trips
/// the detector, so its numbers are unchanged.
```

같은 파일 `private var prevInstant: ContinuousClock.Instant?`(19행) 바로 뒤에 추가:

```swift
    /// macOS 27 stale-Energy-Model path (see `PowerHistogram`). `histogram` is nil where the
    /// `PMP`/`Energy` subgroup is absent (macOS ≤ 26) — then only the Energy Model is used.
    private var histogram: IOReportPMPEnergySubscription?
    private var prevHistogram: [String: PowerHistogramChannel]?
    private var staleness = EnergyModelStaleness()
    private var aneRate = StaleANERate()
    #if DEBUG
    /// Probe-only: which CPU source the last kept poll used.
    private(set) var debugSource = "em"
    /// Probe-only: the histogram CPU figure of the last poll (computed even while `.live`, so
    /// the two sources can be compared side by side on-device).
    private(set) var debugHistogramCPUW: Double?
    #endif
```

- [ ] **Step 2: `read(at:)` 교체**

현재 `func read(at _: ContinuousClock.Instant) async -> ProviderReading { … }`(58–91행) 전체를 아래로 교체:

```swift
    func read(at _: ContinuousClock.Instant) async -> ProviderReading {
        if !setupAttempted {
            setupAttempted = true
            subscription = IOReportEnergySubscription()
            histogram = IOReportPMPEnergySubscription()
        }
        guard let subscription else {
            return .unavailable(.channelUnreadable(Self.unreadableMessage))
        }
        let sampleStart = now()
        guard let captured = subscription.sample(), !captured.energies.isEmpty else {
            return .unavailable(.channelUnreadable(Self.unreadableMessage))
        }
        let histSample = histogram?.sample()     // nil: no PMP (macOS ≤ 26) or a sample failure
        let sampleEnd = now()
        let sampleInstant = sampleStart.advanced(by: sampleStart.duration(to: sampleEnd) / 2)
        let curr = captured.energies
        // re-baseline on every kept path (both sources share one instant)
        defer { prev = curr; prevInstant = sampleInstant; prevHistogram = histSample }

        // An engine channel with an unknown unit is unsafe to scale. Drop this interval
        // and keep the remaining known counters only as a new baseline.
        guard captured.unknownUnitEngineChannels.isEmpty else { return .pending }

        guard let prev, let prevInstant else { return .pending }   // first sample: baseline only
        let dt = Self.seconds(from: prevInstant, to: sampleInstant)
        if dt <= 0 || dt > Self.maxPlausibleDt || hasCounterReset(prev: prev, curr: curr)
            || hasEngineChannelSetChanged(prev: prev, curr: curr) {
            return .pending                                  // anomaly → drop interval, re-baseline
        }

        let coreDeltaJ = cpuCoreEnergyDeltaJ(prev: prev, curr: curr)
        let histogramCPUW: Double? = {
            guard let p = prevHistogram, let c = histSample else { return nil }
            return clusterHistogramCPUWatts(prev: p, curr: c)
        }()
        #if DEBUG
        debugHistogramCPUW = histogramCPUW
        #endif

        var overrides = PowerOverrides()
        switch staleness.observe(cpuCoreDeltaJ: coreDeltaJ) {
        case .live:
            #if DEBUG
            debugSource = "em"
            #endif
            break                                            // Release: keeps the case non-empty
        case .deciding:
            #if DEBUG
            debugSource = "deciding"
            #endif
            return .pending                                  // one zero poll: withhold, re-baseline
        case .stale:
            #if DEBUG
            debugSource = "pmp"
            #endif
            // Energy Model is frozen between refreshes. Without a histogram source the CPU
            // figure would be a false 0 W → surface the orange card instead.
            guard histogram != nil else {
                return .unavailable(.channelUnreadable(Self.unreadableMessage))
            }
            guard let cpuW = histogramCPUW else { return .pending }   // baseline / reset / no samples
            overrides.cpuW = cpuW
            overrides.npuW = aneRate.observe(aneDeltaJ: aneEnergyDeltaJ(prev: prev, curr: curr),
                                             cpuCoreDeltaJ: coreDeltaJ, at: sampleInstant)
        }

        var sample = powerSample(prev: prev, curr: curr, dt: dt, overrides: overrides)
        guard sample.totalW.isFinite, sample.totalW <= Self.sanityCeilingW else {
            return .pending                                  // implausible → re-baseline
        }
        sample.processes = enumerating ? processPower(at: sampleInstant) : nil
        return .value(.power(sample))
    }
```

- [ ] **Step 3: DEBUG 프로브 추가**

`Wattly/Providers/PowerProvider.swift`의 `actor PowerProvider { … }` 닫는 `}`(현재 150행, `struct IOReportEnergySnapshot` 앞) 바로 뒤에 추가:

```swift
#if DEBUG
/// DEBUG 실기 프로브. 실제 `PowerProvider`로 10회 읽어 소스(em / deciding / pmp)와 엔진별 W를
/// 출력하고 종료한다. macOS 27 이관 확인용 — GUI 없이 정체 감지·히스토그램 CPU가 사는지 본다:
///   `Wattly.app/Contents/MacOS/Wattly -WattlyPowerProbe`
/// Release에서는 제외. 막힌 메인 스레드 밖에서 돌도록 detached.
enum PowerProbe {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("-WattlyPowerProbe") else { return }
        let provider = PowerProvider()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let clock = ContinuousClock()
            for i in 0..<10 {
                let reading = await provider.read(at: clock.now)
                let source = await provider.debugSource
                let histCPU = await provider.debugHistogramCPUW
                print("[power-probe] sample \(i): source=\(source) histCPU=\(f(histCPU)) W · \(describe(reading))")
                try? await Task.sleep(for: .seconds(1))
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }

    private static func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "nil" }

    private static func describe(_ r: ProviderReading) -> String {
        switch r {
        case .value(.power(let s)):
            return "total \(f(s.totalW)) W · cpu \(f(s.cpuW)) · gpu \(f(s.gpuW)) · ane \(f(s.npuW))"
        case .pending:
            return "pending"
        case .unavailable(let reason):
            return "unavailable: \(reason)"
        case .value(let other):
            return "non-power: \(other)"
        }
    }
}
#endif
```

`Wattly/App/WattlyApp.swift:18`의 `BatteryProbe.runIfRequested()` 줄 바로 뒤에 추가:

```swift
        PowerProbe.runIfRequested()    // -WattlyPowerProbe: dump CPU source + engine watts and exit (macOS 27 migration)
```

`Wattly/Models/MetricSample.swift:97`의 `var npuW: Double   // Apple Neural Engine; sourced from the HW "ANE" energy channel`를 아래로 교체:

```swift
    var npuW: Double   // Apple Neural Engine; HW "ANE" energy channel (macOS 27: refresh-interval average, see PowerHistogram)
```

- [ ] **Step 4: 빌드 + 전체 테스트**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | grep -E "Executed|error:|failed|\*\* TEST"`
Expected: 마지막 줄 `** TEST SUCCEEDED **`, `failed` 없음. 이전 합계(PR #121 시점) + 이번에 추가한 23개(PowerHistogramTests 17 + PowerEnergyTests 6).

Swift 6 오류가 나면 흔한 원인: (a) `debugSource`/`debugHistogramCPUW`를 `#if DEBUG` 밖에서 참조 — 프로브 코드 전체가 `#if DEBUG` 안에 있어야 한다. (b) `PowerOverrides`가 `Sendable`이 아님 — Task 3 정의 확인.

- [ ] **Step 5: 실기 프로브 (macOS 27, 이 머신)**

Run:
```bash
DD=$(xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/{print $3}'); "$DD/Wattly.app/Contents/MacOS/Wattly" -WattlyPowerProbe 2>&1 | grep -a power-probe
```
Expected (유휴):
```
[power-probe] sample 0: source=em histCPU=nil W · pending
[power-probe] sample 1: source=deciding histCPU=1.xx W · pending
[power-probe] sample 2: source=pmp histCPU=1.xx W · total 1.xx W · cpu 1.xx · gpu 0.0x · ane 0.00
[power-probe] sample 3…9: source=pmp, cpu 1~2 W, ane 0.00, pending 없음
```
그다음 다른 터미널에서 `yes > /dev/null & yes > /dev/null & yes > /dev/null & yes > /dev/null &`를 띄우고 다시 프로브 → `cpu`가 10 W 이상으로 즉시 올라야 한다. 끝나면 `killall yes`.

sample 1이 `source=em`으로 값이 나오면 이 머신의 EM이 살아 있다는 뜻(감사 전제와 모순) — 스펙 §1 재확인 후 진행. `histCPU=nil`이 계속되면 Task 4의 `channelNames`가 비었는지 프로브에 `print(await provider.debugSource)` 대신 구독 결과를 찍어 확인.

- [ ] **Step 6: 커밋**

```bash
git checkout -- docs/assets 2>/dev/null; git add Wattly/Providers/PowerProvider.swift Wattly/App/WattlyApp.swift Wattly/Models/MetricSample.swift
git commit -m "feat(power): switch CPU/ANE to PMP histograms when the Energy Model goes stale (macOS 27)

PowerProvider now also subscribes to PMP/Energy. After two kept polls with zero
CPU-core delta it sticks to histogram CPU + refresh-interval ANE; GPU keeps the
live nJ channel. macOS <= 26 never trips the detector. Adds -WattlyPowerProbe.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: 실기 검증 기록 + 스펙 §6

**Files:**
- Modify: `docs/superpowers/specs/2026-09-17-macos-27-processor-power-migration.md` (§6)

**Interfaces:** 없음(문서).

- [ ] **Step 1: 팝오버 눈 확인**

앱을 빌드 산출물에서 실행(`open "$DD/Wattly.app"`; 이미 떠 있는 Wattly는 먼저 종료). 팝오버 프로세서 전력 카드를 30초 관찰: 헤드라인이 매초 갱신되고 서브라인 `CPU x.x W · GPU x.x W · ANE 0.0 W`가 부하(`yes` 4개)에 다음 폴부터 반응, 스파이크 없음. 앱별 Top-N 펼침도 정상.

- [ ] **Step 2: (선택, 사용자 sudo) powermetrics 정합**

사용자가 실행: `sudo powermetrics --samplers cpu_power -i 1000 -n 10` 부하 중 `CPU Power` mW와 프로브 `cpu` 비교. ±10% 안이면 통과. 실행하지 않으면 "미실행"으로 기록.

- [ ] **Step 3: 스펙 §6 작성**

`docs/superpowers/specs/2026-09-17-macos-27-processor-power-migration.md`의 `## 6. 실기 결과` 아래 `(구현 후 기록)`을 실제 결과로 교체. 형식(1축 스펙 §6과 동일):

```markdown
## 6. 실기 결과 (2026-09-17, macOS 27.0 26A428, Mac17,2)

- `-WattlyPowerProbe` 유휴: sample 1 `deciding`, sample 2부터 `pmp`. 관측값:
  `[power-probe] sample 2: source=pmp histCPU=1.xx W · total 1.xx W · cpu 1.xx · gpu 0.0x · ane 0.00`
- `yes` ×4 부하: 다음 폴 cpu N.N W(≥ 10 W), 부하 해제 후 즉시 하강.
- 팝오버(사용자 확인): 헤드라인·CPU 서브값 매초 반응, 스파이크 없음, ANE 0.0 W 유지.
- powermetrics 정합: (값 / 미실행).
- 한계 확인: (해당 시) 32 W 상한 빈 미도달.
```

- [ ] **Step 4: 커밋**

```bash
git add docs/superpowers/specs/2026-09-17-macos-27-processor-power-migration.md
git commit -m "docs(power): record macOS 27 processor-power migration on-device results

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## 완료 기준

- Task 1–5 커밋 6개, 전체 테스트 `** TEST SUCCEEDED **`.
- 실기 프로브: 3폴째부터 `source=pmp`, 유휴 CPU 1~2 W, 부하 즉시 반응, ANE 0.0, `pending` 반복 없음.
- 스펙 §6 채움.
- PR 본문 체크리스트: (1) 실기 프로브 출력 붙임, (2) 팝오버 눈 확인, (3) powermetrics 정합(선택), (4) macOS 26 회귀 없음의 근거 = `EnergyModelStaleness`가 `cpuCoreEnergyDeltaJ > 0`이면 `.live`이고 `.live` 경로는 `powerSample(…overrides: .init())` == 기존 결과(`emptyOverridesMatchLegacyBehaviour`).
