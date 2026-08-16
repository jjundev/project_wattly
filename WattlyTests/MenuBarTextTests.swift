import Testing
import Foundation
@testable import Wattly

/// The pure menubar-text assembler (issue 14 §수용 — "조립 문자열 순수 함수 단위 테스트").
/// Pins the per-metric format, the integer-vs-decimal rounding split, the cold-label
/// placeholders, and the canonical-order join — all verbatim from the prototype (663–668).
struct MenuBarTextTests {
    private func cpu(_ v: Double) -> MetricState { .value(.cpu(CPUSample(overall: v, perfLevels: []))) }
    private func power(_ w: Double) -> MetricState { .value(.power(PowerSample(totalW: w, cpuW: 0, gpuW: 0, npuW: 0))) }
    private func mem(_ g: Double) -> MetricState { .value(.memory(MemorySample(usedGB: g, totalGB: 16, wiredGB: 0, compressedGB: 0))) }
    private func temp(cpu: Double? = nil, gpu: Double? = nil) -> MetricState {
        func cat(_ v: Double?) -> CategoryReading { v.map { .reading(TemperatureReading(celsius: $0)) } ?? .notPresent("x") }
        return .value(.temperature(TemperatureSnapshot(cpu: cat(cpu), gpu: cat(gpu))))
    }

    private func battery(netW: Double, charging: Bool, temp: Double? = nil) -> MetricState {
        .value(.battery(BatterySample(netW: netW, milliamps: 1000, volts: 11.5,
                                      charging: charging, externalConnected: charging,
                                      temperatureCelsius: temp)))
    }

    @Test func cpuRoundsToInteger() {
        #expect(MenuBarText.part(.cpu, cpu(42.4)) == "CPU 42%")
        #expect(MenuBarText.part(.cpu, cpu(42.6)) == "CPU 43%")
    }

    @Test func gpuMenuBarText() {
        let sample = GPUSample(overall: 38.4, coreCount: 10, activeGHz: 1.28)
        let text = MenuBarText.part(.gpu, .value(.gpu(sample)))
        #expect(text == "GPU 38%")
    }

    @Test func menuBarOrder() {
        #expect(MenuBarText.order == [.cpu, .gpu, .power, .battery, .mem, .cpuTemp, .gpuTemp, .fan])
    }

    @Test func powerHasNoLabelAndOneDecimal() {
        #expect(MenuBarText.part(.power, power(8.42)) == "8.4 W")
    }

    @Test func memoryIsGBNotOverTotal() {
        #expect(MenuBarText.part(.mem, mem(9.18)) == "9.2 GB")
    }

    @Test func temperaturesUseShortWarmLabelAndInteger() {
        #expect(MenuBarText.part(.cpuTemp, temp(cpu: 54.3)) == "CPU 54°C")
        #expect(MenuBarText.part(.gpuTemp, temp(gpu: 48.7)) == "GPU 49°C")
    }

    @Test func batteryTempMenuBarText() {
        let sample = BatterySample(netW: -5.0, milliamps: 450, volts: 11.2, charging: false, externalConnected: false, temperatureCelsius: 31.4)
        let part = MenuBarText.batteryTempPart(.value(.battery(sample)))
        #expect(part == "배터리 31°C")

        let cold = MenuBarText.batteryTempPart(.loading)
        #expect(cold == "배터리 온도 —")

        let noTemp = BatterySample(netW: -5.0, milliamps: 450, volts: 11.2, charging: false, externalConnected: false, temperatureCelsius: nil)
        #expect(MenuBarText.batteryTempPart(.value(.battery(noTemp))) == "배터리 온도 —")
    }

    @Test func coldUsesLongLabelPlaceholder() {
        #expect(MenuBarText.part(.cpu, .loading) == "CPU —")
        #expect(MenuBarText.part(.gpu, .loading) == "GPU —")
        #expect(MenuBarText.part(.power, .loading) == "전력 —")
        #expect(MenuBarText.part(.mem, .unavailable(.providerError("x"))) == "메모리 —")
        #expect(MenuBarText.part(.cpuTemp, .loading) == "CPU 온도 —")
        #expect(MenuBarText.part(.gpuTemp, .loading) == "GPU 온도 —")
    }

    @Test func assembleJoinsInCanonicalOrderWithMiddleDot() {
        let states: [CardKind: MetricState] = [.cpu: cpu(42), .power: power(8.4), .cpuTemp: temp(cpu: 54)]
        // Selection given out of order; output follows the canonical order cpu·power·…·cpuTemp.
        let s = MenuBarText.assemble(selected: [.cpuTemp, .cpu, .power], states: states)
        #expect(s == "CPU 42%  ·  8.4 W  ·  CPU 54°C")
    }

    @Test func assembleEmptySelectionIsNil() {
        #expect(MenuBarText.assemble(selected: [], states: [:]) == nil)
    }

    @Test func assembleMissingStateFallsBackToCold() {
        // A selected metric with no state entry → treated as loading → its cold placeholder.
        #expect(MenuBarText.assemble(selected: [.cpu], states: [:]) == "CPU —")
    }

    @Test func batteryUsesSignAndOneDecimal() {
        #expect(MenuBarText.part(.battery, battery(netW: 8.42, charging: false)) == "−8.4 W")
        #expect(MenuBarText.part(.battery, battery(netW: 5.0, charging: true)) == "+5.0 W")
    }

    @Test func batterySignDropsNearZero() {
        // #17 rule reused: |net| rounding to 0.0 drops the sign, never a meaningless "−0.0".
        #expect(MenuBarText.part(.battery, battery(netW: 0.02, charging: false)) == "0.0 W")
    }

    @Test func batteryJoinsRightAfterPower() {
        let states: [CardKind: MetricState] = [.power: power(8.4), .battery: battery(netW: 3.0, charging: false)]
        let s = MenuBarText.assemble(selected: [.battery, .power], states: states)
        #expect(s == "8.4 W  ·  −3.0 W")
    }

    @Test func memPressurePartShowsPercent() {
        let st = MetricState.value(.memory(MemorySample(
            usedGB: 9, totalGB: 16, wiredGB: 0, compressedGB: 0, pressurePercent: 46)))
        #expect(MenuBarText.memPressurePart(st) == "압력 46%")
    }

    @Test func memPressurePartColdWhenPercentMissing() {
        let st = MetricState.value(.memory(MemorySample(usedGB: 9, totalGB: 16, wiredGB: 0, compressedGB: 0)))
        #expect(MenuBarText.memPressurePart(st) == "압력 —")
        #expect(MenuBarText.memPressurePart(.loading) == "압력 —")
    }

    @Test func coreClockPartShowsGHzForMatchingCluster() {
        let st = MetricState.value(.cpu(CPUSample(overall: 40, perfLevels: [
            PerfLevelUsage(name: "Super", usage: 30, activeGHz: 3.52),
            PerfLevelUsage(name: "Efficiency", usage: 12, activeGHz: 2.10),
        ])))
        #expect(MenuBarText.coreClockPart("S", st) == "S 3.52 GHz")
        #expect(MenuBarText.coreClockPart("E", st) == "E 2.10 GHz")
    }

    @Test func coreClockPartColdWhenClusterMissing() {
        // Performance/Efficiency (P/E) chip — no "Super" cluster, so selecting S is cold.
        let st = MetricState.value(.cpu(CPUSample(overall: 40, perfLevels: [
            PerfLevelUsage(name: "Performance", usage: 30, activeGHz: 3.0),
            PerfLevelUsage(name: "Efficiency", usage: 12, activeGHz: 2.0),
        ])))
        #expect(MenuBarText.coreClockPart("S", st) == "S 코어 클럭 —")
        #expect(MenuBarText.coreClockPart("P", st) == "P 3.00 GHz")
    }

    @Test func coreClockPartColdWhenGHzUnavailable() {
        let st = MetricState.value(.cpu(CPUSample(overall: 40, perfLevels: [
            PerfLevelUsage(name: "Performance", usage: 30, activeGHz: nil),
        ])))
        #expect(MenuBarText.coreClockPart("P", st) == "P 코어 클럭 —")
    }

    @Test func coreClockPartColdWhenNotCPUState() {
        #expect(MenuBarText.coreClockPart("P", .loading) == "P 코어 클럭 —")
    }
}
