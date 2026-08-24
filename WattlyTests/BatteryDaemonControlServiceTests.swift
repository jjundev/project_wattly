import Foundation
import Testing
@testable import Wattly

struct BatteryDaemonControlServiceTests {
    @Test func powerlessEnabledRequestPersistsNormalizedPolicyAndEncodesSkippedStatus() throws {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .allowed
        let store = PolicyStoreSpy()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })
        let service = BatteryDaemonControlService(coordinator: coordinator)
        let request = BatteryControlConfigurationRequest(
            configuration: .init(
                enabled: true,
                limitPercentage: 145,
                lowerHysteresisDelta: 0),
            generation: 1)

        let replyData = try service.configure(
            encodedRequest: BatteryControlCodec.encode(request),
            currentReading: nil)
        let status = try BatteryControlCodec.decode(
            BatteryControlServiceStatus.self,
            from: replyData)

        #expect(status == coordinator.latestStatus)
        #expect(store.stored?.configuration == .init(
            enabled: true,
            limitPercentage: 100,
            lowerHysteresisDelta: 1))
        #expect(status.desiredConfiguration == store.stored?.configuration)
        #expect(status.lastMaintenance == .init(
            trigger: .clientConfiguration,
            result: .skipped,
            occurredAt: 100,
            reason: .init(kind: .powerSourceUnreadable)))
        #expect(status.detailReason?.kind == .powerSourceUnreadable)
        #expect(status.currentPercentage == 0)
        #expect(status.isPowerAdapterConnected == false)
        #expect(hardware.writeCount == 0)
        #expect(hardware.releaseAttemptCount == 0)
    }

    @Test func staleGenerationReturnsLatestEncodedStatusWithoutAnotherTransaction() throws {
        let hardware = MockBatteryHardware()
        let store = PolicyStoreSpy()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })
        let service = BatteryDaemonControlService(coordinator: coordinator)
        let accepted = BatteryControlConfigurationRequest(
            configuration: .init(enabled: true, limitPercentage: 80),
            generation: 2)
        let stale = BatteryControlConfigurationRequest(
            configuration: .init(enabled: true, limitPercentage: 90),
            generation: 1)

        let acceptedReply = try service.configure(
            encodedRequest: BatteryControlCodec.encode(accepted),
            currentReading: nil)
        let staleReply = try service.configure(
            encodedRequest: BatteryControlCodec.encode(stale),
            currentReading: nil)
        let acceptedStatus = try BatteryControlCodec.decode(
            BatteryControlServiceStatus.self,
            from: acceptedReply)
        let staleStatus = try BatteryControlCodec.decode(
            BatteryControlServiceStatus.self,
            from: staleReply)

        #expect(staleStatus == acceptedStatus)
        #expect(store.stored?.configuration == accepted.configuration.normalized)
        #expect(store.events.filter { $0 == "save" }.count == 1)
        #expect(hardware.writeCount == 0)
        #expect(hardware.releaseAttemptCount == 0)
    }

    @Test func observedAdapterChangeUsesAdapterTransitionReconciliation() throws {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .allowed
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: PolicyStoreSpy(),
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })
        let service = BatteryDaemonControlService(coordinator: coordinator)
        let request = BatteryControlConfigurationRequest(
            configuration: .init(enabled: true, limitPercentage: 80),
            generation: 1)
        _ = try service.configure(
            encodedRequest: BatteryControlCodec.encode(request),
            currentReading: .init(stateOfCharge: 70, isPluggedIn: true))

        let status = service.sample(
            currentReading: .init(stateOfCharge: 70, isPluggedIn: false),
            force: true)

        #expect(status.lastMaintenance?.trigger == .adapterTransition)
        #expect(status.lastMaintenance?.result == .verified)
        #expect(status.isPowerAdapterConnected == false)
    }

    @Test func unchangedAdapterUsesOrdinarySampleWithoutReplacingMaintenance() throws {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .allowed
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: PolicyStoreSpy(),
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })
        let service = BatteryDaemonControlService(coordinator: coordinator)
        let request = BatteryControlConfigurationRequest(
            configuration: .init(enabled: true, limitPercentage: 80),
            generation: 1)
        let configuredData = try service.configure(
            encodedRequest: BatteryControlCodec.encode(request),
            currentReading: .init(stateOfCharge: 70, isPluggedIn: true))
        let configured = try BatteryControlCodec.decode(
            BatteryControlServiceStatus.self,
            from: configuredData)
        let readsBeforeSample = hardware.readCount

        let status = service.sample(
            currentReading: .init(stateOfCharge: 71, isPluggedIn: true),
            force: true)

        #expect(status.lastMaintenance == configured.lastMaintenance)
        #expect(status.currentPercentage == 71)
        #expect(status.isPowerAdapterConnected)
        #expect(hardware.readCount == readsBeforeSample)
    }

    @Test func startupReadingBecomesTheFallbackForLaterConfiguration() throws {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .allowed
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
        let service = BatteryDaemonControlService(coordinator: coordinator)
        _ = service.restore(currentReading: .init(
            stateOfCharge: 70,
            isPluggedIn: true))
        let request = BatteryControlConfigurationRequest(
            configuration: .init(enabled: true, limitPercentage: 85),
            generation: 1)

        let replyData = try service.configure(
            encodedRequest: BatteryControlCodec.encode(request),
            currentReading: nil)
        let status = try BatteryControlCodec.decode(
            BatteryControlServiceStatus.self,
            from: replyData)

        #expect(status.currentPercentage == 70)
        #expect(status.isPowerAdapterConnected)
        #expect(status.lastMaintenance?.trigger == .clientConfiguration)
        #expect(status.lastMaintenance?.result == .applied)
        #expect(status.detailReason?.kind != .powerSourceUnreadable)
    }

    @Test func wakeReconciliationUsesTheLastReadablePowerState() throws {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .allowed
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: PolicyStoreSpy(),
            engine: BatteryControlEngine(hardware: hardware),
            now: { 100 })
        let service = BatteryDaemonControlService(coordinator: coordinator)
        let request = BatteryControlConfigurationRequest(
            configuration: .init(enabled: true, limitPercentage: 80),
            generation: 1)
        _ = try service.configure(
            encodedRequest: BatteryControlCodec.encode(request),
            currentReading: .init(stateOfCharge: 70, isPluggedIn: true))

        let status = service.reconcileAfterWake(currentReading: nil)

        #expect(status.lastMaintenance?.trigger == .wake)
        #expect(status.lastMaintenance?.result == .verified)
        #expect(status.currentPercentage == 70)
        #expect(status.isPowerAdapterConnected)
    }

    @Test func daemonControlServicePassesTemperatureReadingToCoordinator() {
        let store = PolicyStoreSpy()
        let hw = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: hw)
        let coordinator = BatteryControlCoordinator(ownerUID: 501, store: store, engine: engine, now: { 1000 })
        let service = BatteryDaemonControlService(coordinator: coordinator)

        let reading = BatteryPowerSourceReading(stateOfCharge: 80, isPluggedIn: true, temperatureCelsius: 38.5)
        let status = service.sample(currentReading: reading, force: true)

        #expect(status.batteryTemperatureCelsius == 38.5)
    }

    @Test func daemonControlServiceThreadsTemperatureThroughConfigureAndRestore() throws {
        let store = PolicyStoreSpy()
        let hw = MockBatteryHardware()
        hw.reportedGate = .allowed
        let engine = BatteryControlEngine(hardware: hw)
        let coordinator = BatteryControlCoordinator(ownerUID: 501, store: store, engine: engine, now: { 1000 })
        let service = BatteryDaemonControlService(coordinator: coordinator)

        let restoreReading = BatteryPowerSourceReading(stateOfCharge: 75, isPluggedIn: true, temperatureCelsius: 36.2)
        let restoreStatus = service.restore(currentReading: restoreReading)
        #expect(restoreStatus.batteryTemperatureCelsius == 36.2)

        let configRequest = BatteryControlConfigurationRequest(
            configuration: .init(enabled: true, limitPercentage: 80),
            generation: 1)
        let configReading = BatteryPowerSourceReading(stateOfCharge: 76, isPluggedIn: true, temperatureCelsius: 39.1)
        let replyData = try service.configure(
            encodedRequest: BatteryControlCodec.encode(configRequest),
            currentReading: configReading)
        let configStatus = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: replyData)
        #expect(configStatus.batteryTemperatureCelsius == 39.1)

        let wakeStatus = service.reconcileAfterWake(currentReading: nil)
        #expect(wakeStatus.batteryTemperatureCelsius == 39.1)
    }
}
