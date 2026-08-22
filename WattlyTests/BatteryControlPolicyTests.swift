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

    @Test func reconcileBacksOffWhenTheHelperKeepsRejectingTheWrite() {
        // A healthy helper is re-checked every minute...
        #expect(BatteryControlPolicy.reconcileInterval(consecutiveUnsupported: 0) == 60.0)
        // ...but a Mac that will never accept the write must not have its write budget re-armed
        // every minute forever.
        #expect(BatteryControlPolicy.reconcileInterval(consecutiveUnsupported: 1) == 300.0)
        #expect(BatteryControlPolicy.reconcileInterval(consecutiveUnsupported: 3) == 300.0)
        #expect(BatteryControlPolicy.reconcileInterval(consecutiveUnsupported: 4) == 900.0)
        #expect(BatteryControlPolicy.reconcileInterval(consecutiveUnsupported: 99) == 900.0)
    }

    @Test func reassertIsThrottledBecauseItIsNotAStateTransition() {
        // The first re-assert of a process always runs.
        #expect(BatteryControlPolicy.shouldReassert(now: 1_000, lastReassertAt: nil))

        // A caller driving the XPC entry point faster than the floor gets one write, not many.
        #expect(!BatteryControlPolicy.shouldReassert(now: 1_000, lastReassertAt: 1_000))
        #expect(!BatteryControlPolicy.shouldReassert(now: 1_059, lastReassertAt: 1_000))

        // The real callers — a launch, a wake, a settings edit — are far past the floor.
        #expect(BatteryControlPolicy.shouldReassert(now: 1_060, lastReassertAt: 1_000))
        #expect(BatteryControlPolicy.shouldReassert(now: 9_999, lastReassertAt: 1_000))
    }
}
