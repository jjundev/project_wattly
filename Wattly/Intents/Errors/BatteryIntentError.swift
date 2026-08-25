import Foundation
import AppIntents

public enum BatteryIntentError: Swift.Error, CustomLocalizedStringResourceConvertible, LocalizedError, Sendable, Equatable {
    case helperNotInstalled
    case hardwareUnsupported
    case xpcCommunicationFailed(String)
    case invalidParameter(String)

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .helperNotInstalled:
            return "Wattly 도우미가 설치되지 않았습니다. Wattly 앱 설정에서 도우미를 먼저 설치해주세요."
        case .hardwareUnsupported:
            return "이 Mac은 배터리 충전 제어를 지원하지 않는 하드웨어입니다."
        case .xpcCommunicationFailed(let detail):
            return "도우미와의 통신에 실패했습니다: \(detail)"
        case .invalidParameter(let msg):
            return "유효하지 않은 설정값입니다: \(msg)"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .helperNotInstalled:
            return String(localized: "Wattly 도우미가 설치되지 않았습니다. Wattly 앱 설정에서 도우미를 먼저 설치해주세요.")
        case .hardwareUnsupported:
            return String(localized: "이 Mac은 배터리 충전 제어를 지원하지 않는 하드웨어입니다.")
        case .xpcCommunicationFailed(let detail):
            return String(format: String(localized: "도우미와의 통신에 실패했습니다: %@"), detail)
        case .invalidParameter(let msg):
            return String(format: String(localized: "유효하지 않은 설정값입니다: %@"), msg)
        }
    }
}
