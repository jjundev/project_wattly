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

    @Test func automaticEcoPollingCopyMatchesProviderBudget() {
        #expect(pollingDescription(for: .auto, mode: .eco) ==
            "자동 · 절전: 패널을 열면 CPU·전력은 1초, 온도는 2초, 메모리·배터리는 5초마다 갱신합니다. 패널을 닫으면 메뉴바에 표시한 지표만 2초마다 갱신하며, 메뉴바 텍스트를 끄면 지표 갱신을 멈춥니다.")
    }

    @Test func automaticAlwaysLatestPollingCopyMatchesProviderBudget() {
        #expect(pollingDescription(for: .auto, mode: .performance) ==
            "자동 · 항상 최신: 패널을 열면 활성 지표를 1초마다 갱신합니다. 패널을 닫으면 메뉴바 텍스트 표시 시 2초마다, 끄면 5초마다 갱신합니다.")
    }

    @Test func fixedPollingCopyNamesTheSelectedInterval() {
        #expect(pollingDescription(for: .s1, mode: .eco) == "패널 상태와 관계없이 활성 지표를 1초마다 갱신합니다.")
        #expect(pollingDescription(for: .s2, mode: .performance) == "패널 상태와 관계없이 활성 지표를 2초마다 갱신합니다.")
        #expect(pollingDescription(for: .s5, mode: .eco) == "패널 상태와 관계없이 활성 지표를 5초마다 갱신합니다.")
    }
}
