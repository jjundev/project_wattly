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

final class SleepInhibitorSpy: SystemSleepInhibiting, @unchecked Sendable {
    /// 시스템의 현재 `SleepDisabled`. 테스트가 "사용자가 미리 켜둠"을 흉내낼 때 직접 세운다.
    var current = false
    var readFails = false
    var setShouldFail = false
    /// 모든 쓰기 시도. 중복 쓰기도 보여야 하므로 성공/실패 무관하게 기록한다.
    var writes: [Bool] = []

    func readSleepDisabled() -> Bool? {
        readFails ? nil : current
    }

    func setSleepDisabled(_ disabled: Bool) -> Bool {
        writes.append(disabled)
        if setShouldFail { return false }
        current = disabled
        return true
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

    /// 어댑터를 뽑을 때 정책 저장이 실패해도 도달 시각은 메모리에서 지워져야 한다. 남겨 두면
    /// 다음 Top Up을 켜는 `configure`가 낡은 시각을 디스크에 다시 써서, 새 Top Up이 켜지자마자
    /// 만료된다.
    @Test func clearsTheStampEvenWhenTheUnplugWriteFails() {
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

        store.saveError = BatteryPolicyStoreError.fileOperation(errno: 1)
        _ = coordinator.reconcile(
            trigger: .adapterTransition, currentSoC: 100, isPluggedIn: false)
        store.saveError = nil

        // 사용자가 다시 꽂고 Top Up을 새로 켠다. 낡은 시각이 딸려 나오면 안 된다.
        clock.advance(by: 60)
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, topUpActive: true),
            trigger: .clientConfiguration, currentSoC: 90, isPluggedIn: true)

        #expect(store.stored?.topUpReachedFullAt == nil)
    }

    /// 캘리브레이션의 충전 단계(`topUpActive == true`)에서 어댑터가 빠져도 두 플래그가 함께
    /// 살아남아야 한다. `topUpActive`가 빠졌던 이전 버전의 테스트는 두 방어 분기(수동 방전·Top
    /// Up 자동 해제)를 아예 타지 않아, 예외 세 곳을 모두 되돌려도 통과하는 무의미한 테스트였다 —
    /// `reconcile`의 예외가 실제로 지키는 것은 바로 이 조합이다.
    @Test func calibrationSurvivesAdapterDisconnect() {
        let store = PolicyStoreSpy()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()),
            now: { 1000 })
        _ = coordinator.configure(
            .init(enabled: true, topUpActive: true, calibrationActive: true,
                  calibrationTargetPercentage: 20),
            trigger: .clientConfiguration, currentSoC: 90, isPluggedIn: true)
        #expect(coordinator.latestStatus.desiredConfiguration?.topUpActive == true)
        #expect(coordinator.latestStatus.desiredConfiguration?.calibrationActive == true)

        // Top Up·수동 방전은 어댑터가 빠지면 끝나지만 캘리브레이션의 충전 단계는 살아남아야
        // 한다 — 그렇지 않으면 앱 FSM은 여전히 충전 중이라 믿는데 엔진은 방전 분기로 빠진다.
        _ = coordinator.sample(currentSoC: 91, isPluggedIn: false)
        #expect(coordinator.latestStatus.desiredConfiguration?.calibrationActive == true)
        #expect(coordinator.latestStatus.desiredConfiguration?.topUpActive == true)
        _ = coordinator.reconcile(trigger: .adapterTransition, currentSoC: 91, isPluggedIn: false)
        #expect(coordinator.latestStatus.desiredConfiguration?.calibrationActive == true)
        #expect(coordinator.latestStatus.desiredConfiguration?.topUpActive == true)
    }

    /// `restore`도 같은 예외를 갖는다. 기존 `calibrationIsPersistedAndRestored`는
    /// `isPluggedIn: true`로만 재시작해 `restore` 맨 위의 예외 분기를 증명하지 못했다 — 배터리로
    /// 재시작하는 경우를 별도로 검증한다.
    @Test func calibrationSurvivesAdapterDisconnectOnRestore() {
        let store = PolicyStoreSpy()
        let first = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()), now: { 1000 })
        _ = first.configure(
            .init(enabled: true, topUpActive: true, calibrationActive: true,
                  calibrationTargetPercentage: 20),
            trigger: .clientConfiguration, currentSoC: 90, isPluggedIn: true)
        #expect(store.stored?.configuration.topUpActive == true)
        #expect(store.stored?.configuration.calibrationActive == true)

        let restarted = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()), now: { 2000 })
        let status = restarted.restore(currentSoC: 91, isPluggedIn: false)
        #expect(status.desiredConfiguration?.topUpActive == true)
        #expect(status.desiredConfiguration?.calibrationActive == true)
    }

    @Test func calibrationIsPersistedAndRestored() {
        let store = PolicyStoreSpy()
        let first = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()), now: { 1000 })
        _ = first.configure(
            .init(enabled: true, calibrationActive: true, calibrationTargetPercentage: 20),
            trigger: .clientConfiguration, currentSoC: 60, isPluggedIn: true)
        #expect(store.stored?.configuration.calibrationActive == true)

        let restarted = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()), now: { 2000 })
        let status = restarted.restore(currentSoC: 55, isPluggedIn: true)
        #expect(status.desiredConfiguration?.calibrationActive == true)
        #expect(status.desiredConfiguration?.calibrationTargetPercentage == 20)
    }

    @Test func calibrationExcludesManualDischarge() {
        let store = PolicyStoreSpy()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()), now: { 1000 })
        let status = coordinator.configure(
            .init(enabled: true, manualDischargeActive: true, manualDischargeTarget: 60,
                  calibrationActive: true, calibrationTargetPercentage: 20),
            trigger: .clientConfiguration, currentSoC: 80, isPluggedIn: true)
        #expect(status.desiredConfiguration?.calibrationActive == true)
        #expect(status.desiredConfiguration?.manualDischargeActive == false)
    }

    /// 모순된 입력 — 수동 방전·Top Up·캘리브레이션이 동시에 켜진 요청 — 에서 캘리브레이션이
    /// 먼저 판정돼야 한다. 순서가 뒤집히면(수동 방전⟷Top Up 상호배제를 먼저 적용) 수동 방전
    /// 분기가 `topUpActive`를 지워 버려 캘리브레이션의 충전 단계 의도가 조용히 사라진다.
    @Test func calibrationResolvesBeforeManualDischargeTopUpExclusion() {
        let store = PolicyStoreSpy()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()), now: { 1000 })
        let status = coordinator.configure(
            .init(enabled: true, topUpActive: true, manualDischargeActive: true,
                  manualDischargeTarget: 60, calibrationActive: true,
                  calibrationTargetPercentage: 20),
            trigger: .clientConfiguration, currentSoC: 80, isPluggedIn: true)
        #expect(status.desiredConfiguration?.manualDischargeActive == false)
        #expect(status.desiredConfiguration?.topUpActive == true)
        #expect(status.desiredConfiguration?.calibrationActive == true)
    }

    /// 같은 모순 입력을 `configureWithoutPowerReading` 경로로도 확인한다 — 두 진입점이 정규화
    /// 로직을 각자 복제하고 있어 하나만 고치면 갈라진다.
    @Test func calibrationResolvesBeforeManualDischargeTopUpExclusionWithoutPowerReading() {
        let store = PolicyStoreSpy()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()), now: { 1000 })
        let status = coordinator.configureWithoutPowerReading(
            .init(enabled: true, topUpActive: true, manualDischargeActive: true,
                  manualDischargeTarget: 60, calibrationActive: true,
                  calibrationTargetPercentage: 20),
            trigger: .clientConfiguration)
        #expect(status.desiredConfiguration?.manualDischargeActive == false)
        #expect(status.desiredConfiguration?.topUpActive == true)
        #expect(status.desiredConfiguration?.calibrationActive == true)
    }

    @Test func coordinatorAdvertisesCalibrationCapability() {
        #expect(BatteryControlCoordinator.capabilities.contains(.calibrationV1))
    }

    /// 캘리브레이션이 시작되기 *전에* 평범한 Top Up이 이미 100%에 도달해 도달 시각을 파일에
    /// 찍어 둔 상태를 재현한다. 그 스탬프가 디스크에 남아 있는 채로 캘리브레이션이 시작되면,
    /// 12시간 뒤에도 그 스탬프가 만료를 쏘면 안 된다. `evaluateTopUpExpiry`가 100% 홀드 판정
    /// 자체를 `.calibrationHolding`으로 바꿔 버리는 이전 버전의 테스트는 `decide` 호출에서
    /// `calibrationActive:` 인자를 지워도 통과했다 — `isHoldingAtFull`이 이미 false라 `.none`이
    /// 나오는 별개의 이유로 우연히 맞았을 뿐, 인자가 실제로 하는 일은 검증하지 못했다.
    @Test func topUpNeverExpiresDuringCalibration() {
        let store = PolicyStoreSpy()
        let clock = MutableClock(1000)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()),
            now: { clock.now })

        // 평범한 Top Up이 먼저 100%에 도달해 도달 시각을 찍는다.
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, topUpActive: true),
            trigger: .clientConfiguration, currentSoC: 100, isPluggedIn: true)
        _ = coordinator.sample(currentSoC: 100, isPluggedIn: true)
        #expect(store.stored?.topUpReachedFullAt == 1000)

        // 그 스탬프가 디스크에 남은 채로 캘리브레이션이 시작된다(충전 단계 = topUpActive 유지).
        _ = coordinator.configure(
            .init(enabled: true, topUpActive: true, calibrationActive: true,
                  calibrationTargetPercentage: 20),
            trigger: .clientConfiguration, currentSoC: 100, isPluggedIn: true)

        clock.advance(by: BatteryTopUpExpiry.duration + 3600)
        let status = coordinator.sample(currentSoC: 100, isPluggedIn: true)
        #expect(status.desiredConfiguration?.topUpActive == true)
        #expect(status.lastMaintenance?.trigger != .topUpExpired)
    }

    // MARK: - 클램쉘 방전 잠자기 억제

    private func makeClamshellCoordinator(
        clock: MutableClock,
        hardware: MockBatteryHardware = MockBatteryHardware(),
        store: PolicyStoreSpy = PolicyStoreSpy(),
        inhibitor: SleepInhibitorSpy = SleepInhibitorSpy()
    ) -> BatteryControlCoordinator {
        BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: hardware),
            now: { clock.now },
            sleepInhibitor: inhibitor)
    }

    @Test func capabilitiesAdvertiseClamshellDischarge() {
        #expect(BatteryControlCoordinator.capabilities.contains(.clamshellDischargeV1))
    }

    /// 켜는 조건 세 개: allowed && CHIE 걸림. 마커가 플래그보다 먼저 저장된다.
    @Test func engagesSleepInhibitionWhenAllowedAndDischarging() {
        let clock = MutableClock(1_000)
        let hardware = MockBatteryHardware()
        let store = PolicyStoreSpy()
        let inhibitor = SleepInhibitorSpy()
        let coordinator = makeClamshellCoordinator(
            clock: clock, hardware: hardware, store: store, inhibitor: inhibitor)

        let status = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  manualDischargeActive: true, manualDischargeTarget: 70,
                  clamshellDischargeAllowed: true),
            trigger: .clientConfiguration, currentSoC: 85, isPluggedIn: true)

        #expect(hardware.isDischargeActive == true)
        #expect(inhibitor.writes == [true])
        #expect(inhibitor.current == true)
        #expect(status.isSystemSleepInhibited == true)
        #expect(store.stored?.sleepInhibitedAt == 1_000)
        // 옵트인 자체는 저장하지 않는다.
        #expect(store.stored?.configuration.clamshellDischargeAllowed == false)
    }

    @Test func doesNotEngageWithoutAllowanceEvenWhileDischarging() {
        let clock = MutableClock(1_000)
        let inhibitor = SleepInhibitorSpy()
        let coordinator = makeClamshellCoordinator(clock: clock, inhibitor: inhibitor)

        let status = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  manualDischargeActive: true, manualDischargeTarget: 70),
            trigger: .clientConfiguration, currentSoC: 85, isPluggedIn: true)

        #expect(inhibitor.writes.isEmpty)
        #expect(status.isSystemSleepInhibited == false)
    }

    /// 자동 방전(sailing)도 CHIE를 걸므로 같은 규칙을 탄다(결정 #20).
    @Test func engagesForAutomaticDischargeToo() {
        let clock = MutableClock(1_000)
        let hardware = MockBatteryHardware()
        let inhibitor = SleepInhibitorSpy()
        let coordinator = makeClamshellCoordinator(
            clock: clock, hardware: hardware, inhibitor: inhibitor)

        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, autoDischargeEnabled: true,
                  clamshellDischargeAllowed: true),
            trigger: .clientConfiguration, currentSoC: 95, isPluggedIn: true)

        #expect(hardware.isDischargeActive == true)
        #expect(inhibitor.current == true)
    }

    /// 목표 도달 → 엔진이 CHIE를 끔 → 같은 샘플에서 잠자기 차단도 풀린다.
    @Test func disengagesWhenDischargeReachesItsTarget() {
        let clock = MutableClock(1_000)
        let hardware = MockBatteryHardware()
        let store = PolicyStoreSpy()
        let inhibitor = SleepInhibitorSpy()
        let coordinator = makeClamshellCoordinator(
            clock: clock, hardware: hardware, store: store, inhibitor: inhibitor)
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  manualDischargeActive: true, manualDischargeTarget: 70,
                  clamshellDischargeAllowed: true),
            trigger: .clientConfiguration, currentSoC: 85, isPluggedIn: true)
        #expect(inhibitor.current == true)

        let status = coordinator.sample(currentSoC: 70, isPluggedIn: true)

        #expect(hardware.isDischargeActive == false)
        #expect(inhibitor.writes == [true, false])
        #expect(status.isSystemSleepInhibited == false)
        #expect(store.stored?.sleepInhibitedAt == nil)
    }

    /// 가방 시나리오: 어댑터를 뽑으면 데몬이 수동 방전을 끄고, 잠자기 차단도 함께 풀린다.
    @Test func disengagesWhenTheAdapterIsUnplugged() {
        let clock = MutableClock(1_000)
        let inhibitor = SleepInhibitorSpy()
        let coordinator = makeClamshellCoordinator(clock: clock, inhibitor: inhibitor)
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  manualDischargeActive: true, manualDischargeTarget: 70,
                  clamshellDischargeAllowed: true),
            trigger: .clientConfiguration, currentSoC: 85, isPluggedIn: true)

        _ = coordinator.sample(currentSoC: 84, isPluggedIn: false)

        #expect(inhibitor.current == false)
        #expect(inhibitor.writes == [true, false])
    }

    /// 앱이 allowed=false를 보내면(옵트인 해제 또는 외장 디스플레이 분리) 방전은 계속되지만
    /// 잠자기 차단만 풀린다.
    @Test func disengagesWhenTheAppWithdrawsAllowanceWhileStillDischarging() {
        let clock = MutableClock(1_000)
        let hardware = MockBatteryHardware()
        let inhibitor = SleepInhibitorSpy()
        let coordinator = makeClamshellCoordinator(
            clock: clock, hardware: hardware, inhibitor: inhibitor)
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  manualDischargeActive: true, manualDischargeTarget: 70,
                  clamshellDischargeAllowed: true),
            trigger: .clientConfiguration, currentSoC: 85, isPluggedIn: true)

        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  manualDischargeActive: true, manualDischargeTarget: 70,
                  clamshellDischargeAllowed: false),
            trigger: .clientConfiguration, currentSoC: 84, isPluggedIn: true)

        #expect(hardware.isDischargeActive == true)
        #expect(inhibitor.current == false)
    }

    /// 발열 보호는 엔진이 CHIE를 끄므로 별도 배선 없이 상속된다.
    @Test func disengagesUnderHeatProtection() {
        let clock = MutableClock(1_000)
        let hardware = MockBatteryHardware()
        let inhibitor = SleepInhibitorSpy()
        let coordinator = makeClamshellCoordinator(
            clock: clock, hardware: hardware, inhibitor: inhibitor)
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  heatProtectionEnabled: true, heatProtectionThresholdCelsius: 35,
                  manualDischargeActive: true, manualDischargeTarget: 70,
                  clamshellDischargeAllowed: true),
            trigger: .clientConfiguration, currentSoC: 85, isPluggedIn: true,
            temperatureCelsius: 30)
        #expect(inhibitor.current == true)

        _ = coordinator.sample(currentSoC: 84, isPluggedIn: true, temperatureCelsius: 36)

        #expect(hardware.isDischargeActive == false)
        #expect(inhibitor.current == false)
    }

    /// 12시간이 지나면 방전은 계속되지만 잠자기 차단은 풀리고, 앱이 allowed=true를 매분
    /// 되밀어도 같은 방전 세션에서는 다시 켜지지 않는다. 방전이 끝나면 래치가 풀린다.
    @Test func expiresAfterTwelveHoursAndDoesNotReengageUntilDischargeEnds() {
        let clock = MutableClock(1_000)
        let hardware = MockBatteryHardware()
        let inhibitor = SleepInhibitorSpy()
        let coordinator = makeClamshellCoordinator(
            clock: clock, hardware: hardware, inhibitor: inhibitor)
        let running = BatteryControlConfiguration(
            enabled: true, limitPercentage: 80,
            manualDischargeActive: true, manualDischargeTarget: 50,
            clamshellDischargeAllowed: true)
        _ = coordinator.configure(
            running, trigger: .clientConfiguration, currentSoC: 95, isPluggedIn: true)

        clock.advance(by: BatteryClamshellSleepPolicy.duration)
        let expired = coordinator.sample(currentSoC: 60, isPluggedIn: true)
        #expect(hardware.isDischargeActive == true)
        #expect(inhibitor.current == false)
        #expect(expired.isSystemSleepInhibited == false)

        // 앱 reconcile이 다시 보내도 켜지지 않는다.
        _ = coordinator.configure(
            running, trigger: .clientConfiguration, currentSoC: 59, isPluggedIn: true)
        #expect(inhibitor.writes == [true, false])

        // 목표 도달로 방전이 끝나면 래치가 풀려, 다음 방전은 다시 켤 수 있다.
        _ = coordinator.sample(currentSoC: 50, isPluggedIn: true)
        // `manualDischargeTarget`은 50~99로 클램프된다(`BatterySectionPresentation
        // .manualDischargeTargetRange`). 목표를 40으로 요청해도 50으로 잘리므로, 새 방전이
        // 실제로 걸리려면 SoC가 그 클램프된 목표보다 높아야 한다 — 그래서 55에서 다시 켠다.
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  manualDischargeActive: true, manualDischargeTarget: 40,
                  clamshellDischargeAllowed: true),
            trigger: .clientConfiguration, currentSoC: 55, isPluggedIn: true)
        #expect(inhibitor.writes == [true, false, true])
    }

    /// 사용자가 직접 `pmset disablesleep 1`을 해 둔 Mac에서는 소유하지 않는다 — 켜지도, 방전이
    /// 끝났다고 끄지도 않는다.
    @Test func doesNotTakeOwnershipOfAUserSetSleepDisabled() {
        let clock = MutableClock(1_000)
        let store = PolicyStoreSpy()
        let inhibitor = SleepInhibitorSpy()
        inhibitor.current = true
        let coordinator = makeClamshellCoordinator(
            clock: clock, store: store, inhibitor: inhibitor)

        let status = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  manualDischargeActive: true, manualDischargeTarget: 70,
                  clamshellDischargeAllowed: true),
            trigger: .clientConfiguration, currentSoC: 85, isPluggedIn: true)
        _ = coordinator.sample(currentSoC: 70, isPluggedIn: true)

        #expect(inhibitor.writes.isEmpty)
        #expect(inhibitor.current == true)
        #expect(status.isSystemSleepInhibited == false)
        #expect(store.stored?.sleepInhibitedAt == nil)
    }

    /// 읽기 실패는 "꺼져 있음"이 아니다. 모르면 켜지 않는다.
    @Test func doesNotEngageWhenTheCurrentValueCannotBeRead() {
        let clock = MutableClock(1_000)
        let inhibitor = SleepInhibitorSpy()
        inhibitor.readFails = true
        let coordinator = makeClamshellCoordinator(clock: clock, inhibitor: inhibitor)

        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  manualDischargeActive: true, manualDischargeTarget: 70,
                  clamshellDischargeAllowed: true),
            trigger: .clientConfiguration, currentSoC: 85, isPluggedIn: true)

        #expect(inhibitor.writes.isEmpty)
    }

    /// 마커 저장이 실패하면 플래그를 켜지 않는다 — 마커 없는 플래그는 크래시 후 고아가 된다.
    @Test func doesNotEngageWhenTheMarkerCannotBePersisted() {
        let clock = MutableClock(1_000)
        let store = PolicyStoreSpy()
        let inhibitor = SleepInhibitorSpy()
        let coordinator = makeClamshellCoordinator(
            clock: clock, store: store, inhibitor: inhibitor)
        // configure의 첫 persist는 성공시키고, 그 뒤 마커 저장만 실패시킨다.
        var saveCount = 0
        store.onSave = {
            saveCount += 1
            if saveCount >= 2 { store.saveError = BatteryPolicyStoreError.fileOperation(errno: 1) }
        }

        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  manualDischargeActive: true, manualDischargeTarget: 70,
                  clamshellDischargeAllowed: true),
            trigger: .clientConfiguration, currentSoC: 85, isPluggedIn: true)

        #expect(inhibitor.writes.isEmpty)
        #expect(store.stored?.sleepInhibitedAt == nil)
    }

    /// 해제 쓰기가 실패하면 마커를 남겨 다음 샘플이 재시도한다.
    @Test func retriesDisengageUntilTheWriteLands() {
        let clock = MutableClock(1_000)
        let store = PolicyStoreSpy()
        let inhibitor = SleepInhibitorSpy()
        let coordinator = makeClamshellCoordinator(
            clock: clock, store: store, inhibitor: inhibitor)
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  manualDischargeActive: true, manualDischargeTarget: 70,
                  clamshellDischargeAllowed: true),
            trigger: .clientConfiguration, currentSoC: 85, isPluggedIn: true)

        inhibitor.setShouldFail = true
        _ = coordinator.sample(currentSoC: 70, isPluggedIn: true)
        #expect(inhibitor.current == true)
        #expect(store.stored?.sleepInhibitedAt == 1_000)

        inhibitor.setShouldFail = false
        clock.advance(by: 5)
        _ = coordinator.sample(currentSoC: 70, isPluggedIn: true)
        #expect(inhibitor.current == false)
        #expect(store.stored?.sleepInhibitedAt == nil)
    }

    /// 크래시·재부팅 복구: 파일에 마커가 남아 있으면 시작 시 무조건 되돌린다. 옵트인은 저장되지
    /// 않으므로 다시 켜지지도 않는다.
    @Test func restoreClearsAnOrphanedSleepInhibition() {
        let clock = MutableClock(5_000)
        let store = PolicyStoreSpy()
        store.stored = PersistedBatteryPolicy(
            ownerUID: 501,
            configuration: .init(enabled: true, limitPercentage: 80),
            updatedAt: 1_000,
            sleepInhibitedAt: 1_000)
        let inhibitor = SleepInhibitorSpy()
        inhibitor.current = true
        let coordinator = makeClamshellCoordinator(
            clock: clock, store: store, inhibitor: inhibitor)

        let status = coordinator.restore(currentSoC: 60, isPluggedIn: true)

        #expect(inhibitor.writes == [false])
        #expect(inhibitor.current == false)
        #expect(store.stored?.sleepInhibitedAt == nil)
        #expect(status.isSystemSleepInhibited == false)
    }

    @Test func restoreWithoutPowerReadingAlsoClearsAnOrphanedSleepInhibition() {
        let clock = MutableClock(5_000)
        let store = PolicyStoreSpy()
        store.stored = PersistedBatteryPolicy(
            ownerUID: 501,
            configuration: .init(enabled: true, limitPercentage: 80),
            updatedAt: 1_000,
            sleepInhibitedAt: 1_000)
        let inhibitor = SleepInhibitorSpy()
        inhibitor.current = true
        let coordinator = makeClamshellCoordinator(
            clock: clock, store: store, inhibitor: inhibitor)

        _ = coordinator.restoreWithoutPowerReading()

        #expect(inhibitor.writes == [false])
        #expect(store.stored?.sleepInhibitedAt == nil)
    }

    /// 마커가 없으면 시작 시 아무것도 쓰지 않는다 — 사용자의 `disablesleep 1`을 건드리면 안 된다.
    @Test func restoreLeavesAForeignSleepDisabledAlone() {
        let clock = MutableClock(5_000)
        let store = PolicyStoreSpy()
        store.stored = PersistedBatteryPolicy(
            ownerUID: 501,
            configuration: .init(enabled: true, limitPercentage: 80),
            updatedAt: 1_000)
        let inhibitor = SleepInhibitorSpy()
        inhibitor.current = true
        let coordinator = makeClamshellCoordinator(
            clock: clock, store: store, inhibitor: inhibitor)

        _ = coordinator.restore(currentSoC: 60, isPluggedIn: true)

        #expect(inhibitor.writes.isEmpty)
        #expect(inhibitor.current == true)
    }

    @Test func terminationReleasesSleepInhibition() {
        let clock = MutableClock(1_000)
        let store = PolicyStoreSpy()
        let inhibitor = SleepInhibitorSpy()
        let coordinator = makeClamshellCoordinator(
            clock: clock, store: store, inhibitor: inhibitor)
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  manualDischargeActive: true, manualDischargeTarget: 70,
                  clamshellDischargeAllowed: true),
            trigger: .clientConfiguration, currentSoC: 85, isPluggedIn: true)

        _ = coordinator.releaseForTermination()

        #expect(inhibitor.current == false)
        #expect(store.stored?.sleepInhibitedAt == nil)
    }
}

