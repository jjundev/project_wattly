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
        switch self { case .eco: 0.75; case .standard: 1.25; case .responsive: 2 }
    }
    var maximumFrameRate: Double {
        switch self { case .eco: 3; case .standard: 5; case .responsive: 7 }
    }
    var description: String {
        switch self {
        case .eco: "낮은 전력으로 부하에 따라 0.75~3 fps로 움직입니다."
        case .standard: "균형 잡힌 반응으로 부하에 따라 1.25~5 fps로 움직입니다."
        case .responsive: "부하 변화에 민감하게 2~7 fps로 움직입니다."
        }
    }
}

enum MenuBarIconMotion {
    static let idleThreshold = 5.0
    static let fluxLoopPhaseDelayMultipliers = [0.92, 0.78, 1.32, 0.96, 0.78, 1.32, 0.92]

    static func displayedFrame(style: MenuBarIconStyle, phase: Int, reduceMotion: Bool) -> Int {
        guard !reduceMotion else { return style.staticFrame }
        let count = style.frameCount
        return ((phase % count) + count) % count
    }

    static func phaseDelayMultiplier(style: MenuBarIconStyle, phase: Int) -> Double {
        if style == .fluxLoop {
            let count = fluxLoopPhaseDelayMultipliers.count
            return fluxLoopPhaseDelayMultipliers[((phase % count) + count) % count]
        }
        return 1.0
    }

    static func frameDelay(style: MenuBarIconStyle, phase: Int, frameRate: Double) -> TimeInterval {
        phaseDelayMultiplier(style: style, phase: phase) / frameRate
    }

    static func frameRate(load: Double, speed: KineticNotchSpeed) -> Double? {
        let load = min(max(load, 0), 100)
        guard load > idleThreshold else { return nil }
        let progress = sqrt((load - idleThreshold) / (100 - idleThreshold))
        return speed.minimumFrameRate + (speed.maximumFrameRate - speed.minimumFrameRate) * progress
    }
}

/// Backward-compatible wrapper for Flux Loop / Kinetic Notch
enum KineticNotchMotion {
    static let frameCount = 7
    static let idleThreshold = MenuBarIconMotion.idleThreshold
    static let staticFrame = 0
    static let rightEdgePhase = 2
    static let leftEdgePhase = 5

    static func displayedFrame(phase: Int, reduceMotion: Bool) -> Int {
        MenuBarIconMotion.displayedFrame(style: .fluxLoop, phase: phase, reduceMotion: reduceMotion)
    }

    static func phaseDelayMultiplier(phase: Int) -> Double {
        MenuBarIconMotion.phaseDelayMultiplier(style: .fluxLoop, phase: phase)
    }

    static func frameDelay(phase: Int, frameRate: Double) -> TimeInterval {
        MenuBarIconMotion.frameDelay(style: .fluxLoop, phase: phase, frameRate: frameRate)
    }

    static func frameRate(load: Double, speed: KineticNotchSpeed) -> Double? {
        MenuBarIconMotion.frameRate(load: load, speed: speed)
    }
}
