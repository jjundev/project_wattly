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
    private func temp(cpu: Double? = nil, gpu: Double? = nil, bat: Double? = nil) -> MetricState {
        func cat(_ v: Double?) -> CategoryReading { v.map { .reading(TemperatureReading(celsius: $0)) } ?? .notPresent("x") }
        return .value(.temperature(TemperatureSnapshot(cpu: cat(cpu), gpu: cat(gpu), battery: cat(bat))))
    }

    @Test func cpuRoundsToInteger() {
        #expect(MenuBarText.part(.cpu, cpu(42.4)) == "CPU 42%")
        #expect(MenuBarText.part(.cpu, cpu(42.6)) == "CPU 43%")
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
        #expect(MenuBarText.part(.batTemp, temp(bat: 31.2)) == "배터리 31°C")
    }

    @Test func coldUsesLongLabelPlaceholder() {
        #expect(MenuBarText.part(.cpu, .loading) == "CPU —")
        #expect(MenuBarText.part(.power, .loading) == "전력 —")
        #expect(MenuBarText.part(.mem, .unavailable(.providerError("x"))) == "메모리 —")
        #expect(MenuBarText.part(.cpuTemp, .loading) == "CPU 온도 —")
        #expect(MenuBarText.part(.gpuTemp, .loading) == "GPU 온도 —")
        #expect(MenuBarText.part(.batTemp, .loading) == "배터리 온도 —")
    }

    @Test func desktopBatteryTempIsUnavailablePlaceholder() {
        // batTemp fans out to `.unavailable(.notPresent)` on a desktop → "배터리 온도 —".
        #expect(MenuBarText.part(.batTemp, .unavailable(.notPresent("배터리 없음"))) == "배터리 온도 —")
    }

    @Test func assembleJoinsInCanonicalOrderWithMiddleDot() {
        let states: [CardKind: MetricState] = [.cpu: cpu(42), .power: power(8.4), .batTemp: temp(bat: 31)]
        // Selection given out of order; output follows the canonical order cpu·power·…·batTemp.
        let s = MenuBarText.assemble(selected: [.batTemp, .cpu, .power], states: states)
        #expect(s == "CPU 42%  ·  8.4 W  ·  배터리 31°C")
    }

    @Test func assembleEmptySelectionIsNil() {
        #expect(MenuBarText.assemble(selected: [], states: [:]) == nil)
    }

    @Test func assembleMissingStateFallsBackToCold() {
        // A selected metric with no state entry → treated as loading → its cold placeholder.
        #expect(MenuBarText.assemble(selected: [.cpu], states: [:]) == "CPU —")
    }
}
