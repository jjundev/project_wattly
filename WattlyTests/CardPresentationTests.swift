import Testing
import Foundation
@testable import Wattly

/// Characterization tests for the pure card-presentation seam (issue: deepen the
/// shallow `MetricCardView`). These pin the *current* rendered strings/units/sign
/// rules so the extraction from the view is provably behavior-preserving — they
/// cross the `CardPresentation` interface directly, with no SwiftUI.
struct CardPresentationTests {

    // The displayed minus is U+2212 (MINUS SIGN), not an ASCII hyphen.
    private let minus = "\u{2212}"

    // MARK: Battery sign rule (#17) — one home, shared by value + sub-line

    @Test func batterySignDropsAtZeroMagnitude() {
        #expect(CardPresentation.batterySign(netW: 12.0, charging: false) == minus)   // discharging
        #expect(CardPresentation.batterySign(netW: -30.0, charging: true) == "+")     // charging
        #expect(CardPresentation.batterySign(netW: 0.0, charging: false) == "")       // exact zero → no sign
        #expect(CardPresentation.batterySign(netW: 0.03, charging: false) == "")      // |x| < 0.05 → no sign
        #expect(CardPresentation.batterySign(netW: 0.05, charging: false) == minus)   // boundary: not < 0.05 → sign
    }

    @Test func batteryValueAndSub() {
        let charging = MetricState.value(.battery(BatterySample(
            netW: -30.0, milliamps: 2362, volts: 12.7, charging: true, externalConnected: true)))
        #expect(CardPresentation.valueText(.battery, charging) == "+30.0")
        #expect(CardPresentation.unitText(.battery, charging) == "W")
        #expect(CardPresentation.subText(charging) == "+2362 mA · 12.7 V · 충전 중")

        let discharging = MetricState.value(.battery(BatterySample(
            netW: 12.0, milliamps: 944, volts: 12.7, charging: false, externalConnected: false,
            average1mW: 10.4)))
        #expect(CardPresentation.valueText(.battery, discharging) == "\(minus)12.0")
        #expect(CardPresentation.subText(discharging) == "−944 mA · 12.7 V · 방전 중 · 1분 평균 10.4 W")

        let zero = MetricState.value(.battery(BatterySample(
            netW: 0.0, milliamps: 0, volts: 12.7, charging: false, externalConnected: true)))
        #expect(CardPresentation.valueText(.battery, zero) == "0.0")
        #expect(CardPresentation.subText(zero) == "0 mA · 12.7 V · 방전 중")
    }

    // MARK: CPU

    @Test func cpuValueRoundsAndSub() {
        let twoLevels = MetricState.value(.cpu(CPUSample(overall: 42.4, perfLevels: [
            PerfLevelUsage(name: "Performance", usage: 80.4),
            PerfLevelUsage(name: "Efficiency", usage: 12.6),
        ])))
        #expect(CardPresentation.valueText(.cpu, twoLevels) == "42")           // 42.4 → 42
        #expect(CardPresentation.unitText(.cpu, twoLevels) == "%")
        #expect(CardPresentation.subText(twoLevels) == "P 80% · E 13%")        // order-based prefixes

        let up = MetricState.value(.cpu(CPUSample(overall: 42.6, perfLevels: [])))
        #expect(CardPresentation.valueText(.cpu, up) == "43")                  // 42.6 → 43

        let single = MetricState.value(.cpu(CPUSample(overall: 50, perfLevels: [
            PerfLevelUsage(name: "Super", usage: 50.0)])))
        #expect(CardPresentation.subText(single) == "S 50%")                   // <2 levels → single

        let none = MetricState.value(.cpu(CPUSample(overall: 50, perfLevels: [])))
        #expect(CardPresentation.subText(none) == nil)                         // no levels → nil
    }

    // MARK: Memory — the one state-dependent unit ("/ N GB")

    @Test func memoryValueUnitSub() {
        let st = MetricState.value(.memory(MemorySample(
            usedGB: 8.37, totalGB: 16, wiredGB: 3.21, compressedGB: 1.05)))
        #expect(CardPresentation.valueText(.mem, st) == "8.4")
        #expect(CardPresentation.unitText(.mem, st) == "/ 16 GB")             // reads total off state
        #expect(CardPresentation.subText(st) == "고정 3.2 GB · 압축 1.1 GB · 스왑 0.0 GB")
        #expect(CardPresentation.unitText(.mem, .loading) == "GB")           // no value → bare unit
    }

    @Test func memorySubShowsSwapSize() {
        // The swap segment reflects swapUsedGB and uses the same one-decimal GB format.
        let st = MetricState.value(.memory(MemorySample(
            usedGB: 12.0, totalGB: 16, wiredGB: 3.21, compressedGB: 1.05, swapUsedGB: 5.0)))
        #expect(CardPresentation.subText(st) == "고정 3.2 GB · 압축 1.1 GB · 스왑 5.0 GB")
    }

    // MARK: Power — the only accented card

    @Test func powerValueSubAndTint() {
        let st = MetricState.value(.power(PowerSample(totalW: 12.34, cpuW: 5.62, gpuW: 2.10, npuW: 0.30)))
        #expect(CardPresentation.valueText(.power, st) == "12.3")
        #expect(CardPresentation.subText(st) == "CPU 5.6 W · GPU 2.1 W · NPU 0.3 W")
        #expect(CardPresentation.display(.power, st).tint == .accent)
        #expect(CardPresentation.display(.cpu, .loading).tint == .neutral)
    }

    // MARK: Temperature fan-out — value per category, defensive "—"

    @Test func temperatureValuePerCategory() {
        let snap = TemperatureSnapshot(
            cpu: .reading(TemperatureReading(celsius: 58.7)),
            gpu: .reading(TemperatureReading(celsius: 44.2)),
            battery: .reading(TemperatureReading(celsius: 31.0)))
        let st = MetricState.value(.temperature(snap))
        #expect(CardPresentation.valueText(.cpuTemp, st) == "58.7")
        #expect(CardPresentation.valueText(.gpuTemp, st) == "44.2")
        #expect(CardPresentation.valueText(.batTemp, st) == "31.0")
        #expect(CardPresentation.unitText(.cpuTemp, st) == "°C")
        #expect(CardPresentation.subText(st) == nil)

        let degraded = MetricState.value(.temperature(TemperatureSnapshot(
            cpu: .unavailable(.noVerifiedProfile),
            gpu: .reading(TemperatureReading(celsius: 44.2)),
            battery: .notPresent("x"))))
        #expect(CardPresentation.valueText(.cpuTemp, degraded) == "—")        // defends a non-reading category
    }

    // MARK: display() is total over MetricState (so MenuBarLabel etc. are safe)

    @Test func totalOverLoadingAndUnavailable() {
        let loading = CardPresentation.display(.cpu, .loading)
        #expect(loading.valueText == "—")
        #expect(loading.unitText == "%")
        #expect(loading.subText == nil)
        #expect(loading.label == "CPU")

        let unavailable = CardPresentation.display(.power, .unavailable(.channelUnreadable("x")))
        #expect(unavailable.valueText == "—")
        #expect(unavailable.label == "프로세서 전력")
        #expect(unavailable.tint == .accent)
    }

    // MARK: Labels (shared with the in-view unavailable cards)

    @Test func labels() {
        #expect(CardPresentation.label(.power) == "프로세서 전력")
        #expect(CardPresentation.label(.battery) == "배터리")
        #expect(CardPresentation.label(.cpu) == "CPU")
        #expect(CardPresentation.label(.mem) == "메모리")
        #expect(CardPresentation.label(.cpuTemp) == "CPU 온도")
        #expect(CardPresentation.label(.gpuTemp) == "GPU 온도")
        #expect(CardPresentation.label(.batTemp) == "배터리 온도")
    }

    // MARK: Relocated pure helpers (expand regions)

    @Test func formatHelpers() {
        #expect(CardPresentation.f1(2.5) == "2.5")
        #expect(CardPresentation.f1(0.0) == "0.0")
        #expect(CardPresentation.corePrefix("Performance") == "P")
        #expect(CardPresentation.corePrefix("efficiency") == "E")
        #expect(CardPresentation.corePrefix("") == "C")
        #expect(CardPresentation.gbText(1_610_612_736) == "1.5 GB")   // 1.5 GiB
        #expect(CardPresentation.gbText(1_073_741_824) == "1.0 GB")   // 1.0 GiB
        #expect(CardPresentation.tempBarFraction(55.0) == 0.5)        // 55/110
        #expect(CardPresentation.tempBarFraction(220.0) == 1.0)       // clamped high
        #expect(CardPresentation.tempBarFraction(-5.0) == 0.0)        // clamped low
        #expect(CardPresentation.clusterSummary(average: 55.0, hottest: 60.0) == "55.0° · 최고 60.0°")
    }

    // MARK: CardKind structural facts (D) — single home for the card-family flags

    @Test func cardKindStructuralFlags() {
        #expect(CardKind.allCases.filter(\.isExpandable) == [.power, .cpu, .mem, .cpuTemp])
        #expect(CardKind.allCases.filter(\.hasSparkArea) == [.power, .cpu, .mem, .cpuTemp, .gpuTemp, .batTemp])
        #expect(CardKind.allCases.filter(\.isAccented) == [.power])
    }
}
