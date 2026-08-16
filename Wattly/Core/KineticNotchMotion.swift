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

    static func displayedFrame(style: MenuBarIconStyle, phase: Int, load: Double? = nil, reduceMotion: Bool) -> Int {
        guard !reduceMotion else { return style.staticFrame }
        let count = style.frameCount

        // Gauge-type meter styles (e.g. VU Meter) move needle from left to right as load increases
        if style == .vuMeter, let load {
            let clampedLoad = min(max(load, 0), 100)
            let baseIndex = (clampedLoad / 100.0) * Double(count - 1)
            let jitter = sin(Double(phase) * 0.8) * (0.5 + (clampedLoad / 100.0) * 1.5)
            let target = Int(round(baseIndex + jitter))
            return min(max(target, 0), count - 1)
        }

        // Digital Equalizer dynamically scales bar heights based on workload tier (4 tiers x 6 subphases)
        if style == .equalizer, let load {
            let clampedLoad = min(max(load, 0), 100)
            let tier = min(Int(clampedLoad / 25.0), 3) // Tier 0 (low) ~ Tier 3 (max load)
            let subPhase = ((phase % 6) + 6) % 6
            return tier * 6 + subPhase
        }

        return ((phase % count) + count) % count
    }

    static func displayedFrame(style: MenuBarIconStyle, phase: Int, reduceMotion: Bool) -> Int {
        displayedFrame(style: style, phase: phase, load: nil, reduceMotion: reduceMotion)
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
