import Darwin
import Foundation
import Testing
@testable import Wattly

/// 시간을 앞뒤로 움직일 수 있는 테스트 시계. 기존 테스트들이 쓰는 `now: { 100 }` 상수로는
/// 만료처럼 시간이 얽힌 전이를 실제 대기 없이 검증할 수 없다.
final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(_ value: TimeInterval) { self.value = value }

    var now: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        value += seconds
    }
}

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

    // MARK: - Top Up 자동 만료

    /// 100% 홀드를 처음 관측한 순간 도달 시각이 파일에 남아야 한다. 데몬은 재시작 후
    /// `restore()`로 `topUpActive`를 되살리므로, 시각이 메모리에만 있으면 매 재시작마다
    /// 12시간이 처음부터 다시 시작된다.
    @Test func stampsTheFullChargeMomentIntoThePolicyFile() {
        let clock = MutableClock(1_000)
        let hardware = MockBatteryHardware()
        let store = PolicyStoreSpy()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: hardware),
            now: { clock.now })

        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, topUpActive: true),
            trigger: .clientConfiguration, currentSoC: 98, isPluggedIn: true)
        #expect(store.stored?.topUpReachedFullAt == nil)

        clock.advance(by: 600)
        _ = coordinator.sample(currentSoC: 100, isPluggedIn: true)

        #expect(store.stored?.topUpReachedFullAt == 1_600)
    }

    /// 완충 도달 시각의 저장이 실패하면 다음 샘플이 다시 찍어야 한다. 미러에 남겨 두면
    /// `decide`가 두 번 다시 `.stamp`를 내지 않아 파일에는 영영 시각이 없고, 재시작 후
    /// 12시간 시계가 그 시점부터 새로 시작된다.
    @Test func retriesTheFullChargeStampWhenThePolicyWriteFails() {
        let clock = MutableClock(1_000)
        let store = PolicyStoreSpy()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()),
            now: { clock.now })
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, topUpActive: true),
            trigger: .clientConfiguration, currentSoC: 100, isPluggedIn: true)

        store.saveError = BatteryPolicyStoreError.fileOperation(errno: 1)
        _ = coordinator.sample(currentSoC: 100, isPluggedIn: true)
        #expect(store.stored?.topUpReachedFullAt == nil)

        store.saveError = nil
        clock.advance(by: 5)
        _ = coordinator.sample(currentSoC: 100, isPluggedIn: true)

        #expect(store.stored?.topUpReachedFullAt == 1_005)
    }

    /// 스탬프는 한 번만. 매 샘플마다 다시 찍히면 만료가 영원히 오지 않는다.
    @Test func doesNotRestampOnEverySample() {
        let clock = MutableClock(1_000)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: PolicyStoreSpy(),
            engine: BatteryControlEngine(hardware: MockBatteryHardware()),
            now: { clock.now })
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, topUpActive: true),
            trigger: .clientConfiguration, currentSoC: 100, isPluggedIn: true)
        _ = coordinator.sample(currentSoC: 100, isPluggedIn: true)

        clock.advance(by: 3_600)
        _ = coordinator.sample(currentSoC: 100, isPluggedIn: true)

        clock.advance(by: 11 * 3_600)   // 스탬프 기준 12시간 경과
        let status = coordinator.sample(currentSoC: 100, isPluggedIn: true)
        #expect(status.desiredConfiguration?.topUpActive == false)
    }

    @Test func expiresTopUpTwelveHoursAfterReachingFull() {
        let clock = MutableClock(1_000)
        let store = PolicyStoreSpy()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()),
            now: { clock.now })
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, topUpActive: true),
            trigger: .clientConfiguration, currentSoC: 100, isPluggedIn: true)
        _ = coordinator.sample(currentSoC: 100, isPluggedIn: true)

        clock.advance(by: 12 * 3_600 - 1)
        #expect(coordinator.sample(currentSoC: 100, isPluggedIn: true)
                    .desiredConfiguration?.topUpActive == true)

        clock.advance(by: 1)
        let status = coordinator.sample(currentSoC: 100, isPluggedIn: true)

        #expect(status.desiredConfiguration?.topUpActive == false)
        #expect(status.lastMaintenance?.trigger == .topUpExpired)
        #expect(status.lastMaintenance?.result == .applied)
        #expect(store.stored?.configuration.topUpActive == false)
        #expect(store.stored?.topUpReachedFullAt == nil)
        // 사용자의 원래 한도는 그대로 남는다.
        #expect(store.stored?.configuration.limitPercentage == 80)
    }

    /// 12시간짜리 잠자기 뒤 깨어난 경우. 타이머는 잠자기 중 돌지 않으므로 wake reconcile이
    /// 같은 판정에 도달해야 한다.
    @Test func expiresOnWakeAfterASleepThatOutlastedTheWindow() {
        let clock = MutableClock(1_000)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: PolicyStoreSpy(),
            engine: BatteryControlEngine(hardware: MockBatteryHardware()),
            now: { clock.now })
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, topUpActive: true),
            trigger: .clientConfiguration, currentSoC: 100, isPluggedIn: true)
        _ = coordinator.sample(currentSoC: 100, isPluggedIn: true)

        clock.advance(by: 13 * 3_600)
        let status = coordinator.reconcile(
            trigger: .wake, currentSoC: 100, isPluggedIn: true)

        #expect(status.desiredConfiguration?.topUpActive == false)
        #expect(status.lastMaintenance?.trigger == .topUpExpired)
    }

    /// 어댑터를 뽑아 Top Up이 끝나면 스탬프도 함께 사라져야 한다. 남아 있으면 다음 Top Up이
    /// 켜지자마자 즉시 만료된다.
    @Test func clearsTheStampWhenTopUpEndsByUnplugging() {
        let clock = MutableClock(1_000)
        let store = PolicyStoreSpy()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()),
            now: { clock.now })
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, topUpActive: true),
            trigger: .clientConfiguration, currentSoC: 100, isPluggedIn: true)
        _ = coordinator.sample(currentSoC: 100, isPluggedIn: true)
        #expect(store.stored?.topUpReachedFullAt == 1_000)

        _ = coordinator.reconcile(
            trigger: .adapterTransition, currentSoC: 100, isPluggedIn: false)

        #expect(store.stored?.configuration.topUpActive == false)
        #expect(store.stored?.topUpReachedFullAt == nil)
    }

    /// 사용자가 Top Up을 직접 끄면 스탬프도 사라진다.
    @Test func clearsTheStampWhenTheUserCancelsTopUp() {
        let clock = MutableClock(1_000)
        let store = PolicyStoreSpy()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()),
            now: { clock.now })
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, topUpActive: true),
            trigger: .clientConfiguration, currentSoC: 100, isPluggedIn: true)
        _ = coordinator.sample(currentSoC: 100, isPluggedIn: true)

        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, topUpActive: false),
            trigger: .clientConfiguration, currentSoC: 100, isPluggedIn: true)

        #expect(store.stored?.topUpReachedFullAt == nil)
    }

    /// Top Up 유지 중 다른 설정(예: 한도)만 바뀐 재푸시는 시계를 되감지 않는다.
    @Test func keepsTheStampAcrossAConfigurePushThatLeavesTopUpOn() {
        let clock = MutableClock(1_000)
        let store = PolicyStoreSpy()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()),
            now: { clock.now })
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, topUpActive: true),
            trigger: .clientConfiguration, currentSoC: 100, isPluggedIn: true)
        _ = coordinator.sample(currentSoC: 100, isPluggedIn: true)

        clock.advance(by: 3_600)
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 75, topUpActive: true),
            trigger: .clientConfiguration, currentSoC: 100, isPluggedIn: true)

        #expect(store.stored?.topUpReachedFullAt == 1_000)
    }

    /// 데몬이 재시작해도 시계는 이어져야 한다.
    @Test func restoresTheStampFromDiskOnDaemonRestart() {
        let clock = MutableClock(50_000)
        let store = PolicyStoreSpy()
        store.stored = .init(
            ownerUID: 501,
            configuration: .init(enabled: true, limitPercentage: 80, topUpActive: true),
            updatedAt: 1_000,
            topUpReachedFullAt: 1_000)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()),
            now: { clock.now })

        // 1_000 + 12h = 44_200 < 50_000 → 복원 직후 첫 샘플에서 만료된다.
        _ = coordinator.restore(currentSoC: 100, isPluggedIn: true)
        let status = coordinator.sample(currentSoC: 100, isPluggedIn: true)

        #expect(status.desiredConfiguration?.topUpActive == false)
        #expect(status.lastMaintenance?.trigger == .topUpExpired)
    }

    /// 만료 시점에 정책 저장이 실패하면 아무것도 바꾸지 않고 물러나야 한다. 엔진만 꺼 두고
    /// 물러나면 다음 판정이 `.none`이 되어 영원히 재시도되지 않고, 파일과 하드웨어가 갈라진 채
    /// 남는다.
    @Test func retriesTheExpiryWhenThePolicyWriteFails() {
        let clock = MutableClock(1_000)
        let store = PolicyStoreSpy()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()),
            now: { clock.now })
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, topUpActive: true),
            trigger: .clientConfiguration, currentSoC: 100, isPluggedIn: true)
        _ = coordinator.sample(currentSoC: 100, isPluggedIn: true)

        clock.advance(by: 12 * 3_600)
        store.saveError = BatteryPolicyStoreError.fileOperation(errno: 1)
        let blocked = coordinator.sample(currentSoC: 100, isPluggedIn: true)

        #expect(blocked.desiredConfiguration?.topUpActive == true)
        #expect(blocked.lastMaintenance?.trigger != .topUpExpired)

        store.saveError = nil
        let retried = coordinator.sample(currentSoC: 100, isPluggedIn: true)

        #expect(retried.desiredConfiguration?.topUpActive == false)
        #expect(retried.lastMaintenance?.trigger == .topUpExpired)
        #expect(store.stored?.configuration.topUpActive == false)
        #expect(store.stored?.topUpReachedFullAt == nil)
    }
}

