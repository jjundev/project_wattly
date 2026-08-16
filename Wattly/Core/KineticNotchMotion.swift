import Foundation

enum KineticNotchSource: String, CaseIterable, Identifiable, Sendable {
    case power
    case cpuClock
    case compute

    var id: String { rawValue }

    var label: String {
        switch self {
        case .power: "전력 소비"
        case .cpuClock: "CPU 클럭"
        case .compute: "CPU + GPU"
        }
    }

    var requiredCards: Set<CardKind> {
        switch self {
        case .power: [.power]
        case .cpuClock: [.cpu]
        case .compute: [.cpu, .gpu]
        }
    }

    /// Resolves target full-load package wattage based on hardware cooling/form factor.
    /// MacBook Air (fanless) sustains ~10-15W under throttling, mapped to 20W for responsive 100% full-load motion.
    static func targetWatts(gpuCores: Int?, fanCount: Int?, model: String? = nil) -> Double {
        if let fanCount, fanCount == 0 { return 20.0 }
        let cores = gpuCores ?? 8
        if cores >= 48 { return 200.0 } // Ultra
        if cores >= 24 { return 100.0 } // Max
        if cores >= 14 { return 55.0 }  // Pro
        // Base Pro / Mac mini (with fans) vs fallback
        return (fanCount ?? 0) > 0 ? 30.0 : 20.0
    }

    static func normalizePower(watts: Double, targetWatts: Double) -> Double {
        guard watts.isFinite, targetWatts > 0 else { return 0 }
        return min(max(watts / targetWatts * 100.0, 0), 100.0)
    }

    static func normalizeCPUClock(activeGHz: Double, baseGHz: Double = 0.8, maxGHz: Double = 4.0) -> Double {
        guard activeGHz.isFinite, maxGHz > baseGHz else { return 0 }
        return min(max((activeGHz - baseGHz) / (maxGHz - baseGHz) * 100.0, 0), 100.0)
    }

    static func normalizeCompute(cpu: Double?, gpu: Double?) -> Double? {
        func valid(_ value: Double?) -> Double? {
            guard let value, value.isFinite else { return nil }
            return min(max(value, 0), 100)
        }
        guard let c = valid(cpu), let g = valid(gpu) else { return nil }
        return (c + g) / 2.0
    }

    func load(power: Double? = nil,
              cpuClockGHz: Double? = nil,
              cpu: Double? = nil,
              gpu: Double? = nil,
              gpuCores: Int? = nil,
              fanCount: Int? = nil) -> Double? {
        switch self {
        case .power:
            guard let power, power.isFinite else { return nil }
            let target = Self.targetWatts(gpuCores: gpuCores, fanCount: fanCount)
            return Self.normalizePower(watts: power, targetWatts: target)
        case .cpuClock:
            guard let cpuClockGHz, cpuClockGHz.isFinite else { return nil }
            return Self.normalizeCPUClock(activeGHz: cpuClockGHz)
        case .compute:
            return Self.normalizeCompute(cpu: cpu, gpu: gpu)
        }
    }
}

enum KineticNotchSpeed: String, CaseIterable, Identifiable, Sendable {
    case eco, standard, responsive
    var id: String { rawValue }
    var label: String {
        switch self { case .eco: "절전"; case .standard: "표준"; case .responsive: "민감" }
    }
    var targetFPS: Double {
        switch self { case .eco: 15.0; case .standard: 30.0; case .responsive: 60.0 }
    }
    var description: String {
        switch self {
        case .eco: "15 fps 주사율로 배터리를 극도로 아끼며 부드럽게 회전합니다. (회전 속도는 부하에 일정)"
        case .standard: "30 fps 주사율로 부드럽고 균형 잡힌 모션을 제공합니다."
        case .responsive: "60 fps 고주사율로 ProMotion급의 극도로 부드러운 모션을 제공합니다."
        }
    }
}

enum MenuBarIconMotion {
    static let rpsMin = 0.25 // 1 rev per 4.0s at 0% idle load
    static let rpsMax = 2.50 // 1 rev per 0.4s at 100% full load

    /// Physical rotation speed in revolutions per second (RPS), solely determined by workload.
    static func revolutionsPerSecond(load: Double) -> Double {
        let clampedLoad = min(max(load, 0), 100)
        let progress = sqrt(clampedLoad / 100.0)
        return rpsMin + (rpsMax - rpsMin) * progress
    }

    /// Dynamic rendering frame rate: visual necessity capped by the preset's target FPS.
    static func effectiveFrameRate(load: Double, speed: KineticNotchSpeed, frameCount: Int) -> Double {
        let rps = revolutionsPerSecond(load: load)
        let visualFPS = rps * Double(frameCount)
        return min(speed.targetFPS, max(visualFPS, 6.0))
    }

    /// Advance continuous fractional phase [0.0, 1.0) given rps and elapsed dt (clamped to 1.0s for sleep/wake).
    static func advancePhase(currentPhase: Double, rps: Double, dt: TimeInterval) -> Double {
        let clampedDt = min(max(dt, 0), 1.0)
        let delta = rps * clampedDt
        var next = currentPhase + delta
        if next >= 1.0 {
            next = next.truncatingRemainder(dividingBy: 1.0)
        }
        return next
    }

    /// Discrete frame index from continuous phase for a given style.
    static func displayedFrame(style: MenuBarIconStyle, phase: Double, load: Double? = nil, reduceMotion: Bool) -> Int {
        guard !reduceMotion else { return style.staticFrame }
        let count = style.frameCount
        let safePhase = max(phase, 0.0).truncatingRemainder(dividingBy: 1.0)
        let activeLoad = (load?.isFinite == true) ? load! : 0.0

        // Gauge-type meter styles (e.g. VU Meter) move needle from left to right as load increases
        if style == .vuMeter {
            let clampedLoad = min(max(activeLoad, 0), 100)
            let baseIndex = (clampedLoad / 100.0) * Double(count - 1)
            let jitter = sin(safePhase * 2.0 * .pi * 3.0) * (0.5 + (clampedLoad / 100.0) * 1.5)
            let target = Int(round(baseIndex + jitter))
            return min(max(target, 0), count - 1)
        }

        // Digital Equalizer dynamically scales bar heights based on workload tier (4 tiers x 6 subphases)
        if style == .equalizer {
            let clampedLoad = min(max(activeLoad, 0), 100)
            let tier = min(Int(clampedLoad / 25.0), 3) // Tier 0 (low) ~ Tier 3 (max load)
            let subPhase = Int(safePhase * 6.0) % 6
            return tier * 6 + subPhase
        }

        return Int(safePhase * Double(count)) % count
    }

    static func displayedFrame(style: MenuBarIconStyle, phase: Int, reduceMotion: Bool) -> Int {
        let continuous = Double(phase) / Double(style.frameCount)
        return displayedFrame(style: style, phase: continuous, load: nil, reduceMotion: reduceMotion)
    }

    static func phaseDelayMultiplier(style: MenuBarIconStyle, phase: Int) -> Double {
        switch style {
        case .equalizer:
            return 1.8
        default:
            return 1.0
        }
    }

    static func frameDelay(style: MenuBarIconStyle, phase: Int, frameRate: Double) -> TimeInterval {
        (1.0 / frameRate) * phaseDelayMultiplier(style: style, phase: phase)
    }
}
