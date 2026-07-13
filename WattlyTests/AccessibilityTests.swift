import Testing
import Foundation
@testable import Wattly

/// The pure VoiceOver-label assembler (issue 15 §메모 — shares #14's assembly logic).
/// Pins the per-card spoken format (symbols per decision B), the loading/unavailable copy,
/// the battery 충전/방전 wording (#7), the folded power breakdown (§5′), and the menubar
/// label that ignores `textEnabled` (§1, decision A).
struct AccessibilityTests {
    // MARK: Sample builders (mirror MenuBarTextTests)

    private func cpu(_ overall: Double) -> MetricState {
        .value(.cpu(CPUSample(overall: overall, perfLevels: [
            PerfLevelUsage(name: "Performance", usage: 30),
            PerfLevelUsage(name: "Efficiency", usage: 12),
        ])))
    }
    private func power(_ w: Double) -> MetricState {
        .value(.power(PowerSample(totalW: w, cpuW: 3, gpuW: 2, npuW: 1)))
    }
    private func mem(_ g: Double) -> MetricState {
        .value(.memory(MemorySample(usedGB: g, totalGB: 16, wiredGB: 1, compressedGB: 0.5)))
    }
    private func battery(netW: Double, charging: Bool) -> MetricState {
        .value(.battery(BatterySample(netW: netW, milliamps: 1000, volts: 11.5,
                                      charging: charging, externalConnected: charging)))
    }
    private func temp(cpu: Double) -> MetricState {
        .value(.temperature(TemperatureSnapshot(
            cpu: .reading(TemperatureReading(celsius: cpu)), gpu: .notPresent("x"), battery: .notPresent("x"))))
    }

    // MARK: Cold / unavailable

    @Test func loadingReadsLoadingWord() {
        #expect(Accessibility.cardLabel(.cpu, .loading) == "CPU, 불러오는 중")
    }

    @Test func unavailableReadsReasonMessage() {
        #expect(Accessibility.cardLabel(.power, .unavailable(.channelUnreadable("에너지 모델 채널 없음")))
                == "프로세서 전력, 사용 불가, 에너지 모델 채널 없음")
    }

    @Test func unavailableTemperatureUsesTerminalReason() {
        #expect(Accessibility.cardLabel(.cpuTemp, .unavailable(.temperature(.noVerifiedProfile)))
                == "CPU 온도, 사용 불가, 검증된 온도 프로파일 없음")
    }

    // MARK: Live values — symbols (decision B)

    @Test func cpuUsesPercentSymbol() {
        #expect(Accessibility.cardLabel(.cpu, cpu(42.4)) == "CPU, 42%, P 30% · E 12%")
    }

    @Test func powerFoldsCpuGpuNpuBreakdown() {
        // The CPU/GPU/NPU split exists ONLY in subText — it must survive into the label.
        #expect(Accessibility.cardLabel(.power, power(8.42))
                == "프로세서 전력, 8.4 W, CPU 3.0 W · GPU 2.0 W · NPU 1.0 W")
    }

    @Test func memoryUsesGBSymbolAndFoldsDetail() {
        #expect(Accessibility.cardLabel(.mem, mem(9.18))
                == "메모리, 9.2 GB, 고정 1.0 GB · 압축 0.5 GB · 스왑 0.0 GB")
    }

    @Test func temperatureUsesDegreeSymbol() {
        #expect(Accessibility.cardLabel(.cpuTemp, temp(cpu: 54.0)) == "CPU 온도, 54.0°C")
    }

    // MARK: Battery sign → 충전/방전 word (#7)

    @Test func batteryDischargingSaysBangjeon() {
        #expect(Accessibility.cardLabel(.battery, battery(netW: 12.3, charging: false))
                .hasPrefix("배터리, 방전 12.3 W"))
    }

    @Test func batteryChargingSaysChungjeon() {
        #expect(Accessibility.cardLabel(.battery, battery(netW: -5.0, charging: true))
                .hasPrefix("배터리, 충전 5.0 W"))
    }

    @Test func batteryZeroNetDropsSignWord() {
        #expect(Accessibility.cardLabel(.battery, battery(netW: 0.0, charging: false))
                .hasPrefix("배터리, 0.0 W"))
    }

    // MARK: State word (warn/crit) — reuses ThresholdLevel.stateWord

    @Test func stateWordCritWarnNormal() {
        let th = Defaults.thresholds   // cpu warn 70 / crit 90
        #expect(Accessibility.stateWord(.cpu, cpu(95), th) == "위험")
        #expect(Accessibility.stateWord(.cpu, cpu(75), th) == "주의")
        #expect(Accessibility.stateWord(.cpu, cpu(40), th) == nil)
    }

    @Test func powerCardHasNoStateWord() {
        #expect(Accessibility.stateWord(.power, power(8.4), Defaults.thresholds) == nil)
    }

    // MARK: Menubar label — ignores textEnabled (§1), empty = "Wattly" (decision A)

    @Test func menuBarLabelEmptySelectionIsWattlyOnly() {
        #expect(Accessibility.menuBarLabel(selected: [], states: [:]) == "Wattly")
    }

    @Test func menuBarLabelPrefixesWattly() {
        let states: [CardKind: MetricState] = [.cpu: cpu(42), .power: power(8.4)]
        #expect(Accessibility.menuBarLabel(selected: [.cpu, .power], states: states)
                == "Wattly, CPU 42%  ·  8.4 W")
    }
}
