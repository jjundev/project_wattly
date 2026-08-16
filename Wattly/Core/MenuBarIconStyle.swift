import Foundation

public enum MenuBarIconStyle: String, CaseIterable, Identifiable, Sendable {
    case turbine = "turbine"             // 1. 쿨링 터빈
    case pulseWave = "pulseWave"         // 2. 흐르는 펄스 W 파형
    case cube3D = "cube3D"               // 3. 3D 와이어프레임 큐브
    case thermalBubble = "thermalBubble" // 4. 열 대류 버블

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .turbine: "쿨링 터빈"
        case .pulseWave: "펄스 웨이브"
        case .cube3D: "3D 큐브"
        case .thermalBubble: "열 대류 버블"
        }
    }

    public var category: String {
        switch self {
        case .turbine: "쿨링 / 팬"
        case .pulseWave: "전력 / 신호"
        case .cube3D: "3D 기하학"
        case .thermalBubble: "열역학"
        }
    }

    public var summary: String {
        switch self {
        case .turbine: "맥북 쿨링 팬 블레이드가 부하에 맞춰 고속 회전합니다."
        case .pulseWave: "Wattly 시그니처 W 파형이 좌에서 우로 전파되며 전력 부하에 따라 가속됩니다."
        case .cube3D: "3차원 대각선 축을 기준으로 와이어프레임 큐브가 자전합니다."
        case .thermalBubble: "하단에서 상단으로 열 배출 기포 파티클이 상승합니다."
        }
    }

    public var frameCount: Int {
        switch self {
        case .turbine, .pulseWave, .cube3D, .thermalBubble:
            return 24
        }
    }

    public var staticFrame: Int { 0 }
}
