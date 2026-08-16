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
}

enum KineticNotchMotion {
    static let frameCount = 7
    static let idleThreshold = 5.0
    private static let phaseOffsets = [-2, -1, 0, 1, 2, 1, 0]
    static func restFrame(load: Double) -> Int {
        Int(((min(max(load, 0), 100) / 100) * Double(frameCount - 1)).rounded())
    }
    static func displayedFrame(load: Double, phase: Int, reduceMotion: Bool) -> Int {
        let rest = restFrame(load: load)
        guard !reduceMotion else { return rest }
        return min(max(rest + phaseOffsets[phase % phaseOffsets.count], 0), frameCount - 1)
    }
    static func frameRate(load: Double, speed: KineticNotchSpeed) -> Double? {
        let load = min(max(load, 0), 100)
        guard load > idleThreshold else { return nil }
        let progress = sqrt((load - idleThreshold) / (100 - idleThreshold))
        return speed.minimumFrameRate + (speed.maximumFrameRate - speed.minimumFrameRate) * progress
    }
}
