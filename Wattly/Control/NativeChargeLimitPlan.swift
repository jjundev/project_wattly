import Foundation

/// `PowerUISmartChargeClient.isMCLCurrentlyEnabled:`가 돌려주는 원시값. 실측(macOS 27.0,
/// 26A428): 0 = 꺼짐, 1 = 켜짐, 3 = "이번만 완충" 일시 해제. 2와 그 밖의 값은 본 적이 없어
/// 의미를 추측하지 않고 그대로 들고 다닌다.
enum NativeLimitEnabledState: Equatable, Sendable {
    case off
    case on
    case temporarilyDisabled
    case unknown(UInt64)

    init(rawState: UInt64) {
        switch rawState {
        case 0: self = .off
        case 1: self = .on
        case 3: self = .temporarilyDisabled
        default: self = .unknown(rawState)
        }
    }
}

/// 네이티브 제한을 한 번 읽은 결과. `limit`은 일시 해제 중에는 100으로 가려진다 — 사용자가
/// 원한 값은 서비스가 따로 기억한다.
struct NativeLimitSnapshot: Equatable, Sendable {
    var limit: Int
    var state: NativeLimitEnabledState
}

enum NativeLimitCommand: Equatable, Sendable {
    case none
    case setLimit(Int)
    case temporarilyDisable
    /// Wattly가 건 제한을 푼다. 실행은 `setLimit(releaseLimit)`이지만 소유 플래그를 내리는
    /// 부수 효과가 달라 별도 케이스다.
    case release
}

/// 설정과 네이티브 상태를 보고 다음에 쓸 명령 하나를 고른다. 순수 함수 — I/O도 시계도 없다.
enum NativeChargeLimitPlan {
    /// `availableChargeLimitsWithError:`를 못 읽었을 때 쓰는 목록. 실측값 그대로다.
    static let fallbackLimits = [80, 85, 90, 95, 100]
    /// 이 값을 쓰면 네이티브 제한이 스스로 꺼진다(실측: `setMCLLimit:100` → enabled 0).
    static let releaseLimit = 100

    /// 요청값 이상인 최소 허용값. API는 목록 밖 값을 `PowerUISmartChargingErrorDomain Code=4`로
    /// 거부하므로 쓰기 전에 여기서 맞춘다. 내림이 아니라 올림인 이유: 단축어가 70을 요청했을 때
    /// "요청보다 덜 충전"은 이 API로 불가능하고, 가장 가까운 가능한 값은 80이다.
    static func snapped(_ requested: Int, to available: [Int]) -> Int {
        let candidates = available.isEmpty ? fallbackLimits : available
        return candidates.sorted().first { $0 >= requested } ?? releaseLimit
    }

    static func command(
        configuration: BatteryControlConfiguration,
        isPluggedIn: Bool,
        native: NativeLimitSnapshot,
        ownsNativeLimit: Bool,
        availableLimits: [Int]
    ) -> NativeLimitCommand {
        // Top Up은 어댑터가 있어야 의미가 있다. 없으면 평소 제한 경로로 떨어져 제한을 다시 건다 —
        // 일시 해제는 어댑터 분리로도 스스로 풀리지 않기 때문에(실측) 여기서 풀어 줘야 한다.
        if configuration.topUpActive, isPluggedIn {
            return native.state == .on ? .temporarilyDisable : .none
        }
        guard configuration.enabled else {
            return ownsNativeLimit ? .release : .none
        }
        let target = snapped(configuration.clampedLimitPercentage, to: availableLimits)
        if target >= releaseLimit {
            return native.state == .off ? .none : .setLimit(releaseLimit)
        }
        if native.state == .on, native.limit == target { return .none }
        return .setLimit(target)
    }
}
