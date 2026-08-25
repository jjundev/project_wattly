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

    var savedRecord: PersistedBatteryPolicy? { stored }

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

typealias MockBatteryPolicyStore = PolicyStoreSpy

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
        hardware.releaseVerification = .init(
            verdict: .notControllable,
            proof: .noDrivableRegisterAtRuntime)
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
        #expect(status.releaseVerification?.proof == .noDrivableRegisterAtRuntime)
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

    @Test func coordinatorDoesNotReleaseHardwareWhenHeatProtectionIsActiveWithoutChargeLimit() {
        let store = PolicyStoreSpy()
        let hw = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: hw)
        let coordinator = BatteryControlCoordinator(ownerUID: 501, store: store, engine: engine, now: { 1000 })

        let config = BatteryControlConfiguration(enabled: false, heatProtectionEnabled: true)
        let status = coordinator.configure(config, trigger: .clientConfiguration, currentSoC: 50, isPluggedIn: true, temperatureCelsius: 37.0)

        #expect(status.mode == .inhibited)
        #expect(status.activity == .heatProtection)
        #expect(hw.lastInhibited == true)
    }

    @Test func unpluggingAdapterAutomaticallyDeactivatesTopUpAndPersistsBasePolicy() throws {
        let store = MockBatteryPolicyStore()
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: engine,
            now: { 1000.0 }
        )

        // Configure Top Up while plugged in
        let topUpConfig = BatteryControlConfiguration(enabled: true, limitPercentage: 80, topUpActive: true)
        _ = coordinator.configure(topUpConfig, trigger: .clientConfiguration, currentSoC: 70, isPluggedIn: true)
        #expect(coordinator.latestStatus.desiredConfiguration?.topUpActive == true)
        #expect(store.savedRecord?.configuration.topUpActive == true)

        // Adapter is disconnected (unplugged): trigger adapterTransition
        let unpluggedStatus = coordinator.reconcile(
            trigger: .adapterTransition,
            currentSoC: 70,
            isPluggedIn: false
        )

        // Top Up must be cleared, normal policy (limit 80) persisted and enforced
        #expect(unpluggedStatus.desiredConfiguration?.topUpActive == false)
        #expect(unpluggedStatus.desiredConfiguration?.limitPercentage == 80)
        #expect(store.savedRecord?.configuration.topUpActive == false)
        #expect(store.savedRecord?.configuration.limitPercentage == 80)
    }

    @Test func startingUpOrWakingOnBatteryPowerClearsAnyStaleTopUpActive() throws {
        let store = MockBatteryPolicyStore()
        let staleTopUp = BatteryControlConfiguration(enabled: true, limitPercentage: 80, topUpActive: true)
        try store.save(.init(ownerUID: 501, configuration: staleTopUp, updatedAt: 900.0))

        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: engine,
            now: { 1000.0 }
        )

        // Restore on battery power (!isPluggedIn)
        let restoreStatus = coordinator.restore(currentSoC: 90, isPluggedIn: false)
        #expect(restoreStatus.desiredConfiguration?.topUpActive == false)
        #expect(store.savedRecord?.configuration.topUpActive == false)
    }

    @Test func unplugResetsDischargeState() {
        let mockStore = MockBatteryPolicyStore()
        let mockHardware = MockBatteryHardware()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: mockStore,
            engine: BatteryControlEngine(hardware: mockHardware),
            now: { 1000 })

        let config = BatteryControlConfiguration(
            enabled: true,
            limitPercentage: 80,
            manualDischargeActive: true,
            manualDischargeTarget: 70)
        _ = coordinator.configure(
            config,
            trigger: .clientConfiguration,
            currentSoC: 85,
            isPluggedIn: true)

        #expect(coordinator.latestStatus.desiredConfiguration?.manualDischargeActive == true)
        #expect(mockHardware.isDischargeActive == true)

        let status = coordinator.sample(currentSoC: 80, isPluggedIn: false)

        #expect(status.desiredConfiguration?.manualDischargeActive == false)
        #expect(coordinator.latestStatus.desiredConfiguration?.manualDischargeActive == false)
        #expect(mockHardware.isDischargeActive == false)
    }

    @Test func manualDischargeSessionIsNotPersistedToStore() {
        let mockStore = MockBatteryPolicyStore()
        let mockHardware = MockBatteryHardware()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: mockStore,
            engine: BatteryControlEngine(hardware: mockHardware),
            now: { 1000 })

        let config = BatteryControlConfiguration(
            enabled: true,
            limitPercentage: 80,
            manualDischargeActive: true,
            manualDischargeTarget: 70)
        _ = coordinator.configure(
            config,
            trigger: .clientConfiguration,
            currentSoC: 85,
            isPluggedIn: true)

        #expect(coordinator.latestStatus.desiredConfiguration?.manualDischargeActive == true)
        #expect(mockStore.savedRecord?.configuration.manualDischargeActive == false)
        #expect(mockStore.savedRecord?.configuration.limitPercentage == 80)
        #expect(mockStore.savedRecord?.configuration.manualDischargeTarget == 70)

        // Also test configureWithoutPowerReading
        _ = coordinator.configureWithoutPowerReading(
            config,
            trigger: .clientConfiguration)

        #expect(coordinator.latestStatus.desiredConfiguration?.manualDischargeActive == true)
        #expect(mockStore.savedRecord?.configuration.manualDischargeActive == false)
    }

    @Test func restoreNeverRestoresActiveManualDischargeFromStore() throws {
        let mockStore = MockBatteryPolicyStore()
        let staleDischarge = BatteryControlConfiguration(
            enabled: true,
            limitPercentage: 80,
            manualDischargeActive: true,
            manualDischargeTarget: 70)
        try mockStore.save(.init(ownerUID: 501, configuration: staleDischarge, updatedAt: 900.0))

        let mockHardware = MockBatteryHardware()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: mockStore,
            engine: BatteryControlEngine(hardware: mockHardware),
            now: { 1000 })

        let restoreStatus = coordinator.restore(currentSoC: 75, isPluggedIn: true)
        #expect(restoreStatus.desiredConfiguration?.manualDischargeActive == false)
        #expect(mockHardware.isDischargeActive == false)

        let powerlessStatus = coordinator.restoreWithoutPowerReading()
        #expect(powerlessStatus.desiredConfiguration?.manualDischargeActive == false)
    }

    @Test func mutualExclusionDischargeClearsTopUp() {
        let mockStore = MockBatteryPolicyStore()
        let mockHardware = MockBatteryHardware()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: mockStore,
            engine: BatteryControlEngine(hardware: mockHardware),
            now: { 1000 })

        // 1. First enable Top Up
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, topUpActive: true),
            trigger: .clientConfiguration,
            currentSoC: 80,
            isPluggedIn: true)
        #expect(coordinator.latestStatus.desiredConfiguration?.topUpActive == true)
        #expect(coordinator.latestStatus.desiredConfiguration?.manualDischargeActive == false)

        // 2. Enable Manual Discharge -> Top Up must be cleared
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, manualDischargeActive: true, manualDischargeTarget: 70),
            trigger: .clientConfiguration,
            currentSoC: 85,
            isPluggedIn: true)
        #expect(coordinator.latestStatus.desiredConfiguration?.manualDischargeActive == true)
        #expect(coordinator.latestStatus.desiredConfiguration?.topUpActive == false)
        #expect(mockStore.savedRecord?.configuration.topUpActive == false)
        #expect(mockStore.savedRecord?.configuration.manualDischargeActive == false)
    }

    @Test func mutualExclusionTopUpClearsDischarge() {
        let mockStore = MockBatteryPolicyStore()
        let mockHardware = MockBatteryHardware()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: mockStore,
            engine: BatteryControlEngine(hardware: mockHardware),
            now: { 1000 })

        // 1. First enable Manual Discharge
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, manualDischargeActive: true, manualDischargeTarget: 70),
            trigger: .clientConfiguration,
            currentSoC: 85,
            isPluggedIn: true)
        #expect(coordinator.latestStatus.desiredConfiguration?.manualDischargeActive == true)
        #expect(coordinator.latestStatus.desiredConfiguration?.topUpActive == false)

        // 2. Enable Top Up -> Manual Discharge must be cleared
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, topUpActive: true),
            trigger: .clientConfiguration,
            currentSoC: 80,
            isPluggedIn: true)
        #expect(coordinator.latestStatus.desiredConfiguration?.topUpActive == true)
        #expect(coordinator.latestStatus.desiredConfiguration?.manualDischargeActive == false)
        #expect(mockStore.savedRecord?.configuration.topUpActive == true)
        #expect(mockStore.savedRecord?.configuration.manualDischargeActive == false)
    }

    @Test func terminationReleasesActiveDischargeHardwareState() {
        let mockStore = MockBatteryPolicyStore()
        let mockHardware = MockBatteryHardware()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: mockStore,
            engine: BatteryControlEngine(hardware: mockHardware),
            now: { 1000 })

        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, manualDischargeActive: true, manualDischargeTarget: 70),
            trigger: .clientConfiguration,
            currentSoC: 85,
            isPluggedIn: true)
        #expect(mockHardware.isDischargeActive == true)

        let safe = coordinator.releaseForTermination()
        #expect(safe == true)
        #expect(mockHardware.isDischargeActive == false)
        #expect(coordinator.latestStatus.lastMaintenance?.trigger == .termination)
        #expect(coordinator.latestStatus.lastMaintenance?.result == .released)
    }
}

