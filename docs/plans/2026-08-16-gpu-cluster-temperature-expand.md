# GPU 클러스터 온도 펼치기(Expand) 뷰 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** GPU 온도 카드(`gpuTemp`)에 펼치기(Expand) 기능을 추가하여, Apple Silicon GPU의 2개 코어 복합체 다이 센서군을 "GPU 클러스터 1" 및 "GPU 클러스터 2"로 나누어 평균 및 최고 온도를 확인할 수 있도록 지원한다.

**Architecture:** 
1. `Temperature.swift`의 Apple M5 프로필에서 단일 `GPU` 키 그룹으로 묶여 있던 23개 `Tg*` 다이 센서를 `Tg0*`(13개)과 `Tg1*`(10개)으로 분리하여 `GPU 클러스터 1`, `GPU 클러스터 2` `TemperatureKeyGroup`으로 재구성한다.
2. `CardKind.swift`의 `isExpandable`에 `.gpuTemp`를 포함하여 UI 상에서 탭 및 셰브론이 활성화되도록 한다.
3. `CardExpandRegion.swift`에서 `card == .gpuTemp` 상태일 때 GPU의 클러스터 그룹(`s.gpu.reading.groups`)을 렌더링하고, 길어진 클러스터 레이블 폭에 맞춰 `tempGroupRow`의 레이아웃을 정돈한다.
4. `FakeProvider.swift`와 단위 테스트(`TemperatureTests`, `CardPresentationTests` 등)를 갱신하여 회귀를 방지한다.

**Tech Stack:** Swift 6, SwiftUI, IOKit / AppleSMC, Swift Testing (`Testing`)

## Global Constraints

- Swift 6 strict concurrency (`Sendable`, `@MainActor`, `actor` 경계 준수)
- Zero unverified SMC I/O (프로필 기반 접근 유지)
- 순수 로직/포매터와 뷰 계층의 엄격한 분리 (`CardPresentation`, `Temperature`는 순수 함수로 유지)
- 기존 CPU 온도 카드(`P-코어`, `E-코어`) 및 팬 카드 등 다른 카드의 시각적 정렬과 일관성 유지

---

### Task 1: TemperatureProfile GPU 센서 그룹 분리 (M5: GPU 클러스터 1 & 2)

**Files:**
- Modify: `Wattly/Core/Temperature.swift:24-69`
- Test: `WattlyTests/TemperatureTests.swift:83-100`

**Interfaces:**
- Consumes: `TemperatureKeyGroup`, `TemperatureProfile`, `TemperatureProfiles`
- Produces: `TemperatureProfiles.m5.gpuGroups` containing `[TemperatureKeyGroup(name: "GPU 클러스터 1", ...), TemperatureKeyGroup(name: "GPU 클러스터 2", ...)]`

- [ ] **Step 1: Write the failing test in TemperatureTests.swift**

```swift
    // In WattlyTests/TemperatureTests.swift
    @Test func buildsClusterGroupsWithAverageAndHottest() async {
        let tx = FakeTempTransport()
        tx.keyValues = ["Tp00": 80, "Tp0X": 90,   // P-코어 → avg 85, hottest 90
                        "Te04": 60, "Te08": 70,   // E-코어 → avg 65, hottest 70
                        "Tg04": 50, "Tg0C": 60,   // GPU 클러스터 1 → avg 55, hottest 60
                        "Tg12": 70, "Tg1s": 80]   // GPU 클러스터 2 → avg 75, hottest 80
        let p = TemperatureProvider(transport: tx, model: "Mac17,2")
        let snap = await readSnapshot(p, at: base)

        guard case .reading(let cpu) = snap.cpu else { Issue.record("cpu should read"); return }
        #expect(cpu.celsius == 75)            // headline = mean of all CPU sensors (80+90+60+70)/4
        #expect(cpu.groups == [TemperatureGroup(name: "P-코어", average: 85, hottest: 90),
                               TemperatureGroup(name: "E-코어", average: 65, hottest: 70)])

        guard case .reading(let gpu) = snap.gpu else { Issue.record("gpu should read"); return }
        #expect(gpu.celsius == 65)            // headline = mean of all GPU sensors (50+60+70+80)/4
        #expect(gpu.groups == [TemperatureGroup(name: "GPU 클러스터 1", average: 55, hottest: 60),
                               TemperatureGroup(name: "GPU 클러스터 2", average: 75, hottest: 80)])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TemperatureTests/buildsClusterGroupsWithAverageAndHottest`
Expected: FAIL — `gpu.groups` currently contains `[TemperatureGroup(name: "GPU", ...)]`.

- [ ] **Step 3: Update Temperature.swift with split GPU clusters and updated doc comments**

```swift
// In Wattly/Core/Temperature.swift around lines 55-61:
        gpuGroups: [
            TemperatureKeyGroup(name: "GPU 클러스터 1",
                keys: ["Tg04", "Tg0C", "Tg0G", "Tg0K", "Tg0O", "Tg0R", "Tg0U", "Tg0X",
                       "Tg0d", "Tg0g", "Tg0j", "Tg0m", "Tg0p"]),
            TemperatureKeyGroup(name: "GPU 클러스터 2",
                keys: ["Tg12", "Tg16", "Tg1A", "Tg1I", "Tg1M", "Tg1Y", "Tg1c",
                       "Tg1g", "Tg1o", "Tg1s"]),
        ],
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TemperatureTests/buildsClusterGroupsWithAverageAndHottest`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/Temperature.swift WattlyTests/TemperatureTests.swift
git commit -m "feat(temp): split GPU die sensors into Cluster 1 and Cluster 2 groups"
```

---

### Task 2: CardKind isExpandable에 gpuTemp 추가 및 테스트 갱신

**Files:**
- Modify: `Wattly/Models/CardKind.swift:31-34`
- Test: `WattlyTests/CardPresentationTests.swift:373-376`

**Interfaces:**
- Consumes: `CardKind.gpuTemp`
- Produces: `CardKind.gpuTemp.isExpandable == true`

- [ ] **Step 1: Write the failing test in CardPresentationTests.swift**

```swift
// In WattlyTests/CardPresentationTests.swift:374:
#expect(CardKind.allCases.filter(\.isExpandable) == [.power, .battery, .cpu, .mem, .cpuTemp, .gpuTemp, .fan])
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CardPresentationTests`
Expected: FAIL — `.gpuTemp` not in `isExpandable`.

- [ ] **Step 3: Update CardKind.isExpandable**

```swift
// In Wattly/Models/CardKind.swift:31-34
    var isExpandable: Bool {
        self == .power || self == .battery || self == .cpu || self == .mem || self == .cpuTemp || self == .gpuTemp || self == .fan
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CardPresentationTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Models/CardKind.swift WattlyTests/CardPresentationTests.swift
git commit -m "feat(cards): mark gpuTemp as expandable"
```

---

### Task 3: CardExpandRegion에 GPU 온도 상세 뷰 연결 및 UI 폭 최적화

**Files:**
- Modify: `Wattly/Views/CardExpandRegion.swift:28-33, 250-274`
- Modify: `Wattly/Providers/FakeProvider.swift:135-142`

**Interfaces:**
- Consumes: `state == .value(.temperature(let s))`, `case .reading(let r) = s.gpu`, `r.groups`
- Produces: GPU temperature expanded rows with labels and average/hottest metrics.

- [ ] **Step 1: Update CardExpandRegion.swift body**

```swift
// In Wattly/Views/CardExpandRegion.swift lines 28-33:
        } else if card == .cpuTemp, case .value(.temperature(let s)) = state, case .reading(let r) = s.cpu {
            tempExpand(r.groups)
        } else if card == .gpuTemp, case .value(.temperature(let s)) = state, case .reading(let r) = s.gpu {
            tempExpand(r.groups)
        } else if card == .fan, case .value(.fan(let s)) = state {
```

- [ ] **Step 2: Adjust tempGroupRow label frame in CardExpandRegion.swift**

```swift
// In Wattly/Views/CardExpandRegion.swift lines 250-270:
    private func tempGroupRow(_ g: TemperatureGroup) -> some View {
        HStack(spacing: 9) {
            Text(g.name)
                .font(WattlyFont.at(10.5, weight: .semibold))
                .foregroundStyle(t.faint)
                .frame(width: 78, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(t.sparkFill)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(t.spark)
                        .frame(width: geo.size.width * CardPresentation.tempBarFraction(g.average))
                }
            }
            .frame(height: 6)
            Text(CardPresentation.clusterSummary(average: g.average, hottest: g.hottest))
                .font(WattlyFont.at(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(t.sub)
                .frame(width: 104, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(g.name), 평균 \(CardPresentation.f1(g.average))도, 최고 \(CardPresentation.f1(g.hottest))도")
    }
```

- [ ] **Step 3: Update FakeProvider.swift to supply GPU cluster mock groups**

```swift
// In Wattly/Providers/FakeProvider.swift around lines 135-142:
            let g = v("gpuTemp")
            let gpu = CategoryReading.reading(TemperatureReading(
                celsius: g,
                groups: [
                    TemperatureGroup(name: "GPU 클러스터 1", average: g - 0.4, hottest: g + 0.3),
                    TemperatureGroup(name: "GPU 클러스터 2", average: g + 0.2, hottest: g + 0.7),
                ]
            ))
```

- [ ] **Step 4: Build and test entire project**

Run: `swift test`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Views/CardExpandRegion.swift Wattly/Providers/FakeProvider.swift
git commit -m "feat(ui): render GPU cluster 1 and 2 in temperature expand region"
```

---

## Verification Plan

### Automated Tests
- `swift test --filter TemperatureTests` (SMC 센서 그룹핑 및 클러스터 평균/최고 온도 검증)
- `swift test --filter CardPresentationTests` (isExpandable 및 텍스트 렌더링 검증)
- `swift test` (전체 유닛 테스트 통과 확인)

### Manual Verification
- Wattly 앱 실행 후 팝오버에서 GPU 온도 카드를 클릭하여 셰브론 회전 및 `GPU 클러스터 1`, `GPU 클러스터 2` 두 줄이 정상 출력되는지 확인.
- Metal 부하 또는 그래픽 작업 시 각 클러스터의 평균 및 최고 온도가 실시간으로 자연스럽게 변동하는지 확인.
