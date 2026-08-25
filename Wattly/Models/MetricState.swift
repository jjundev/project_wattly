import Foundation

/// Per-provider state held by `SystemMonitor`. The data-bearing case wraps the
/// single boundary type, `MetricSample`.
enum MetricState: Sendable, Equatable {
    case loading
    case value(MetricSample)
    case unavailable(MetricUnavailableReason)
}

/// What a provider returns each poll. `MetricSample` is the sole *data* payload;
/// the other two cases are the failure / not-ready control channels (so the
/// provider never has to know about the UI-facing `.loading` state).
enum ProviderReading: Sendable, Equatable {
    case value(MetricSample)
    case unavailable(MetricUnavailableReason)
    case pending   // cold warm-up: monitor keeps the card in `.loading`
}

/// Typed reason a card is unavailable — drives distinct copy + icon per case
/// (the prototype renders a different card per reason, lines 684–685). A plain
/// `String` could not carry that branch, which is why this is an enum (L5).
enum MetricUnavailableReason: Sendable, Equatable {
    case notPresent(String)          // e.g. battery on a desktop Mac
    case channelUnreadable(String)   // e.g. IOReport Energy Model group
    case temperature(TemperatureError)
    case providerError(String)

    /// Full copy (prototype wording where it exists).
    var message: String {
        switch self {
        case .notPresent(let s): s
        case .channelUnreadable(let s): s
        case .temperature(let e): e.message
        case .providerError(let s): s
        }
    }

    /// Short copy for compact rows (prototype `reasonShort`).
    var shortMessage: String {
        switch self {
        case .notPresent: String(localized: "사용 불가")
        case .channelUnreadable: String(localized: "읽기 불가")
        case .temperature(let e): e.shortMessage
        case .providerError: String(localized: "오류")
        }
    }
}

extension TemperatureError {
    var message: String {
        switch self {
        case .connectionFailed: String(localized: "센서에 연결할 수 없음 — 재시도 중")
        case .readFailed: String(localized: "센서 읽기 실패 — 재시도 중")
        case .unsupportedChip: String(localized: "이 칩에서 검증된 온도 프로파일 없음")
        case .noVerifiedProfile: String(localized: "검증된 온도 프로파일 없음")
        case .unsupportedDataType: String(localized: "지원되지 않는 센서 데이터 형식")
        case .invalidReadings: String(localized: "유효하지 않은 센서 값")
        }
    }

    var shortMessage: String {
        switch self {
        case .connectionFailed, .readFailed: String(localized: "재시도 중")
        case .unsupportedChip, .noVerifiedProfile: String(localized: "미지원")
        case .unsupportedDataType: String(localized: "형식 미지원")
        case .invalidReadings: String(localized: "값 오류")
        }
    }
}
