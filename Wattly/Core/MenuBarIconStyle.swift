import Foundation

public enum MenuBarIconStyle: String, CaseIterable, Identifiable, Sendable {
    case turbine = "turbine"             // 1. 쿨링 터빈
    case pulseWave = "pulseWave"         // 2. 흐르는 펄스 W 파형
    case vuMeter = "vuMeter"             // 3. VU 파워 미터
    case cube3D = "cube3D"               // 4. 3D 와이어프레임 큐브
    case thermalBubble = "thermalBubble" // 5. 열 대류 버블
    case equalizer = "equalizer"         // 6. 디지털 이퀄라이저

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .turbine: "쿨링 터빈"
        case .pulseWave: "펄스 웨이브"
        case .vuMeter: "VU 파워 미터"
        case .cube3D: "3D 큐브"
        case .thermalBubble: "열 대류 버블"
        case .equalizer: "디지털 이퀄라이저"
        }
    }

    public var category: String {
        switch self {
        case .turbine: "쿨링 / 팬"
        case .pulseWave: "전력 / 신호"
        case .vuMeter: "정밀 계측기"
        case .cube3D: "3D 기하학"
        case .thermalBubble: "열역학"
        case .equalizer: "디지털 스펙트럼"
        }
    }

    public var summary: String {
        switch self {
        case .turbine: "맥북 쿨링 팬 블레이드가 부하에 맞춰 고속 회전합니다."
        case .pulseWave: "Wattly 시그니처 W 파형이 좌에서 우로 전파되며 전력 부하에 따라 가속됩니다."
        case .vuMeter: "아날로그 전력 계측기 바늘이 전력량에 맞춰 기민하게 스윙합니다."
        case .cube3D: "3차원 대각선 축을 기준으로 와이어프레임 큐브가 자전합니다."
        case .thermalBubble: "하단에서 상단으로 열 배출 기포 파티클이 상승합니다."
        case .equalizer: "4개의 수직 디지털 바가 연산 및 전력 부하에 맞춰 상하 바운스합니다."
        }
    }

    public var frameCount: Int {
        switch self {
        case .turbine, .pulseWave, .vuMeter, .cube3D, .thermalBubble, .equalizer:
            return 24
        }
    }

    public var staticFrame: Int { 0 }
}
