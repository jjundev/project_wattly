import Foundation

enum KineticNotchSource: String, CaseIterable, Identifiable, Sendable {
    case cpu, gpu, cpuGPU
    var id: String { rawValue }
    var label: String {
        switch self { case .cpu: "CPU"; case .gpu: "GPU"; case .cpuGPU: "CPU + GPU" }
    }
    var requiredCards: Set<CardKind> {
        switch self { case .cpu: [.cpu]; case .gpu: [.gpu]; case .cpuGPU: [.cpu, .gpu] }
    }
    func load(cpu: Double?, gpu: Double?) -> Double? {
        func valid(_ value: Double?) -> Double? {
            guard let value, value.isFinite else { return nil }
            return min(max(value, 0), 100)
        }
        switch self {
        case .cpu: return valid(cpu)
        case .gpu: return valid(gpu)
        case .cpuGPU:
            guard let cpu = valid(cpu), let gpu = valid(gpu) else { return nil }
            return (cpu + gpu) / 2
        }
    }
}

enum KineticNotchSpeed: String, CaseIterable, Identifiable, Sendable {
    case eco, standard, responsive
    var id: String { rawValue }
    var label: String {
        switch self { case .eco: "절전"; case .standard: "표준"; case .responsive: "민감" }
    }
    var minimumFrameRate: Double {
        switch self { case .eco: 6.0; case .standard: 8.0; case .responsive: 12.0 }
    }
    var maximumFrameRate: Double {
        switch self { case .eco: 36.0; case .standard: 48.0; case .responsive: 60.0 }
    }
    var description: String {
        switch self {
        case .eco: "낮은 전력으로 부하에 따라 6~36 fps로 부드럽게 움직입니다."
        case .standard: "균형 잡힌 반응으로 부하에 따라 8~48 fps로 매끄럽게 움직입니다."
        case .responsive: "부하 변화에 민감하게 12~60 fps의 고주사율로 움직입니다."
        }
    }
}

enum MenuBarIconMotion {
    static let idleThreshold = 5.0

    static func displayedFrame(style: MenuBarIconStyle, phase: Int, reduceMotion: Bool) -> Int {
        guard !reduceMotion else { return style.staticFrame }
        let count = style.frameCount
        return ((phase % count) + count) % count
    }

    static func phaseDelayMultiplier(style: MenuBarIconStyle, phase: Int) -> Double {
        1.0
    }

    static func frameDelay(style: MenuBarIconStyle, phase: Int, frameRate: Double) -> TimeInterval {
        1.0 / frameRate
    }

    static func frameRate(load: Double, speed: KineticNotchSpeed) -> Double? {
        let load = min(max(load, 0), 100)
        guard load > idleThreshold else { return nil }
        let progress = sqrt((load - idleThreshold) / (100 - idleThreshold))
        return speed.minimumFrameRate + (speed.maximumFrameRate - speed.minimumFrameRate) * progress
    }
}
