import Foundation

public struct BatteryPowerSourceReading: Equatable, Sendable {
    public let stateOfCharge: Int
    public let isPluggedIn: Bool
    public let temperatureCelsius: Double?

    public init(stateOfCharge: Int, isPluggedIn: Bool, temperatureCelsius: Double? = nil) {
        self.stateOfCharge = stateOfCharge
        self.isPluggedIn = isPluggedIn
        self.temperatureCelsius = temperatureCelsius
    }
}

/// Serial daemon-facing orchestration for battery XPC requests and power samples.
public final class BatteryDaemonControlService {
    private let coordinator: BatteryControlCoordinator
    private var lastGeneration: UInt64 = 0
    private var lastPowerReading: BatteryPowerSourceReading?

    public init(coordinator: BatteryControlCoordinator) {
        self.coordinator = coordinator
    }

    @discardableResult
    public func restore(
        currentReading: BatteryPowerSourceReading?
    ) -> BatteryControlServiceStatus {
        guard let currentReading else {
            return coordinator.restoreWithoutPowerReading()
        }
        lastPowerReading = currentReading
        return coordinator.restore(
            currentSoC: currentReading.stateOfCharge,
            isPluggedIn: currentReading.isPluggedIn,
            temperatureCelsius: currentReading.temperatureCelsius)
    }

    public func configure(
        encodedRequest: Data,
        currentReading: BatteryPowerSourceReading?
    ) throws -> Data {
        let request = try BatteryControlCodec.decode(
            BatteryControlConfigurationRequest.self,
            from: encodedRequest)
        guard request.generation > lastGeneration else {
            return try BatteryControlCodec.encode(coordinator.latestStatus)
        }
        lastGeneration = request.generation
        let status: BatteryControlServiceStatus
        if let reading = currentReading ?? lastPowerReading {
            lastPowerReading = reading
            status = coordinator.configure(
                request.configuration,
                trigger: .clientConfiguration,
                currentSoC: reading.stateOfCharge,
                isPluggedIn: reading.isPluggedIn,
                temperatureCelsius: reading.temperatureCelsius)
        } else {
            status = coordinator.configureWithoutPowerReading(
                request.configuration,
                trigger: .clientConfiguration)
        }
        return try BatteryControlCodec.encode(status)
    }

    @discardableResult
    public func sample(
        currentReading: BatteryPowerSourceReading?,
        force: Bool = false
    ) -> BatteryControlServiceStatus {
        guard force || coordinator.needsSampling else {
            return coordinator.latestStatus
        }
        guard let reading = currentReading ?? lastPowerReading else {
            return coordinator.latestStatus
        }
        let adapterChanged = lastPowerReading?.isPluggedIn != reading.isPluggedIn
        lastPowerReading = reading
        if adapterChanged {
            return coordinator.reconcile(
                trigger: .adapterTransition,
                currentSoC: reading.stateOfCharge,
                isPluggedIn: reading.isPluggedIn,
                temperatureCelsius: reading.temperatureCelsius)
        }
        return coordinator.sample(
            currentSoC: reading.stateOfCharge,
            isPluggedIn: reading.isPluggedIn,
            temperatureCelsius: reading.temperatureCelsius)
    }

    @discardableResult
    public func reconcileAfterWake(
        currentReading: BatteryPowerSourceReading?
    ) -> BatteryControlServiceStatus {
        guard let reading = currentReading ?? lastPowerReading else {
            return coordinator.latestStatus
        }
        lastPowerReading = reading
        return coordinator.reconcile(
            trigger: .wake,
            currentSoC: reading.stateOfCharge,
            isPluggedIn: reading.isPluggedIn,
            temperatureCelsius: reading.temperatureCelsius)
    }
}
