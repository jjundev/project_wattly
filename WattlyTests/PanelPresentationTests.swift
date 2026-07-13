import Testing
import Foundation
@testable import Wattly

/// Pure-seam tests for the mode-C compact list-row text (plan 20). `compactRowText` is total over
/// `MetricState` and reuses `valueText`/`unitText`, so units — including the battery-temperature
/// `°C` the prototype `rowOf` (lines 677–682) dropped to `W` — and the battery sign (#17) stay
/// correct and in step with the cards. CPU joins its `%` tight; every other unit is spaced.
struct PanelPresentationTests {

    // The displayed minus is U+2212 (MINUS SIGN), not an ASCII hyphen.
    private let minus = "\u{2212}"

    @Test func powerRowIsWatts() {
        let s = MetricState.value(.power(PowerSample(totalW: 8.4, cpuW: 3.1, gpuW: 2.0, npuW: 0.2)))
        #expect(CardPresentation.compactRowText(.power, s) == "8.4 W")
    }

    @Test func batteryRowCarriesSign() {
        let s = MetricState.value(.battery(BatterySample(
            netW: 11.3, milliamps: 900, volts: 12.0, charging: false, externalConnected: false)))
        #expect(CardPresentation.compactRowText(.battery, s) == "\(minus)11.3 W")
    }

    @Test func cpuRowJoinsPercentTight() {
        let s = MetricState.value(.cpu(CPUSample(overall: 42.0, perfLevels: [])))
        #expect(CardPresentation.compactRowText(.cpu, s) == "42%")
    }

    @Test func memoryRowKeepsTotalUnit() {
        let s = MetricState.value(.memory(MemorySample(
            usedGB: 9.2, totalGB: 16, wiredGB: 3, compressedGB: 1)))
        #expect(CardPresentation.compactRowText(.mem, s) == "9.2 / 16 GB")
    }

    @Test func batteryTemperatureRowIsCelsius() {
        // The prototype rowOf rendered batTemp as "W" (fall-through bug); reusing unitText → "°C".
        let snap = TemperatureSnapshot(
            cpu: .notPresent("x"),
            gpu: .notPresent("x"),
            battery: .reading(TemperatureReading(celsius: 31.5)))
        let s = MetricState.value(.temperature(snap))
        #expect(CardPresentation.compactRowText(.batTemp, s) == "31.5 °C")
    }

    @Test func loadingRowIsDash() {
        #expect(CardPresentation.compactRowText(.power, .loading) == "—")
    }

    @Test func unavailableRowIsShortReason() {
        let s = MetricState.unavailable(.channelUnreadable("Energy Model 그룹을 읽을 수 없음"))
        #expect(CardPresentation.compactRowText(.power, s) == "읽기 불가")
    }

    @Test func automaticPollingCopyMatchesProviderBudget() {
        #expect(automaticPollingDescription ==
            "자동: 패널 열림은 CPU·전력 1초/온도 2초/메모리·배터리 5초, 닫힘은 메뉴바에 표시한 지표만 2초마다 갱신합니다. 텍스트를 끄면 지표 폴링을 멈춥니다.")
    }
}
