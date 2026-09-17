import Testing
@testable import Wattly

@Suite struct BatteryControlBackendSelectorTests {
    private let allAbsent: (String) -> BatteryControlKeyProbeResult = { _ in .confirmedAbsent }

    @Test func macOS27ShapeSelectsTheNativeBackend() {
        let backend = BatteryControlBackendSelector.select(
            isRunningTests: false, smcProbe: allAbsent, isNativeSupported: { true })
        #expect(backend == .nativeLimit)
    }

    /// 단위 테스트가 개발자의 실제 시스템 충전 제한을 건드리면 안 된다.
    @Test func theTestHostNeverSelectsTheNativeBackend() {
        let backend = BatteryControlBackendSelector.select(
            isRunningTests: true, smcProbe: allAbsent, isNativeSupported: { true })
        #expect(backend == .smc)
    }

    @Test func aMacThatStillHasARegisterStaysOnTheHelper() {
        var nativeWasAsked = false
        let backend = BatteryControlBackendSelector.select(
            isRunningTests: false,
            smcProbe: { $0 == "CHTE" ? .readable(type: "ui32", size: 4) : .confirmedAbsent },
            isNativeSupported: { nativeWasAsked = true; return true })
        #expect(backend == .smc)
        #expect(nativeWasAsked == false)   // PowerUI는 필요할 때만 올린다
    }

    @Test func anUncertainProbeIsNotProofOfAbsence() {
        let backend = BatteryControlBackendSelector.select(
            isRunningTests: false,
            smcProbe: { $0 == "CH0B" ? .uncertain : .confirmedAbsent },
            isNativeSupported: { true })
        #expect(backend == .smc)
    }

    @Test func noRegisterAndNoPowerUIFallsBackToTheHelperPath() {
        let backend = BatteryControlBackendSelector.select(
            isRunningTests: false, smcProbe: allAbsent, isNativeSupported: { false })
        #expect(backend == .smc)
    }

    @Test func theRunningTestHostIsDetected() {
        #expect(BatteryControlBackendSelector.isRunningTests)
        #expect(BatteryControlBackendSelector.current == .smc)
    }

    // MARK: reader assembly

    @Test func readingScalesCapacityAndTreatsAnyAdapterSignalAsPluggedIn() {
        let onAC = NativeLimitBatteryReader.reading(
            currentCapacity: 80, maxCapacity: 100, isACPower: true,
            externalConnected: true, adapterWatts: 68, instantAmperage: 0)
        #expect(onAC == .init(percentage: 80, isPluggedIn: true, batteryMilliamps: 0))

        let wattsOnly = NativeLimitBatteryReader.reading(
            currentCapacity: 3_000, maxCapacity: 6_000, isACPower: false,
            externalConnected: false, adapterWatts: 68, instantAmperage: -850)
        #expect(wattsOnly == .init(percentage: 50, isPluggedIn: true, batteryMilliamps: -850))

        let onBattery = NativeLimitBatteryReader.reading(
            currentCapacity: 72, maxCapacity: 100, isACPower: false,
            externalConnected: false, adapterWatts: nil, instantAmperage: nil)
        #expect(onBattery == .init(percentage: 72, isPluggedIn: false, batteryMilliamps: nil))
    }

    @Test func readingSurvivesAZeroMaxCapacity() {
        let reading = NativeLimitBatteryReader.reading(
            currentCapacity: 64, maxCapacity: 0, isACPower: true,
            externalConnected: nil, adapterWatts: nil, instantAmperage: nil)
        #expect(reading.percentage == 64)
    }
}
