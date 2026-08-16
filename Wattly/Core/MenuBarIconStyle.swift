import Foundation

public enum MenuBarIconStyle: String, CaseIterable, Identifiable, Sendable {
    case turbine = "turbine"             // 1. 쿨링 터빈
    case gears = "gears"                 // 2. 듀얼 인터로킹 기어
    case pulseWave = "pulseWave"         // 3. 흐르는 펄스 W 파형
    case atomicOrbit = "atomicOrbit"     // 4. 원자 궤도
    case cube3D = "cube3D"               // 5. 3D 와이어프레임 큐브
    case infinityLoop = "infinityLoop"   // 6. 뫼비우스 인피니티
    case tapeReel = "tapeReel"           // 7. 레트로 테이프 릴
    case thermalBubble = "thermalBubble" // 8. 열 대류 버블
    case fluxLoop = "fluxLoop"           // 9. 플럭스 루프 (Kinetic Notch)

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .turbine: "쿨링 터빈"
        case .gears: "듀얼 기어"
        case .pulseWave: "펄스 웨이브"
        case .atomicOrbit: "원자 궤도"
        case .cube3D: "3D 큐브"
        case .infinityLoop: "뫼비우스 루프"
        case .tapeReel: "테이프 릴"
        case .thermalBubble: "열 대류 버블"
        case .fluxLoop: "플럭스 루프"
        }
    }

    public var category: String {
        switch self {
        case .turbine: "쿨링 / 팬"
        case .gears: "기계 메커니즘"
        case .pulseWave: "전력 / 신호"
        case .atomicOrbit: "에너지 물리"
        case .cube3D: "3D 기하학"
        case .infinityLoop: "유체 모션"
        case .tapeReel: "레트로 컴퓨팅"
        case .thermalBubble: "열역학"
        case .fluxLoop: "노치 루프"
        }
    }

    public var summary: String {
        switch self {
        case .turbine: "맥북 쿨링 팬 블레이드가 부하에 맞춰 고속 회전합니다."
        case .gears: "맞물린 2개의 기어가 서로 반대 방향으로 회전하며 연산 작업을 시각화합니다."
        case .pulseWave: "Wattly 시그니처 W 파형이 좌에서 우로 전파되며 전력 부하에 따라 가속됩니다."
        case .atomicOrbit: "중앙 핵 주위의 2개 타원 궤도를 따라 전자가 고속 순환합니다."
        case .cube3D: "3차원 대각선 축을 기준으로 와이어프레임 큐브가 자전합니다."
        case .infinityLoop: "무한대(∞) 궤적을 따라 유체 에너지 파티클이 순환합니다."
        case .tapeReel: "클래식 메인프레임의 마그네틱 테이프 릴이 연동 회전합니다."
        case .thermalBubble: "하단에서 상단으로 열 배출 기포 파티클이 상승합니다."
        case .fluxLoop: "맥북 노치 형태의 트랙을 따라 에너지 점이 순환합니다."
        }
    }

    public var frameCount: Int {
        switch self {
        case .turbine: 24
        case .gears: 24
        case .pulseWave: 24
        case .atomicOrbit: 24
        case .cube3D: 24
        case .infinityLoop: 24
        case .tapeReel: 24
        case .thermalBubble: 24
        case .fluxLoop: 14
        }
    }

    public var staticFrame: Int { 0 }
}
