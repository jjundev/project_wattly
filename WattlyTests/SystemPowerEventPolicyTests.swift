import Testing
@testable import Wattly

@Suite struct SystemPowerEventPolicyTests {
    @Test func canSleepIsImmediatelyAllowedWithoutWork() {
        #expect(SystemPowerEventPolicy.action(for: .canSleep)
            == .init(releaseFans: false, reconcileBattery: false, acknowledge: true))
    }

    @Test func willSleepReleasesOnlyFansAndAcknowledges() {
        #expect(SystemPowerEventPolicy.action(for: .willSleep)
            == .init(releaseFans: true, reconcileBattery: false, acknowledge: true))
    }

    @Test func earlyWakeDoesNotTouchUnavailableHardware() {
        #expect(SystemPowerEventPolicy.action(for: .willPowerOn)
            == .init(releaseFans: false, reconcileBattery: false, acknowledge: false))
    }

    @Test func completedWakeReconcilesOnlyBattery() {
        #expect(SystemPowerEventPolicy.action(for: .hasPoweredOn)
            == .init(releaseFans: false, reconcileBattery: true, acknowledge: false))
    }
}
