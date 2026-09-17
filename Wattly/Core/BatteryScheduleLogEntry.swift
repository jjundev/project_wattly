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
        case calibrationRunning = "배터리 캘리브레이션 진행 중"
        /// 네이티브 충전 제한 백엔드(macOS 27)는 상한 하나가 전부라 "충전 일시 정지"를 표현할 수 없다.
        case unsupportedOnNativeLimit = "이 macOS에서는 충전 일시 중지를 사용할 수 없음"

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
            case .calibrationRunning:
                return String(localized: "배터리 캘리브레이션 진행 중")
            case .unsupportedOnNativeLimit:
                return String(localized: "이 macOS에서는 충전 일시 중지를 사용할 수 없음")
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
