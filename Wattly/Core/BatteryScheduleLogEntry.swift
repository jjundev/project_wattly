import Foundation

public struct BatteryScheduleLogEntry: Identifiable, Codable, Equatable, Sendable {
    public enum Status: Codable, Equatable, Sendable {
        case success
        case skipped(reason: SkipReason)
        case failed(reason: String)

        public var localizedDescription: String {
            switch self {
            case .success:
                return String(localized: "성공")
            case .skipped(let reason):
                return reason.localizedDescription
            case .failed(let reason):
                return String(format: String(localized: "실패: %@"), reason)
            }
        }
    }

    public enum SkipReason: String, Codable, Equatable, Sendable {
        case adapterDisconnected = "어댑터 미연결"
        case catchUpWindowExpired = "잠자기 유효 시간 초과"
        case overriddenByHigherPriority = "동일 시각 상위 작업 우선"
        case heatProtectionActive = "발열 보호 작동 중"

        public var localizedDescription: String {
            switch self {
            case .adapterDisconnected:
                return String(localized: "어댑터 미연결")
            case .catchUpWindowExpired:
                return String(localized: "잠자기 유효 시간 초과")
            case .overriddenByHigherPriority:
                return String(localized: "동일 시각 상위 작업 우선")
            case .heatProtectionActive:
                return String(localized: "발열 보호 작동 중")
            }
        }
    }

    public var id: UUID
    public var scheduleId: UUID?
    public var scheduleName: String
    public var actionSummary: String
    public var timestamp: Date
    public var status: Status
    public var batteryPercentage: Int
    public var isPluggedIn: Bool

    public init(
        id: UUID = UUID(),
        scheduleId: UUID? = nil,
        scheduleName: String,
        actionSummary: String,
        timestamp: Date = Date(),
        status: Status,
        batteryPercentage: Int,
        isPluggedIn: Bool
    ) {
        self.id = id
        self.scheduleId = scheduleId
        self.scheduleName = scheduleName
        self.actionSummary = actionSummary
        self.timestamp = timestamp
        self.status = status
        self.batteryPercentage = batteryPercentage
        self.isPluggedIn = isPluggedIn
    }
}
