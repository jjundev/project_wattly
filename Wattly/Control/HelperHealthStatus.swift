import Foundation

enum HelperHealthState: Equatable, Sendable {
    case checking
    case notInstalled
    case running
    case updateAvailable(reason: String)
    case unavailable(detail: String)
    case ownershipMismatch(ownerUID: UInt32)
    case installing

    var isActionable: Bool {
        switch self {
        case .checking, .installing: false
        case .notInstalled, .running, .updateAvailable, .unavailable, .ownershipMismatch: true
        }
    }
}

struct HelperDiagnosticDetails: Equatable, Sendable {
    var installedOwnership: FanHelperInstaller.InstalledOwnership
    var currentUID: UInt32
    var batteryMode: BatteryControlServiceMode
    var fanMode: FanControlServiceMode
    var installedBinaryExists: Bool
    var bundledBinaryExists: Bool
    var binaryMatch: Bool?
    var capabilities: [BatteryControlCapability]?
    var missingCapabilities: [BatteryControlCapability]
    var checkedAt: Date

    init(
        installedOwnership: FanHelperInstaller.InstalledOwnership = .notInstalled,
        currentUID: UInt32 = UInt32(getuid()),
        batteryMode: BatteryControlServiceMode = .unavailable,
        fanMode: FanControlServiceMode = .unavailable,
        installedBinaryExists: Bool = false,
        bundledBinaryExists: Bool = false,
        binaryMatch: Bool? = nil,
        capabilities: [BatteryControlCapability]? = nil,
        missingCapabilities: [BatteryControlCapability] = [],
        checkedAt: Date = Date()
    ) {
        self.installedOwnership = installedOwnership
        self.currentUID = currentUID
        self.batteryMode = batteryMode
        self.fanMode = fanMode
        self.installedBinaryExists = installedBinaryExists
        self.bundledBinaryExists = bundledBinaryExists
        self.binaryMatch = binaryMatch
        self.capabilities = capabilities
        self.missingCapabilities = missingCapabilities
        self.checkedAt = checkedAt
    }
}

enum HelperHealthStatus {
    static let requiredCapabilities: [BatteryControlCapability] = [
        .persistedPolicyV1,
        .hardwareGateReadbackV1,
        .systemPowerEventsV1
    ]

    static func resolve(
        ownership: FanHelperInstaller.InstalledOwnership,
        currentUID: UInt32 = UInt32(getuid()),
        batteryMode: BatteryControlServiceMode,
        fanMode: FanControlServiceMode,
        bundledBinaryExists: Bool,
        installedBinaryExists: Bool,
        binaryMatch: Bool?,
        capabilities: [BatteryControlCapability]?
    ) -> HelperHealthState {
        // 1. Not installed if plist is absent or installed binary file doesn't exist
        if ownership == .notInstalled || !installedBinaryExists {
            return .notInstalled
        }

        // 2. Ownership mismatch
        switch ownership {
        case .owner(let ownerUID) where ownerUID != currentUID:
            return .ownershipMismatch(ownerUID: ownerUID)
        case .invalidMetadata:
            return .ownershipMismatch(ownerUID: 0)
        case .notInstalled, .owner:
            break
        }

        // 3. XPC Communication availability
        let isBatteryAlive = batteryMode != .unavailable
        let isFanAlive = fanMode != .unavailable
        guard isBatteryAlive || isFanAlive else {
            return .unavailable(detail: String(localized: "도우미에 연결되지 않음"))
        }

        // 4. Missing capabilities
        if let capabilities {
            let missing = requiredCapabilities.filter { !capabilities.contains($0) }
            if !missing.isEmpty {
                return .updateAvailable(reason: String(localized: "필수 기능(하드웨어 게이트 / 시스템 전원 감지) 업데이트 필요"))
            }
        } else if isBatteryAlive {
            // Battery responded but sent no capabilities -> legacy helper
            return .updateAvailable(reason: String(localized: "구버전 도우미가 설치되어 있습니다"))
        }

        // 5. Binary file difference
        if binaryMatch == false {
            return .updateAvailable(reason: String(localized: "최신 앱 번들 도우미 바이너리 업데이트 사용 가능"))
        }

        return .running
    }
}
