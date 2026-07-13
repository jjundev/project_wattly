# 21 — CPU 카드 클러스터별 클럭(GHz) 표시 (스택 행 모드)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 스택 행(모드 A) CPU 카드의 확장 영역에서 각 코어 클러스터(S/P·E)의 **활성 클럭(GHz)** 을, 클러스터 헤더의 **평균 점유율 % 바로 왼쪽**에 표시한다.

**Architecture:** 클럭은 새 데이터 소스에서 온다 — IOReport 비공개 API의 `"CPU Stats"` 그룹(`"CPU Complex Performance States"` 서브그룹)의 클러스터별 DVFS 잔류(residency) 카운터 + IORegistry `pmgr`의 DVFS 주파수 테이블(`voltage-statesN-sram`). 순수 계산(`CPUFrequency`: 테이블 디코드 + 잔류 델타 가중평균 + 순서기반 부착)과 I/O(`RealCPUClock`: IOReport 구독 + IOKit 테이블 읽기, 기존 `IOReportEnergySubscription`을 그대로 미러)로 분리한다. `PerfLevelUsage`에 `activeGHz: Double?`를 더하고, `MetricCardView.cpuExpand`의 헤더 행이 그 값을 % 왼쪽에 렌더한다.

**Tech Stack:** Swift 6(strict concurrency complete), macOS 14.0 / arm64, SwiftUI, IOReport(`libIOReport.dylib`, dlopen)·IOKit(IORegistry) 비공개/저수준 API(엔타이틀먼트 불필요), Swift Testing(`import Testing`).

## Global Constraints

- **언어 모드:** Swift 6 strict concurrency. 액터 경계를 넘는 건 오직 `Sendable` 값 타입(`CPUSample`/`MetricSample`)뿐. IOReport/IOKit 핸들은 래퍼(`RealCPUClock`) 밖으로 절대 나가지 않는다 (`@unchecked Sendable`, `CPUProvider` 액터 격리 안에서만 접근).
- **배포 타깃:** macOS 14.0, arm64 전용.
- **비공개 API 정책:** `dlopen`은 leaf 이름(`"libIOReport.dylib"`)만. 라이브러리·심볼·그룹·테이블 중 하나라도 없으면 **graceful nil 강등** — 클럭만 사라지고 나머지 CPU 카드는 그대로(기존 `PowerProvider` 철학과 동일).
- **클럭 의미:** powermetrics 패리티 = **활성(비-유휴) DVFS 잔류 가중평균**. 유휴 빈(bin 0)은 제외.
- **레이어링:** 순수 로직은 `Wattly/Core/`, I/O는 `Wattly/Providers/`. 테스트는 Swift Testing(`@Test`/`#expect`), 하드웨어 미접촉(합성 입력만).
- **프로젝트 파일:** XcodeGen 폴더 글롭(`sources: Wattly` / `WattlyTests`) — **새 `.swift` 파일 추가 후 반드시 `xcodegen generate`** 로 `.xcodeproj`에 반영한 뒤 빌드.
- **UI 카피:** 한국어. 클럭 토큰은 `"X.XX GHz"`.
- **빌드:** `xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
- **테스트:** `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test`

## 배경 / 온-디바이스로 검증된 사실 (M5, macOS 26.5.1)

- 토폴로지: `hw.nperflevels=2`, `hw.perflevel0.name="Super"`(4코어), `hw.perflevel1.name="Efficiency"`(6코어). 즉 이 칩의 클러스터 접두어는 **S·E** (다른 칩은 P·E). 사용자가 말한 "s, p, e"는 런타임 클러스터를 통칭 — 코드는 이미 `CardPresentation.corePrefix(level.name)`(첫 글자 대문자)로 처리한다.
- DVFS 주파수 테이블은 IORegistry `pmgr` 노드에 존재: `voltage-states5-sram`(19상태, 1.308–4.608 GHz) = **Performance/Super 클러스터**, `voltage-states1-sram`(8상태, 0.972–3.048 GHz) = **Efficiency 클러스터**. 포맷: 8바이트 엔트리 `(freqRaw: UInt32 LE, microvolts: UInt32 LE)`, `GHz = freqRaw / 1e6`. (비-`-sram` 테이블은 다른 값 → 쓰지 않는다.)
- CPU 사용률 샘플은 **평활 대상이 아님**(평활은 power·battery만) → `CPUSample`은 raw로 흘러가고 클럭 필드가 그대로 보존된다.
- `cpuExpand`(클러스터 헤더 + 코어 바)는 **모드 A(`MetricCardView`) 전용** — 모드 B/C(그리드·히어로)에는 없다. 따라서 "스택 행 모드"는 자연히 이 뷰로 스코프된다. **모드 B/C는 건드리지 않는다.**

## ⚠️ 온-디바이스 needs-you (빌드 후 실기 확인 — 비공개 API 리버스 지점)

이전 plan(06/16)과 동일하게, 아래는 실기에서 눈으로 확인해야 하는 IOReport 리버스 항목이다. 코드는 이 가정으로 작성하되, `RealCPUClock`은 어긋나도 안전하게 nil 강등한다.

1. **채널 이름:** `"CPU Complex Performance States"` 채널명이 `"ECPU"`/`"PCPU"`(멀티다이면 `"ECPU0"` 등 접미 숫자)인지. `name.contains("PCPU"/"ECPU")` 분류가 맞는지.
2. **유휴 빈 위치:** 잔류 배열 `bin[0]`이 유휴/오프 빈인지(그래서 활성 계산에서 제외). `IOReportStateGetNameForIndex`로 `"IDLE"/"DOWN"/"OFF"` 확인 권장.
3. **테이블↔클러스터 짝:** `states5-sram`=Performance, `states1-sram`=Efficiency 매핑이 이 칩에서 맞는지(디코드 GHz 범위로 교차 확인 — P가 더 높음).
4. **눈 확인:** 부하를 주며(예: `yes > /dev/null &`) 카드를 펼쳤을 때 S/E 클러스터 GHz가 % 왼쪽에 뜨고 powermetrics `CPU cluster active frequency`와 대략 일치하는지. 사용률 첫 표시 후 **클럭은 1폴 늦게** 나타남(클럭 소스 베이스라인 1회).

---

## File Structure

- `Wattly/Models/MetricSample.swift` — `PerfLevelUsage`에 `activeGHz: Double? = nil` 추가 (**수정**).
- `Wattly/Core/CPUFrequency.swift` — 순수: `decodeDVFSTable` / `activeGHz` / `attaching` (**신규**).
- `Wattly/Providers/CPUClock.swift` — `RealCPUClock`(IOReport `"CPU Stats"` 구독 + DVFS 테이블 IOKit 읽기 + 순서기반 매핑) (**신규**).
- `Wattly/Providers/CPUProvider.swift` — `RealCPUClock` 지연 생성 + `read()`에서 클럭 부착 (**수정**).
- `Wattly/Core/CardPresentation.swift` — `ghzText(_:)` 추가 (**수정**).
- `Wattly/Views/MetricCardView.swift` — `cpuExpand` 클러스터 헤더에 GHz를 % 왼쪽에 (**수정**).
- `Wattly/Providers/FakeProvider.swift` — 페이크 CPU 샘플에 데모 GHz (**수정**).
- `WattlyTests/CPUFrequencyTests.swift` — 순수 로직 + 모델 기본값 테스트 (**신규**).
- `WattlyTests/CardPresentationTests.swift` — `ghzText` 테스트 추가 (**수정**).

---

### Task 1: 모델 필드 + 페이크 데모 값

**Files:**
- Modify: `Wattly/Models/MetricSample.swift:24-28`
- Modify: `Wattly/Providers/FakeProvider.swift:93-96`
- Test: `WattlyTests/CPUFrequencyTests.swift` (신규 — 이 파일은 Task 2에서도 이어 씀)

**Interfaces:**
- Produces: `PerfLevelUsage.activeGHz: Double?` (기본 `nil`) — 이후 모든 태스크가 이 필드를 읽고/쓴다.

- [ ] **Step 1: 실패하는 테스트 작성** — 새 파일 `WattlyTests/CPUFrequencyTests.swift`

```swift
import Testing
import Foundation
@testable import Wattly

struct CPUFrequencyTests {
    @Test func perfLevelActiveGHzDefaultsNil() {
        #expect(PerfLevelUsage(name: "P", usage: 0).activeGHz == nil)
    }
}
```

- [ ] **Step 2: XcodeGen 재생성 + 실패 확인**

Run: `xcodegen generate && xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | tail -30`
Expected: 컴파일 실패 — `value of type 'PerfLevelUsage' has no member 'activeGHz'`.

- [ ] **Step 3: 모델 필드 추가** — `Wattly/Models/MetricSample.swift`, `PerfLevelUsage`를 아래로 교체

```swift
struct PerfLevelUsage: Sendable, Equatable {
    var name: String          // runtime perf-level name (e.g. "Performance", "Efficiency")
    var usage: Double          // 0–100, tick-weighted average across this level's cores
    var cores: [Double] = []   // per-core usage 0–100, in physical-cpu order (issue 04)
    /// Per-cluster active clock in GHz (plan 21), or nil when the DVFS residency source is
    /// unavailable (pre-"CPU Stats" macOS, single-cluster fallback, or first-poll baseline).
    var activeGHz: Double? = nil
}
```

- [ ] **Step 4: 페이크 CPU 샘플에 데모 GHz** — `Wattly/Providers/FakeProvider.swift:93-96` 교체

```swift
            return .cpu(CPUSample(overall: c, perfLevels: [
                PerfLevelUsage(name: "Performance", usage: pAvg, cores: Self.spread(pAvg, count: 4),
                               activeGHz: 1.6 + pAvg / 100 * 2.6),
                PerfLevelUsage(name: "Efficiency", usage: eAvg, cores: Self.spread(eAvg, count: 6),
                               activeGHz: 0.9 + eAvg / 100 * 1.5),
            ]))
```

- [ ] **Step 5: 통과 확인**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: PASS (`perfLevelActiveGHzDefaultsNil` 포함 전체 green).

- [ ] **Step 6: 커밋**

```bash
git add Wattly/Models/MetricSample.swift Wattly/Providers/FakeProvider.swift WattlyTests/CPUFrequencyTests.swift Wattly.xcodeproj
git commit -m "feat(cpu): PerfLevelUsage.activeGHz field + fake demo clocks (plan 21)"
```

---

### Task 2: 순수 — DVFS 주파수 테이블 디코드

**Files:**
- Create: `Wattly/Core/CPUFrequency.swift`
- Test: `WattlyTests/CPUFrequencyTests.swift` (이어 씀)

**Interfaces:**
- Produces: `enum CPUFrequency { static func decodeDVFSTable(_ data: Data) -> [Double] }` — `voltage-statesN-sram` 블롭 → 상태별 GHz 배열(모든 엔트리 보존, 필터 없음 — 잔류 빈 인덱스와 1:1 정렬 유지).

- [ ] **Step 1: 실패하는 테스트 추가** — `CPUFrequencyTests`에 아래 메서드 추가

```swift
    // MARK: DVFS table decode
    private func dvfs(_ pairs: [(UInt32, UInt32)]) -> Data {
        var d = Data()
        for (f, v) in pairs {
            withUnsafeBytes(of: f.littleEndian) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        return d
    }

    @Test func decodesEightBytePairsToGHz() {
        // (2_000_000, 700) & (4_000_000, 800) → 2.0, 4.0 GHz (exactly representable).
        #expect(CPUFrequency.decodeDVFSTable(dvfs([(2_000_000, 700), (4_000_000, 800)])) == [2.0, 4.0])
    }

    @Test func keepsEveryEntryIncludingZeroForBinAlignment() {
        // A zero-freq padding entry is KEPT (as 0.0) so table index stays aligned to residency bins.
        #expect(CPUFrequency.decodeDVFSTable(dvfs([(1_000_000, 700), (0, 0), (2_000_000, 800)])) == [1.0, 0.0, 2.0])
    }
```

- [ ] **Step 2: 실패 확인**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: 컴파일 실패 — `cannot find 'CPUFrequency' in scope`.

- [ ] **Step 3: 최소 구현** — 새 파일 `Wattly/Core/CPUFrequency.swift`

```swift
import Foundation

/// Pure per-cluster active-clock derivation for the CPU card (plan 21). No IOKit/IOReport
/// here — the provider does the I/O and hands raw bytes / residency counters in. Fully
/// deterministic under synthetic input.
enum CPUFrequency {
    /// Decode a `voltage-statesN-sram` property blob into per-state GHz.
    /// Layout: 8-byte entries `(freqRaw: UInt32 LE, microvolts: UInt32 LE)`, `GHz = freqRaw / 1e6`
    /// (verified M5: states5-sram → 1.31…4.61 GHz, states1-sram → 0.97…3.05 GHz).
    /// EVERY entry is kept (including zero-freq / repeated padding) so table index i stays
    /// aligned 1:1 with residency bin i+1 — filtering here would desync the two.
    static func decodeDVFSTable(_ data: Data) -> [Double] {
        let n = data.count / 8
        var out: [Double] = []
        out.reserveCapacity(n)
        data.withUnsafeBytes { raw in
            for i in 0..<n {
                let f = raw.loadUnaligned(fromByteOffset: i * 8, as: UInt32.self)
                out.append(Double(f) / 1_000_000.0)
            }
        }
        return out
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `xcodegen generate && xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: PASS (`decodesEightBytePairsToGHz`, `keepsEveryEntryIncludingZeroForBinAlignment`).

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Core/CPUFrequency.swift WattlyTests/CPUFrequencyTests.swift Wattly.xcodeproj
git commit -m "feat(cpu): pure DVFS voltage-states table decoder (plan 21)"
```

---

### Task 3: 순수 — 잔류 델타 가중 활성 클럭

**Files:**
- Modify: `Wattly/Core/CPUFrequency.swift`
- Test: `WattlyTests/CPUFrequencyTests.swift` (이어 씀)

**Interfaces:**
- Consumes: `CPUFrequency.decodeDVFSTable` (같은 enum).
- Produces: `CPUFrequency.activeGHz(tableGHz: [Double], prev: [UInt64], curr: [UInt64]) -> Double?` — 두 누적 잔류 스냅샷의 델타를 주파수 가중평균. `bin[0]`=유휴(제외), `bin[i]`(i≥1)=`tableGHz[i-1]` 상태 체류. 활성 체류가 없으면(전부 유휴/카운터 리셋/길이 불일치) `nil`.

- [ ] **Step 1: 실패하는 테스트 추가**

```swift
    // MARK: active-frequency weighting
    @Test func weightsResidencyDeltasSkippingIdleBin() {
        // table [2.0, 4.0]; bins [idle, s0, s1]. delta idle 0, s0 3@2.0, s1 1@4.0 → (6+4)/4 = 2.5
        #expect(CPUFrequency.activeGHz(tableGHz: [2.0, 4.0], prev: [10, 0, 0], curr: [10, 3, 1]) == 2.5)
    }

    @Test func fullyIdleIntervalIsNil() {
        // only the idle bin advanced → no active dwell.
        #expect(CPUFrequency.activeGHz(tableGHz: [2.0, 4.0], prev: [10, 5, 5], curr: [20, 5, 5]) == nil)
    }

    @Test func counterResetIsNil() {
        #expect(CPUFrequency.activeGHz(tableGHz: [2.0], prev: [0, 100], curr: [0, 40]) == nil)
    }

    @Test func mismatchedLengthsAreNil() {
        #expect(CPUFrequency.activeGHz(tableGHz: [2.0], prev: [0, 1], curr: [0, 1, 2]) == nil)
        #expect(CPUFrequency.activeGHz(tableGHz: [2.0], prev: [5], curr: [5]) == nil)
    }
```

- [ ] **Step 2: 실패 확인**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: 컴파일 실패 — `type 'CPUFrequency' has no member 'activeGHz'`.

- [ ] **Step 3: 구현** — `Wattly/Core/CPUFrequency.swift`의 `decodeDVFSTable` 아래에 추가

```swift
    /// Frequency-weighted active clock (GHz) from two cumulative DVFS residency snapshots.
    /// Bin 0 is the idle/off bin and is skipped; bin i (i≥1) is dwell in the DVFS state whose
    /// frequency is `tableGHz[i-1]`. Returns nil when no active dwell accrued this interval
    /// (fully idle, counter reset, or a length mismatch) so the caller shows no clock, not 0.
    static func activeGHz(tableGHz: [Double], prev: [UInt64], curr: [UInt64]) -> Double? {
        guard prev.count == curr.count, curr.count >= 2 else { return nil }
        let active = min(curr.count - 1, tableGHz.count)
        var weighted = 0.0, total = 0.0
        for i in 0..<active {
            let bin = i + 1
            if curr[bin] < prev[bin] { return nil }        // cumulative counter reset → drop interval
            let d = Double(curr[bin] - prev[bin])
            weighted += d * tableGHz[i]
            total += d
        }
        return total > 0 ? weighted / total : nil
    }
```

- [ ] **Step 4: 통과 확인**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: PASS (네 테스트 모두).

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Core/CPUFrequency.swift WattlyTests/CPUFrequencyTests.swift
git commit -m "feat(cpu): pure DVFS-residency active-frequency weighting (plan 21)"
```

---

### Task 4: 순수 — 순서기반 클럭 부착

**Files:**
- Modify: `Wattly/Core/CPUFrequency.swift`
- Test: `WattlyTests/CPUFrequencyTests.swift` (이어 씀)

**Interfaces:**
- Produces: `CPUFrequency.attaching(_ sample: CPUSample, clockGHz: [Double?]) -> CPUSample` — `clockGHz[i]`를 `perfLevels[i].activeGHz`에 부착(perf-level **순서** 정렬). 짧거나 긴 배열은 짧은 쪽까지만.

- [ ] **Step 1: 실패하는 테스트 추가**

```swift
    // MARK: order-based attach
    @Test func attachesClockByPerfLevelOrder() {
        let s = CPUSample(overall: 50, perfLevels: [
            PerfLevelUsage(name: "Performance", usage: 60, cores: [60]),
            PerfLevelUsage(name: "Efficiency", usage: 20, cores: [20]),
        ])
        let out = CPUFrequency.attaching(s, clockGHz: [3.4, 2.1])
        #expect(out.perfLevels[0].activeGHz == 3.4)
        #expect(out.perfLevels[1].activeGHz == 2.1)
    }

    @Test func attachToleratesNilAndShortArray() {
        let s = CPUSample(overall: 0, perfLevels: [
            PerfLevelUsage(name: "Performance", usage: 0, cores: []),
            PerfLevelUsage(name: "Efficiency", usage: 0, cores: []),
        ])
        let out = CPUFrequency.attaching(s, clockGHz: [nil])   // short + nil
        #expect(out.perfLevels[0].activeGHz == nil)
        #expect(out.perfLevels[1].activeGHz == nil)
    }
```

- [ ] **Step 2: 실패 확인**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: 컴파일 실패 — `type 'CPUFrequency' has no member 'attaching'`.

- [ ] **Step 3: 구현** — `Wattly/Core/CPUFrequency.swift`의 `activeGHz` 아래에 추가

```swift
    /// Attach per-cluster clocks onto a freshly derived `CPUSample`, aligned by perf-level
    /// order (`clockGHz[i]` → `perfLevels[i]`). Pure so the order-mapping is unit-tested
    /// without touching IOReport. Extra/short `clockGHz` is tolerated (zip to the shorter).
    static func attaching(_ sample: CPUSample, clockGHz: [Double?]) -> CPUSample {
        var s = sample
        for i in s.perfLevels.indices where i < clockGHz.count {
            s.perfLevels[i].activeGHz = clockGHz[i]
        }
        return s
    }
```

- [ ] **Step 4: 통과 확인**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Core/CPUFrequency.swift WattlyTests/CPUFrequencyTests.swift
git commit -m "feat(cpu): pure order-based clock attach onto CPUSample (plan 21)"
```

---

### Task 5: 표시 — `ghzText` + `cpuExpand` 헤더 배선

**Files:**
- Modify: `Wattly/Core/CardPresentation.swift` (`f1` 근처, `:196` 부근에 추가)
- Modify: `Wattly/Views/MetricCardView.swift:127-136`
- Test: `WattlyTests/CardPresentationTests.swift`

**Interfaces:**
- Consumes: `PerfLevelUsage.activeGHz` (Task 1).
- Produces: `CardPresentation.ghzText(_ ghz: Double) -> String` → `"X.XX GHz"`.

- [ ] **Step 1: 실패하는 테스트 추가** — `WattlyTests/CardPresentationTests.swift`의 `struct` 안에 추가

```swift
    @Test func ghzTextTwoDecimalsWithUnit() {
        #expect(CardPresentation.ghzText(3.456) == "3.46 GHz")
        #expect(CardPresentation.ghzText(1.2) == "1.20 GHz")
    }
```

- [ ] **Step 2: 실패 확인**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: 컴파일 실패 — `type 'CardPresentation' has no member 'ghzText'`.

- [ ] **Step 3: `ghzText` 구현** — `Wattly/Core/CardPresentation.swift`의 `f1` 정의(`:196`) 바로 아래에 추가

```swift
    /// GHz → "X.XX GHz" for the CPU card's per-cluster clock (plan 21). Two decimals:
    /// cluster active clock sits in a tight ~1–5 GHz range where 0.01 GHz (10 MHz) is the
    /// meaningful resolution.
    static func ghzText(_ ghz: Double) -> String {
        String(format: "%.2f GHz", ghz)
    }
```

- [ ] **Step 4: `cpuExpand` 클러스터 헤더 배선** — `Wattly/Views/MetricCardView.swift:127-136`의 `HStack(spacing: 8) { … }` 블록을 아래로 교체 (GHz를 `Spacer`와 `%` 사이 = **% 왼쪽**에 삽입)

```swift
                    HStack(spacing: 8) {
                        Text(level.name)
                            .font(WattlyFont.at(11, weight: .bold))
                            .foregroundStyle(t.sub)
                        Spacer(minLength: 8)
                        if let ghz = level.activeGHz {
                            Text(CardPresentation.ghzText(ghz))
                                .font(WattlyFont.at(11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(t.faint)
                        }
                        Text("\(Int(level.usage.rounded()))%")
                            .font(WattlyFont.at(12, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(idx == 0 ? Tokens.accent : t.sub)
                    }
```

- [ ] **Step 5: 통과 확인 + 빌드**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: PASS (`ghzTextTwoDecimalsWithUnit` 포함). 빌드 성공.

- [ ] **Step 6: 페이크로 눈 확인 (선택, 권장)** — 페이크 GHz(Task 1)가 이미 채워지므로 CPU 카드를 펼치면 S/E 헤더에 `X.XX GHz`가 % 왼쪽에 뜬다.

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build && open build/Debug/Wattly.app` *(경로는 `-showBuildSettings`의 `BUILT_PRODUCTS_DIR` 기준으로 조정)*
Expected: 메뉴바 → CPU 카드 탭 확장 → `Performance … 3.xx GHz  NN%` / `Efficiency … 1.xx GHz  NN%`.

- [ ] **Step 7: 커밋**

```bash
git add Wattly/Core/CardPresentation.swift Wattly/Views/MetricCardView.swift WattlyTests/CardPresentationTests.swift
git commit -m "feat(cpu): render per-cluster GHz left of usage % in expand (plan 21)"
```

---

### Task 6: I/O — `RealCPUClock` (IOReport "CPU Stats" + DVFS 테이블)

**Files:**
- Create: `Wattly/Providers/CPUClock.swift`

**Interfaces:**
- Consumes: `CPUFrequency.decodeDVFSTable` / `CPUFrequency.activeGHz` (Task 2·3), `PerfLevel`(`Wattly/Core/CPUUsage.swift`).
- Produces: `final class RealCPUClock: @unchecked Sendable`, `init?()`(graceful nil), `func sampleGHz(topology: [PerfLevel]) -> [Double?]` — perf-level 순서 정렬(인덱스 0=Performance 클러스터=PCPU/states5, 1=Efficiency=ECPU/states1). 첫 호출은 베이스라인이라 전부 nil.

> **주의:** 이 태스크의 자동 검증은 **빌드 성공**까지. 런타임 동작은 Task 7의 실기 확인에서(비공개 API라 유닛테스트 불가 — 기존 `IOReportEnergySubscription`과 동일 방침).

- [ ] **Step 1: 파일 생성** — `Wattly/Providers/CPUClock.swift`

```swift
import Foundation
import IOKit

/// Live per-cluster CPU clock source (plan 21) — reads the IOReport private API's "CPU Stats"
/// group ("CPU Complex Performance States" subgroup) for per-cluster DVFS residency, plus the
/// IORegistry `pmgr` DVFS frequency tables (`voltage-statesN-sram`). Mirrors
/// `IOReportEnergySubscription`: dlopen'd symbols + subscription live only inside this object,
/// touched solely from `CPUProvider`'s actor isolation (hence `@unchecked Sendable`). All
/// arithmetic lives in pure `CPUFrequency`.
final class RealCPUClock: @unchecked Sendable {
    // Two clusters — matches every current Apple Silicon Mac's 2-perflevel topology. A
    // hypothetical 3+-level chip collapses indices ≥1 onto `.efficiency` (acceptable
    // degrade; the rest of the CPU-card code shares the same 2-level assumption).
    private enum Cluster: Hashable { case performance, efficiency }

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

    private let subscription: AnyObject
    private let subbedChannels: CFMutableDictionary
    private let createSamples: CreateSamplesFn
    private let getChannelName: GetStringFn
    private let stateGetCount: StateGetCountFn
    private let stateGetResidency: StateGetResidencyFn

    /// DVFS freq tables (GHz) per cluster, read once from IORegistry.
    private let tables: [Cluster: [Double]]
    /// Previous cumulative residency bins per cluster — nil until the first sample.
    private var prev: [Cluster: [UInt64]] = [:]

    /// nil if the library, any symbol, the "CPU Stats" group, or every DVFS table is
    /// unavailable — graceful degrade (the CPU card then simply shows no clock).
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
            let getRes = sym("IOReportStateGetResidency", as: StateGetResidencyFn.self)
        else { dlclose(handle); return nil }

        // One channel per cluster (ECPU/PCPU) lives in this subgroup.
        guard let channelsU = copyChannels("CPU Stats" as CFString,
                                           "CPU Complex Performance States" as CFString, 0, 0, 0) else {
            dlclose(handle); return nil
        }
        let channels = channelsU.takeRetainedValue()
        var subbedOut: Unmanaged<CFMutableDictionary>?
        guard let subU = createSub(nil, channels, &subbedOut, 0, nil), let subbedU = subbedOut else {
            dlclose(handle); return nil
        }

        // states5-sram = performance cluster, states1-sram = efficiency (asitop/macmon convention,
        // verified on M5). An absent table just means that cluster reports no clock.
        var t: [Cluster: [Double]] = [:]
        if let p = Self.readDVFSTable("voltage-states5-sram") { t[.performance] = p }
        if let e = Self.readDVFSTable("voltage-states1-sram") { t[.efficiency] = e }
        // Self-correct the table↔cluster pairing (needs-you §3): the performance cluster always
        // tops out higher than efficiency, so if a chip decoded reversed, swap — no runtime
        // dependence on the hardcoded states5=P/states1=E convention holding on every SoC.
        if let p = t[.performance], let e = t[.efficiency],
           let pMax = p.max(), let eMax = e.max(), pMax < eMax {
            t[.performance] = e; t[.efficiency] = p
        }
        guard !t.isEmpty else { dlclose(handle); return nil }

        self.subscription = subU.takeRetainedValue()
        self.subbedChannels = subbedU.takeRetainedValue()
        self.createSamples = createSamples
        self.getChannelName = getName
        self.stateGetCount = getCount
        self.stateGetResidency = getRes
        self.tables = t
        // library handle intentionally left open (matches IOReportEnergySubscription).
    }

    /// Per-perf-level active clock (GHz), indexed to `topology` order: element i is the clock
    /// for `topology[i]`. `topology[0]` is the highest-performance level → performance cluster
    /// (PCPU/states5); index 1 → efficiency. nil where unavailable or first-poll baseline.
    func sampleGHz(topology: [PerfLevel]) -> [Double?] {
        guard !topology.isEmpty else { return [] }
        let residencies = currentResidencies()
        defer { for (k, v) in residencies { prev[k] = v } }

        var byCluster: [Cluster: Double?] = [:]
        for (cluster, curr) in residencies {
            guard let table = tables[cluster], let p = prev[cluster] else {
                byCluster[cluster] = Double?.none          // baseline poll → nil
                continue
            }
            byCluster[cluster] = CPUFrequency.activeGHz(tableGHz: table, prev: p, curr: curr)
        }

        return topology.indices.map { i in
            let cluster: Cluster = (i == 0) ? .performance : .efficiency
            return byCluster[cluster] ?? nil
        }
    }

    /// One residency snapshot per cluster, summed across dies of the same kind. Walks the
    /// sample dict's `IOReportChannels` array directly (block-free — same reason as the energy
    /// subscription: no Swift 6 data race on an accumulator).
    private func currentResidencies() -> [Cluster: [UInt64]] {
        guard let samplesU = createSamples(subscription, subbedChannels, nil) else { return [:] }
        let dict = samplesU.takeRetainedValue()
        guard let channels = (dict as NSDictionary)["IOReportChannels"] as? [Any] else { return [:] }
        var out: [Cluster: [UInt64]] = [:]
        for case let ch as NSDictionary in channels {
            let chCF = ch as CFDictionary
            guard let name = getChannelName(chCF)?.takeUnretainedValue() as String? else { continue }
            let cluster: Cluster
            if name.contains("PCPU") { cluster = .performance }
            else if name.contains("ECPU") { cluster = .efficiency }
            else { continue }
            let count = Int(stateGetCount(chCF))
            guard count > 0 else { continue }
            var bins = [UInt64](repeating: 0, count: count)
            for i in 0..<count { bins[i] = UInt64(bitPattern: stateGetResidency(chCF, Int32(i))) }
            if let existing = out[cluster], existing.count == bins.count {
                out[cluster] = zip(existing, bins).map { $0 &+ $1 }   // sum dies of same kind
            } else {
                out[cluster] = bins
            }
        }
        return out
    }

    /// First `AppleARMIODevice` (the `pmgr` node) that carries `key`, decoded to a GHz table.
    private static func readDVFSTable(_ key: String) -> [Double]? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleARMIODevice"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var result: [Double]?
        while true {
            let service = IOIteratorNext(iter)
            if service == 0 { break }
            if result == nil,
               let cf = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let data = cf as? Data {
                let table = CPUFrequency.decodeDVFSTable(data)
                if !table.isEmpty { result = table }
            }
            IOObjectRelease(service)
        }
        return result
    }
}
```

- [ ] **Step 2: XcodeGen 재생성 + 빌드**

Run: `xcodegen generate && xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -25`
Expected: BUILD SUCCEEDED (경고 없이 — Swift 6 동시성 위반 없음).

- [ ] **Step 3: 커밋**

```bash
git add Wattly/Providers/CPUClock.swift Wattly.xcodeproj
git commit -m "feat(cpu): RealCPUClock — IOReport CPU-stats + DVFS freq tables (plan 21)"
```

---

### Task 7: 배선 — `CPUProvider`에 클럭 부착 + 전체 green + 실기 확인

**Files:**
- Modify: `Wattly/Providers/CPUProvider.swift:7-22` (필드), `:14-22` (`read`)

**Interfaces:**
- Consumes: `RealCPUClock`(Task 6), `CPUFrequency.attaching`(Task 4).

- [ ] **Step 1: 클럭 필드 추가** — `Wattly/Providers/CPUProvider.swift`의 `private var topology: [PerfLevel]?`(:12) 바로 아래에 추가

```swift
    /// Live per-cluster clock source (plan 21). Built once, lazily (like `topology`); nil after
    /// the attempt means unavailable → the CPU card just shows no clock (graceful degrade).
    private var clockSetupAttempted = false
    private var clock: RealCPUClock?
```

- [ ] **Step 2: `read()`에서 부착** — `Wattly/Providers/CPUProvider.swift:14-22`의 `read` 본문을 아래로 교체

```swift
    func read(at instant: ContinuousClock.Instant) async -> ProviderReading {
        guard let curr = sampleTicks() else {
            return .unavailable(.providerError("CPU 사용률을 읽을 수 없음"))
        }
        if topology == nil { topology = Self.readTopology() }
        if !clockSetupAttempted { clockSetupAttempted = true; clock = RealCPUClock() }
        defer { prev = curr }
        guard let prev else { return .pending }   // first poll: no baseline yet
        let topo = topology ?? []
        var sample = cpuUsage(prev: prev, curr: curr, topology: topo)
        if let clock {
            // Order-aligned per-cluster clock (baseline poll → all nil, real from the next poll).
            sample = CPUFrequency.attaching(sample, clockGHz: clock.sampleGHz(topology: topo))
        }
        return .value(.cpu(sample))
    }
```

- [ ] **Step 3: 전체 스위트 green**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | tail -25`
Expected: 전체 PASS (기존 + plan 21 신규 ~11 케이스). 실패 0.

- [ ] **Step 4: 실기 확인 (needs-you §1–4)** — 실제 CPU 카드에서 클럭 검증

```bash
# 부하 유발 (확인 후 반드시 kill)
yes > /dev/null & yes > /dev/null &
JOBS=$(jobs -p)
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
# BUILT_PRODUCTS_DIR 확인 후 open <...>/Wattly.app  → 메뉴바 → CPU 카드 확장
# (선택) 대조: sudo powermetrics -i1000 -n1 --samplers cpu_power | grep -i "cluster.*frequency"
kill $JOBS
```
Expected: `Performance/Super` 헤더에 대략 3–4 GHz, `Efficiency`에 1–3 GHz가 **% 왼쪽**에 표시. powermetrics의 cluster active frequency와 대략 일치. 사용률 표시 후 클럭은 1폴 늦게 등장(정상). 어긋나면 needs-you §1–3(채널명/유휴 빈/테이블 짝)을 조정.

- [ ] **Step 5: 커밋 + 브랜치 마무리**

```bash
git add Wattly/Providers/CPUProvider.swift
git commit -m "feat(cpu): wire RealCPUClock into CPUProvider — cluster GHz in card (plan 21)"
```

이후 `superpowers:finishing-a-development-branch`로 병합/PR 옵션 진행. PR 본문에 needs-you §1–4의 실기 결과를 남길 것.

---

## Self-Review 결과

- **스펙 커버리지:** "각 코어(s/p/e) 클럭 GHz 확인"(Task 6·7이 데이터, Task 1 모델), "평균 점유율 % 왼쪽에 표시"(Task 5 헤더 배선 — `Spacer`와 `%` 사이 삽입), "스택 행 모드"(모드 A `cpuExpand` 한정, B/C 미변경). ✅
- **플레이스홀더:** 모든 스텝에 실제 코드/명령/기대출력. 없음. ✅
- **타입 일관성:** `activeGHz: Double?`(T1) ↔ `attaching`/뷰(T4·T5) ↔ `sampleGHz(topology:) -> [Double?]`(T6) ↔ `CPUFrequency.attaching(_:clockGHz:)`(T4) 시그니처 일치. `decodeDVFSTable`/`activeGHz` 인자명 T2·T3와 T6 호출부 일치. ✅
- **경계:** 각 태스크는 독립 테스트 가능 딜리버러블로 종료. 순수 3종(T2–T4)은 유닛테스트, 표시(T5)는 `ghzText` 유닛 + 페이크 눈확인, I/O(T6)는 빌드, 배선(T7)은 전체 green + 실기. ✅
