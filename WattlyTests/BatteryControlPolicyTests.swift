import Foundation
import Testing
@testable import Wattly

@Suite struct BatteryControlPolicyTests {
    private func status(mode: BatteryControlServiceMode, applied: Int?) -> BatteryControlServiceStatus {
        BatteryControlServiceStatus(
            mode: mode,
            currentPercentage: 70,
            isPowerAdapterConnected: true,
            detail: "테스트",
            updatedAt: 0,
            appliedLimitPercentage: applied
        )
    }

    @Test func reapplyWhenHelperRestartedAndForgotTheLimit() {
        // A KeepAlive relaunch brings the helper back with an empty configuration.
        let forgotten = status(mode: .charging, applied: nil)
        #expect(BatteryControlPolicy.shouldReapply(enabled: true, limitPercentage: 85, status: forgotten))
    }

    @Test func reapplyWhenHelperHoldsADifferentLimit() {
        let stale = status(mode: .charging, applied: 80)
        #expect(BatteryControlPolicy.shouldReapply(enabled: true, limitPercentage: 85, status: stale))
    }

    @Test func doNotReapplyWhenHelperAlreadyAgrees() {
        #expect(!BatteryControlPolicy.shouldReapply(enabled: true, limitPercentage: 85,
                                                    status: status(mode: .charging, applied: 85)))
        #expect(!BatteryControlPolicy.shouldReapply(enabled: true, limitPercentage: 85,
                                                    status: status(mode: .inhibited, applied: 85)))
    }

    @Test func doNotReapplyWhenTheUserOptedOut() {
        #expect(!BatteryControlPolicy.shouldReapply(enabled: false, limitPercentage: 85,
                                                    status: status(mode: .charging, applied: nil)))
    }

    @Test func doNotReapplyIntoAnUnreachableHelper() {
        // Connecting or installing is the settings screen's job, not a background loop's.
        #expect(!BatteryControlPolicy.shouldReapply(enabled: true, limitPercentage: 85,
                                                    status: status(mode: .unavailable, applied: nil)))
    }

    @Test func reapplyEvenWhenTheHardwareRejectedTheWrite() {
        // `.unsupported` still means the helper is answering; re-pushing is how a transient
        // failure gets another chance.
        #expect(BatteryControlPolicy.shouldReapply(enabled: true, limitPercentage: 85,
                                                   status: status(mode: .unsupported, applied: nil)))
    }

    @Test func installerRunsOnlyWhenTheHelperIsUnreachable() {
        #expect(BatteryControlPolicy.shouldRunInstaller(mode: .unavailable))
        #expect(!BatteryControlPolicy.shouldRunInstaller(mode: .charging))
        #expect(!BatteryControlPolicy.shouldRunInstaller(mode: .inhibited))
        #expect(!BatteryControlPolicy.shouldRunInstaller(mode: .unsupported))
    }

    @Test func reconcileIntervalIsSlowEnoughToBeFree() {
        #expect(BatteryControlPolicy.reconcileInterval >= 60.0)
    }
}
