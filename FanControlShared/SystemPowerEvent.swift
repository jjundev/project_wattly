public enum SystemPowerEvent: Equatable, Sendable {
    case canSleep
    case willSleep
    case willPowerOn
    case hasPoweredOn
}

public struct SystemPowerEventAction: Equatable, Sendable {
    public var releaseFans: Bool
    public var reconcileBattery: Bool
    public var acknowledge: Bool

    public init(
        releaseFans: Bool,
        reconcileBattery: Bool,
        acknowledge: Bool
    ) {
        self.releaseFans = releaseFans
        self.reconcileBattery = reconcileBattery
        self.acknowledge = acknowledge
    }
}

public enum SystemPowerEventPolicy {
    public static func action(for event: SystemPowerEvent) -> SystemPowerEventAction {
        switch event {
        case .canSleep:
            .init(releaseFans: false, reconcileBattery: false, acknowledge: true)
        case .willSleep:
            .init(releaseFans: true, reconcileBattery: false, acknowledge: true)
        case .willPowerOn:
            .init(releaseFans: false, reconcileBattery: false, acknowledge: false)
        case .hasPoweredOn:
            .init(releaseFans: false, reconcileBattery: true, acknowledge: false)
        }
    }
}
