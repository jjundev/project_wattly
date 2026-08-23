import Darwin
import Foundation
import Testing
@testable import Wattly

final class PolicyStoreSpy: BatteryPolicyStoring, @unchecked Sendable {
    var stored: PersistedBatteryPolicy?
    var events: [String] = []
    var saveError: Error?
    var loadError: Error?
    var onSave: (() -> Void)?

    func load() throws -> PersistedBatteryPolicy? {
        if let loadError { throw loadError }
        events.append("load")
        return stored
    }

    func save(_ policy: PersistedBatteryPolicy) throws {
        events.append("save")
        onSave?()
        if let saveError { throw saveError }
        stored = policy
    }

    func remove() throws {
        events.append("remove")
        stored = nil
    }
}

struct BatteryControlCoordinatorTests {
    @Test func configurePersistsBeforeTheFirstHardwareWrite() {
        final class OrderedEvents: @unchecked Sendable {
            var values: [String] = []
        }
        let ordered = OrderedEvents()
        let hardware = MockBatteryHardware()
        hardware.onWrite = { ordered.values.append("write") }
        let store = PolicyStoreSpy()
        store.onSave = { ordered.values.append("save") }
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })

        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80),
            trigger: .clientConfiguration,
            currentSoC: 80,
            isPluggedIn: true)

        #expect(Array(ordered.values.prefix(2)) == ["save", "write"])
    }

    @Test func startupRestoresMatchingOwnerPolicyWithoutTheApp() {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
        let store = PolicyStoreSpy()
        store.stored = .init(
            ownerUID: 501,
            configuration: .init(enabled: true, limitPercentage: 85),
            updatedAt: 10)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })

        let status = coordinator.restore(currentSoC: 84, isPluggedIn: true)

        #expect(status.desiredConfiguration?.enabled == true)
        #expect(status.mode == .inhibited)
        #expect(status.lastMaintenance?.trigger == .startup)
    }

    @Test func wrongOwnerFailsSafeToDisabledAndVerifiedRelease() {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
        hardware.chargingInhibited = true
        let store = PolicyStoreSpy()
        store.stored = .init(
            ownerUID: 502,
            configuration: .init(enabled: true, limitPercentage: 80),
            updatedAt: 10)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })

        let status = coordinator.restore(currentSoC: 80, isPluggedIn: true)

        #expect(status.desiredConfiguration?.enabled == false)
        #expect(status.lastMaintenance?.reason?.kind == .policyOwnerMismatch)
        #expect(hardware.chargingInhibited == false)
    }

    @Test func missingPolicyUsesDedicatedFirmwareManagedRelease() {
        let hardware = MockBatteryHardware()
        hardware.registerSet = .firmwareManaged
        hardware.releaseVerdict = .verifiedAllowed
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: PolicyStoreSpy(),
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })

        let status = coordinator.restore(currentSoC: 80, isPluggedIn: true)

        #expect(hardware.readCount == 0)
        #expect(hardware.writeCount == 0)
        #expect(hardware.releaseAttemptCount == 1)
        #expect(status.desiredConfiguration?.enabled == false)
        #expect(status.releaseVerdict == .verifiedAllowed)
        #expect(status.actualGate == .allowed)
        #expect(status.lastMaintenance?.result == .released)
    }

    @Test func storedDisabledPolicyUsesDedicatedFirmwareManagedRelease() {
        let hardware = MockBatteryHardware()
        hardware.registerSet = .firmwareManaged
        hardware.releaseVerdict = .notControllable
        let store = PolicyStoreSpy()
        store.stored = .init(
            ownerUID: 501,
            configuration: .init(enabled: false, limitPercentage: 80),
            updatedAt: 10)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })

        let status = coordinator.restore(currentSoC: 80, isPluggedIn: true)

        #expect(hardware.readCount == 0)
        #expect(hardware.writeCount == 0)
        #expect(hardware.releaseAttemptCount == 1)
        #expect(status.releaseVerdict == .notControllable)
        #expect(status.actualGate == .unreadable)
        #expect(status.lastMaintenance?.result == .released)
    }

    @Test func missingPolicyReportsDedicatedReleaseFailure() {
        let hardware = MockBatteryHardware()
        hardware.registerSet = .firmwareManaged
        hardware.releaseVerdict = .failed
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: PolicyStoreSpy(),
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })

        let status = coordinator.restore(currentSoC: 80, isPluggedIn: true)

        #expect(hardware.releaseAttemptCount == 1)
        #expect(status.releaseVerdict == .failed)
        #expect(status.lastMaintenance?.result == .failed)
        #expect(status.lastMaintenance?.reason?.kind == .releaseFailed)
    }

    @Test func wrongOwnerPreservesOwnershipFailureWhenDedicatedReleaseFails() {
        let hardware = MockBatteryHardware()
        hardware.registerSet = .firmwareManaged
        hardware.releaseVerdict = .failed
        let store = PolicyStoreSpy()
        store.stored = .init(
            ownerUID: 502,
            configuration: .init(enabled: true, limitPercentage: 80),
            updatedAt: 10)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })

        let status = coordinator.restore(currentSoC: 80, isPluggedIn: true)

        #expect(hardware.readCount == 0)
        #expect(hardware.writeCount == 0)
        #expect(hardware.releaseAttemptCount == 1)
        #expect(status.releaseVerdict == .failed)
        #expect(status.lastMaintenance?.result == .failed)
        #expect(status.lastMaintenance?.reason?.kind == .policyOwnerMismatch)
    }

    @Test func startupWithoutPowerReadingPreservesAReadableEnabledHold() {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
        hardware.chargingInhibited = true
        let store = PolicyStoreSpy()
        store.stored = .init(
            ownerUID: 501,
            configuration: .init(enabled: true, limitPercentage: 85),
            updatedAt: 10)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })

        let status = coordinator.restoreWithoutPowerReading()

        #expect(status.desiredConfiguration?.enabled == true)
        #expect(status.actualGate?.state == .inhibited)
        #expect(hardware.writeCount == 0)
        #expect(status.detailReason?.kind == .powerSourceUnreadable)
    }

    @Test func disabledConfigureRequiresVerifiedRelease() {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
        hardware.chargingInhibited = true
        hardware.releaseVerdict = .failed
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: PolicyStoreSpy(),
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })

        let status = coordinator.configure(
            .init(enabled: false, limitPercentage: 80),
            trigger: .clientConfiguration,
            currentSoC: 80,
            isPluggedIn: true)

        #expect(hardware.releaseAttemptCount == 1)
        #expect(status.releaseVerdict == .failed)
        #expect(status.actualGate != .allowed)
        #expect(status.lastMaintenance?.result == .failed)
        #expect(status.lastMaintenance?.reason?.kind == .releaseFailed)
    }

    @Test func enabledConfigureWithoutPowerReadingPersistsAndPreservesExistingHold() {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
        hardware.chargingInhibited = true
        let store = PolicyStoreSpy()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })

        let status = coordinator.configureWithoutPowerReading(
            .init(enabled: true, limitPercentage: 145, lowerHysteresisDelta: 0),
            trigger: .clientConfiguration)

        #expect(store.stored?.configuration == .init(
            enabled: true, limitPercentage: 100, lowerHysteresisDelta: 1))
        #expect(hardware.writeCount == 0)
        #expect(hardware.releaseAttemptCount == 0)
        #expect(status.actualGate == .inhibited(appliedLimitPercentage: nil))
        #expect(status.detailReason?.kind == .powerSourceUnreadable)
        #expect(status.lastMaintenance == .init(
            trigger: .clientConfiguration,
            result: .skipped,
            occurredAt: 100,
            reason: .init(kind: .powerSourceUnreadable)))
    }

    @Test func disabledRestoreWithoutPowerReadingStillRequiresVerifiedRelease() {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
        hardware.chargingInhibited = true
        hardware.releaseVerdict = .failed
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: PolicyStoreSpy(),
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })

        let status = coordinator.restoreWithoutPowerReading()

        #expect(hardware.releaseAttemptCount == 1)
        #expect(status.releaseVerdict == .failed)
        #expect(status.lastMaintenance?.result == .failed)
        #expect(status.lastMaintenance?.reason?.kind == .releaseFailed)
    }

    @Test func sampleDoesNotReadHardwareOrReplaceMaintenanceEvidence() {
        let hardware = MockBatteryHardware()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: PolicyStoreSpy(),
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })
        let configured = coordinator.configure(
            .init(enabled: true, limitPercentage: 85),
            trigger: .clientConfiguration,
            currentSoC: 70,
            isPluggedIn: true)
        let reads = hardware.readCount
        let writes = hardware.writeCount

        let sampled = coordinator.sample(currentSoC: 71, isPluggedIn: true)

        #expect(hardware.readCount == reads)
        #expect(hardware.writeCount == writes)
        #expect(sampled.lastMaintenance == configured.lastMaintenance)
        #expect(sampled.desiredConfiguration?.enabled == true)
        #expect(sampled.capabilities == BatteryControlCoordinator.capabilities)
    }

    @Test func adapterTransitionOpensANewThreeWriteRecoveryWindow() {
        let hardware = MockBatteryHardware()
        hardware.writeShouldFail = true
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: PolicyStoreSpy(),
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80),
            trigger: .clientConfiguration,
            currentSoC: 80,
            isPluggedIn: true)
        for _ in 0..<10 {
            _ = coordinator.sample(currentSoC: 80, isPluggedIn: true)
        }
        #expect(hardware.writeCount
            == BatteryControlEngine.maxConsecutiveWriteFailures)

        _ = coordinator.reconcile(
            trigger: .adapterTransition,
            currentSoC: 80,
            isPluggedIn: true)

        #expect(hardware.writeCount
            == BatteryControlEngine.maxConsecutiveWriteFailures + 1)
    }

    @Test func releaseForTerminationRequiresAllowedReadbackAndStopsAtThree() {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
        hardware.releaseVerdict = .failed
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: PolicyStoreSpy(),
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })

        #expect(coordinator.releaseForTermination() == false)
        #expect(hardware.releaseAttemptCount
            == BatteryControlEngine.maxConsecutiveWriteFailures)
        #expect(coordinator.latestStatus.releaseVerdict == .failed)
        #expect(coordinator.latestStatus.lastMaintenance?.trigger == .termination)
        #expect(coordinator.latestStatus.lastMaintenance?.result == .failed)
        #expect(coordinator.latestStatus.lastMaintenance?.reason?.kind == .releaseFailed)
    }

    @Test func fatalSaveRollbackMarksUnsafeAndPerformsVerifiedRelease() {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
        hardware.chargingInhibited = true
        let store = PolicyStoreSpy()
        store.saveError = BatteryPolicyStoreError.rollbackFailed(errno: EIO)
        let engine = BatteryControlEngine(hardware: hardware)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: engine,
            now: { 100 })

        let status = coordinator.configure(
            .init(enabled: true, limitPercentage: 80),
            trigger: .clientConfiguration,
            currentSoC: 80,
            isPluggedIn: true)

        #expect(coordinator.isSafeToServe == false)
        #expect(engine.configuration.enabled == false)
        #expect(hardware.releaseAttemptCount == 1)
        #expect(hardware.chargingInhibited == false)
        #expect(status.releaseVerdict == .verifiedAllowed)
        #expect(status.lastMaintenance?.trigger == .clientConfiguration)
        #expect(status.lastMaintenance?.reason?.kind == .persistenceWriteFailed)
    }

    @Test func fatalSaveRollbackCannotReapplyAPreviouslyEnabledPolicy() {
        let hardware = MockBatteryHardware()
        let store = PolicyStoreSpy()
        let engine = BatteryControlEngine(hardware: hardware)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: engine,
            now: { 100 })
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80),
            trigger: .clientConfiguration,
            currentSoC: 80,
            isPluggedIn: true)
        store.saveError = BatteryPolicyStoreError.rollbackFailed(errno: EIO)

        let status = coordinator.configure(
            .init(enabled: true, limitPercentage: 90),
            trigger: .clientConfiguration,
            currentSoC: 80,
            isPluggedIn: true)
        let writesAfterRelease = hardware.writeCount
        _ = coordinator.sample(currentSoC: 80, isPluggedIn: true)

        #expect(engine.configuration.enabled == false)
        #expect(status.desiredConfiguration?.enabled == false)
        #expect(status.releaseVerdict == .verifiedAllowed)
        #expect(coordinator.needsSampling == false)
        #expect(hardware.writeCount == writesAfterRelease)
    }

    @Test func fatalPowerlessSaveRollbackCannotReapplyAPreviouslyEnabledPolicy() {
        let hardware = MockBatteryHardware()
        let store = PolicyStoreSpy()
        let engine = BatteryControlEngine(hardware: hardware)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: engine,
            now: { 100 })
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80),
            trigger: .clientConfiguration,
            currentSoC: 80,
            isPluggedIn: true)
        store.saveError = BatteryPolicyStoreError.rollbackFailed(errno: EIO)

        let status = coordinator.configureWithoutPowerReading(
            .init(enabled: true, limitPercentage: 90),
            trigger: .clientConfiguration)
        let writesAfterRelease = hardware.writeCount
        _ = coordinator.sample(currentSoC: 80, isPluggedIn: true)

        #expect(engine.configuration.enabled == false)
        #expect(status.desiredConfiguration?.enabled == false)
        #expect(status.releaseVerdict == .verifiedAllowed)
        #expect(coordinator.needsSampling == false)
        #expect(hardware.writeCount == writesAfterRelease)
    }

    @Test func saveFailureLeavesTheOldConfigurationAndHardwareAlone() {
        let hardware = MockBatteryHardware()
        let store = PolicyStoreSpy()
        store.saveError = BatteryPolicyStoreError.fileOperation(errno: EIO)
        let engine = BatteryControlEngine(hardware: hardware)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: engine,
            now: { 100 })

        let status = coordinator.configure(
            .init(enabled: true, limitPercentage: 80),
            trigger: .clientConfiguration,
            currentSoC: 80,
            isPluggedIn: true)

        #expect(engine.configuration.enabled == false)
        #expect(hardware.writeCount == 0)
        #expect(hardware.releaseAttemptCount == 0)
        #expect(coordinator.isSafeToServe)
        #expect(status.lastMaintenance?.reason?.kind == .persistenceWriteFailed)
    }

    @Test func startupReadbackFailureIsNeverPublishedAsVerified() {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .unreadable
        hardware.holdReportedGateAfterWrite = true
        let store = PolicyStoreSpy()
        store.stored = .init(
            ownerUID: 501,
            configuration: .init(enabled: true, limitPercentage: 85),
            updatedAt: 10)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })

        let status = coordinator.restore(currentSoC: 80, isPluggedIn: true)

        #expect(status.lastMaintenance == .init(
            trigger: .startup,
            result: .failed,
            occurredAt: 100,
            reason: .init(kind: .hardwareReadbackFailed)))
    }

    @Test func enabledUnsupportedConfigurePublishesPermanentHardwareFailure() {
        let hardware = MockBatteryHardware()
        hardware.registerSet = .unsupported
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: PolicyStoreSpy(),
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })

        let status = coordinator.configure(
            .init(enabled: true, limitPercentage: 80),
            trigger: .clientConfiguration,
            currentSoC: 80,
            isPluggedIn: true)

        #expect(status.isHardwareSupported == false)
        #expect(status.actualGate == nil)
        #expect(status.detailReason?.kind == .hardwareUnsupported)
        #expect(status.lastMaintenance?.result == .failed)
        #expect(status.lastMaintenance?.reason?.kind == .hardwareUnsupported)
    }

    @Test func enabledUnsupportedRestoreIsNeverPublishedAsVerified() {
        let hardware = MockBatteryHardware()
        hardware.registerSet = .unsupported
        let store = PolicyStoreSpy()
        store.stored = .init(
            ownerUID: 501,
            configuration: .init(enabled: true, limitPercentage: 80),
            updatedAt: 10)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })

        let status = coordinator.restore(currentSoC: 80, isPluggedIn: true)

        #expect(status.isHardwareSupported == false)
        #expect(status.actualGate == nil)
        #expect(status.detailReason?.kind == .hardwareUnsupported)
        #expect(status.lastMaintenance?.result == .failed)
        #expect(status.lastMaintenance?.reason?.kind == .hardwareUnsupported)
    }

    @Test func corruptStoreReleasesAndReportsPersistenceReadFailure() {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
        hardware.chargingInhibited = true
        let store = PolicyStoreSpy()
        store.loadError = BatteryPolicyStoreError.unreadablePayload
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })

        let status = coordinator.restore(currentSoC: 80, isPluggedIn: true)

        #expect(status.desiredConfiguration?.enabled == false)
        #expect(status.actualGate?.state == .allowed)
        #expect(hardware.writeCount == 0)
        #expect(hardware.releaseAttemptCount == 1)
        #expect(coordinator.isSafeToServe)
        #expect(status.lastMaintenance == .init(
            trigger: .startup,
            result: .failed,
            occurredAt: 100,
            reason: .init(kind: .persistenceReadFailed)))
    }

    @Test func wrongOwnerWithoutPowerKeepsDiagnosticSeparateFromCurrentReason() {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
        hardware.chargingInhibited = true
        let store = PolicyStoreSpy()
        store.stored = .init(
            ownerUID: 502,
            configuration: .init(enabled: true, limitPercentage: 85),
            updatedAt: 10)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })

        let status = coordinator.restoreWithoutPowerReading()

        #expect(status.desiredConfiguration?.enabled == false)
        #expect(status.detailReason?.kind == .powerSourceUnreadable)
        #expect(status.lastMaintenance?.result == .failed)
        #expect(status.lastMaintenance?.reason?.kind == .policyOwnerMismatch)
        #expect(status.releaseVerdict == .verifiedAllowed)
    }

    @Test func disabledConfigureWithoutPowerReadingRequiresVerifiedRelease() {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
        hardware.chargingInhibited = true
        hardware.releaseVerdict = .failed
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: PolicyStoreSpy(),
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })

        let status = coordinator.configureWithoutPowerReading(
            .init(enabled: false),
            trigger: .clientConfiguration)

        #expect(hardware.releaseAttemptCount == 1)
        #expect(status.actualGate == .inhibited(appliedLimitPercentage: nil))
        #expect(status.releaseVerdict == .failed)
        #expect(status.lastMaintenance?.result == .failed)
        #expect(status.lastMaintenance?.reason?.kind == .releaseFailed)
    }

    @Test func failedDisableAndLaterSamplesShareOneThreeAttemptBudget() {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
        hardware.chargingInhibited = true
        hardware.releaseVerdict = .failed
        hardware.writeShouldFail = true
        let store = PolicyStoreSpy()
        store.stored = .init(
            ownerUID: 501,
            configuration: .init(enabled: true, limitPercentage: 80),
            updatedAt: 10)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })
        _ = coordinator.restoreWithoutPowerReading()

        _ = coordinator.configure(
            .init(enabled: false),
            trigger: .clientConfiguration,
            currentSoC: 80,
            isPluggedIn: true)
        for _ in 0..<10 {
            _ = coordinator.sample(currentSoC: 80, isPluggedIn: true)
        }

        #expect(hardware.releaseAttemptCount + hardware.writeCount
            == BatteryControlEngine.maxConsecutiveWriteFailures)
    }

    @Test func adapterTransitionReopensRecoveryForFailedDisabledGate() {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
        hardware.chargingInhibited = true
        hardware.releaseVerdict = .failed
        hardware.writeShouldFail = true
        let store = PolicyStoreSpy()
        store.stored = .init(
            ownerUID: 501,
            configuration: .init(enabled: true, limitPercentage: 80),
            updatedAt: 10)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })
        _ = coordinator.restoreWithoutPowerReading()

        _ = coordinator.configure(
            .init(enabled: false),
            trigger: .clientConfiguration,
            currentSoC: 80,
            isPluggedIn: true)
        for _ in 0..<10 {
            _ = coordinator.sample(currentSoC: 80, isPluggedIn: true)
        }
        let attemptsBeforeTransition = hardware.releaseAttemptCount
            + hardware.writeCount

        #expect(coordinator.needsSampling)
        #expect(coordinator.latestStatus.actualGate?.state == .inhibited)

        let status = coordinator.reconcile(
            trigger: .adapterTransition,
            currentSoC: 80,
            isPluggedIn: false)

        #expect(hardware.releaseAttemptCount + hardware.writeCount
            == attemptsBeforeTransition + 1)
        #expect(status.lastMaintenance?.trigger == .adapterTransition)
        #expect(status.lastMaintenance?.result == .failed)
        #expect(status.lastMaintenance?.reason?.kind == .releaseFailed)
    }

    @Test func ordinaryReconcileDoesNotOpenAnotherRecoveryWindow() {
        let hardware = MockBatteryHardware()
        hardware.writeShouldFail = true
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: PolicyStoreSpy(),
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80),
            trigger: .clientConfiguration,
            currentSoC: 80,
            isPluggedIn: true)
        for _ in 0..<10 {
            _ = coordinator.sample(currentSoC: 80, isPluggedIn: true)
        }
        let count = hardware.writeCount

        _ = coordinator.reconcile(
            trigger: .clientConfiguration,
            currentSoC: 80,
            isPluggedIn: true)

        #expect(hardware.writeCount == count)
    }

    @Test func terminationStopsAfterTheFirstSafeVerdict() {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
        hardware.chargingInhibited = true
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: PolicyStoreSpy(),
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })

        #expect(coordinator.releaseForTermination())
        #expect(hardware.releaseAttemptCount == 1)
        #expect(coordinator.latestStatus.actualGate == .allowed)
        #expect(coordinator.latestStatus.lastMaintenance?.result == .released)
        #expect(coordinator.latestStatus.lastMaintenance?.reason == nil)
    }

    @Test func fatalLoadRollbackMarksUnsafeAndPublishesReadFailureAfterRelease() {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
        hardware.chargingInhibited = true
        let store = PolicyStoreSpy()
        store.loadError = BatteryPolicyStoreError.rollbackFailed(errno: EIO)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })

        let status = coordinator.restore(currentSoC: 80, isPluggedIn: true)

        #expect(coordinator.isSafeToServe == false)
        #expect(hardware.releaseAttemptCount == 1)
        #expect(status.actualGate == .allowed)
        #expect(status.releaseVerdict == .verifiedAllowed)
        #expect(status.lastMaintenance?.trigger == .startup)
        #expect(status.lastMaintenance?.reason?.kind == .persistenceReadFailed)
    }

    @Test func unsupportedSchemaIsRecoverableAndFailsSafeToDisabled() {
        let hardware = MockBatteryHardware()
        let store = PolicyStoreSpy()
        store.loadError = BatteryPolicyStoreError.unsupportedSchema(2)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })

        let status = coordinator.restore(currentSoC: 80, isPluggedIn: true)

        #expect(coordinator.isSafeToServe)
        #expect(status.desiredConfiguration?.enabled == false)
        #expect(hardware.writeCount == 0)
        #expect(hardware.releaseAttemptCount == 1)
        #expect(status.lastMaintenance?.reason?.kind == .persistenceReadFailed)
    }

    @Test func firstSampleAfterPowerlessRestoreEvaluatesTheHeldGateNormally() {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
        hardware.chargingInhibited = true
        let store = PolicyStoreSpy()
        store.stored = .init(
            ownerUID: 501,
            configuration: .init(enabled: true, limitPercentage: 85),
            updatedAt: 10)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })
        _ = coordinator.restoreWithoutPowerReading()

        let sampled = coordinator.sample(currentSoC: 82, isPluggedIn: true)

        #expect(hardware.writeCount == 1)
        #expect(hardware.chargingInhibited == false)
        #expect(sampled.actualGate == .allowed)
        #expect(sampled.detailReason?.kind == .chargingToTarget)
    }

    @Test func needsSamplingTracksSafeDisabledAndFailedReleaseStates() {
        let healthyHardware = MockBatteryHardware()
        let healthy = BatteryControlCoordinator(
            ownerUID: 501,
            store: PolicyStoreSpy(),
            engine: BatteryControlEngine(hardware: healthyHardware),
            now: { 100 })
        _ = healthy.configure(
            .init(enabled: false),
            trigger: .clientConfiguration,
            currentSoC: 80,
            isPluggedIn: true)
        #expect(healthy.needsSampling == false)

        let failingHardware = MockBatteryHardware()
        failingHardware.releaseVerdict = .failed
        let failing = BatteryControlCoordinator(
            ownerUID: 501,
            store: PolicyStoreSpy(),
            engine: BatteryControlEngine(hardware: failingHardware),
            now: { 100 })
        _ = failing.configure(
            .init(enabled: false),
            trigger: .clientConfiguration,
            currentSoC: 80,
            isPluggedIn: true)
        #expect(failing.needsSampling)
    }
}
