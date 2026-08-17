import Foundation

public enum MenuBarIconStyle: String, CaseIterable, Identifiable, Sendable {
    case turbine = "turbine"             // 1. 쿨링 터빈
    case pulseWave = "pulseWave"         // 2. 흐르는 펄스 W 파형
    case vuMeter = "vuMeter"             // 3. VU 파워 미터
    case cube3D = "cube3D"               // 4. 3D 와이어프레임 큐브
    case equalizer = "equalizer"         // 5. 디지털 이퀄라이저
    case hillRunner = "hillRunner"       // 6. 경사로 러너 (Hill Runner)

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .turbine: "쿨링 터빈"
        case .pulseWave: "펄스 웨이브"
        case .vuMeter: "VU 파워 미터"
        case .cube3D: "3D 큐브"
        case .equalizer: "디지털 이퀄라이저"
        case .hillRunner: "러너 (경사로 질주)"
        }
    }

    public var category: String {
        switch self {
        case .turbine: "쿨링 / 팬"
        case .pulseWave: "전력 / 신호"
        case .vuMeter: "정밀 계측기"
        case .cube3D: "3D 기하학"
        case .equalizer: "디지털 스펙트럼"
        case .hillRunner: "캐릭터 / 라이프"
        }
    }

    public var summary: String {
        switch self {
        case .turbine: "맥북 쿨링 팬 블레이드가 부하에 맞춰 고속 회전합니다."
        case .pulseWave: "Wattly 시그니처 W 파형이 좌에서 우로 전파되며 전력 부하에 따라 가속됩니다."
        case .vuMeter: "아날로그 전력 계측기 바늘이 전력량에 맞춰 기민하게 스윙합니다."
        case .cube3D: "3차원 대각선 축을 기준으로 와이어프레임 큐브가 자전합니다."
        case .equalizer: "4개의 수직 디지털 바가 연산 및 전력 부하에 맞춰 상하 바운스합니다."
        case .hillRunner: "부하(0%~100%)에 따라 오르막 힘겨운 걸음 → 평지 조깅 → 내리막 폭풍 질주로 지형 경사와 캐릭터 자세가 연속 전환됩니다."
        }
    }

    public var frameCount: Int {
        switch self {
        case .pulseWave:
            return 96 // 4 부하 티어 (1W 저진폭 ~ 풀로드 고진폭) x 24 고해상도 위상 프레임
        case .turbine, .vuMeter, .cube3D, .equalizer, .hillRunner:
            return 24
        }
    }

    public var staticFrame: Int {
        switch self {
        case .hillRunner:
            return 8
        default:
            return 0
        }
    }
}

