import Foundation
import IOKit.ps

enum HardwarePowerSource {
    /// Zero-cost, instantaneous O(1) OS kernel snapshot of AC adapter connection.
    /// Does NOT perform SMC I/O or background polling. Returns true for desktop Macs.
    static func isACConnected() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return true // Desktop Mac fallback
        }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if let state = desc[kIOPSPowerSourceStateKey] as? String, state == kIOPSACPowerValue {
                return true
            }
        }
        return false
    }
}

enum KineticNotchSource: String, CaseIterable, Identifiable, Sendable {
    case cpuClock
    case power
    case compute

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cpuClock: "CPU 클럭"
        case .power: "전력 소비 (권장)"
        case .compute: "CPU + GPU"
        }
    }

    var requiredCards: Set<CardKind> {
        switch self {
        case .cpuClock: [.cpu]
        case .power: [.power]
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
    case eco
    case smart
    case standard
    case responsive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .eco: "절전"
        case .smart: "스마트 (권장)"
        case .standard: "표준"
        case .responsive: "민감"
        }
    }

    var description: String {
        switch self {
        case .eco: "24 fps 시네마틱 주사율로 배터리를 절약하며 부드럽게 회전합니다."
        case .smart: "메뉴바 상주 시에는 ProMotion 절전을 위해 24 fps로 고정되며, 팝오버를 열거나 설정창을 볼 때는 전원 상태(AC 60 fps / 배터리 24 fps)에 따라 부드럽게 동작합니다."
        case .standard: "메뉴바 상주 시 24 fps, 앱 활성화 시 48 fps 고주사율로 ProMotion 화면에서 자연스럽고 균형 잡힌 모션을 제공합니다."
        case .responsive: "메뉴바 상주 시 24 fps, 앱 활성화 시 60 fps 최고 주사율로 극도로 부드러운 고주사율 화면을 제공합니다."
        }
    }

    static func resolveTargetFPS(speed: KineticNotchSpeed,
                                 isACConnected: Bool,
                                 isLowPowerMode: Bool,
                                 isForeground: Bool = false) -> Double {
        if isLowPowerMode { return 15.0 }
        guard isForeground else {
            // Closed / Background state: Always strictly capped at 24 fps to preserve ProMotion 24Hz baseline battery efficiency
            return 24.0
        }
        switch speed {
        case .eco:
            return 24.0
        case .smart:
            return isACConnected ? 60.0 : 24.0
        case .standard:
            return 48.0
        case .responsive:
            return 60.0
        }
    }
}

enum MenuBarIconMotion {
    static let rpsMin = 0.50 // 1 rev per 2.0s at 0% idle load (upgraded from 0.25 for smooth 12fps baseline under ProMotion throttling)
    static let rpsMax = 2.50 // 1 rev per 0.4s at 100% full load

    /// Physical rotation speed in revolutions per second (RPS), solely determined by workload.
    static func revolutionsPerSecond(load: Double) -> Double {
        let clampedLoad = min(max(load, 0), 100)
        let progress = sqrt(clampedLoad / 100.0)
        return rpsMin + (rpsMax - rpsMin) * progress
    }

    /// Smooths RPS transitions using a 1st-order exponential lag filter (tau = 0.25s), giving physical inertia.
    static func smoothedRPS(current: Double, target: Double, dt: TimeInterval, tau: Double = 0.25) -> Double {
        guard dt > 0, tau > 0 else { return target }
        let alpha = 1.0 - exp(-dt / tau)
        return current + (target - current) * alpha
    }

    /// Computes exact uniform inter-frame delay for the next discrete sprite transition.
    /// Eliminates 33ms beat artifacts / micro-stuttering by sleeping precisely the duration needed for 1 sprite advance.
    static func interFrameDelay(rps: Double,
                                speed: KineticNotchSpeed,
                                isACConnected: Bool = true,
                                isLowPowerMode: Bool = false,
                                isForeground: Bool = false,
                                frameCount: Int = 24,
                                style: MenuBarIconStyle = .hillRunner) -> TimeInterval {
        let targetFPS = KineticNotchSpeed.resolveTargetFPS(speed: speed, isACConnected: isACConnected, isLowPowerMode: isLowPowerMode, isForeground: isForeground)
        let maxFPSDelay = 1.0 / targetFPS

        // Natural duration for 1 sprite advance at current RPS
        let naturalFPS = max(rps * Double(frameCount), 1.0)
        let naturalDelay = 1.0 / naturalFPS

        // Floor at targetFPS limit (e.g. at high load, never exceed targetFPS)
        let baseDelay = max(naturalDelay, maxFPSDelay)
        let multiplier = phaseDelayMultiplier(style: style, phase: 0)
        return baseDelay * multiplier
    }

    /// Dynamic rendering frame rate: visual necessity capped by the preset's target FPS.
    static func effectiveFrameRate(load: Double,
                                   speed: KineticNotchSpeed,
                                   isACConnected: Bool = true,
                                   isLowPowerMode: Bool = false,
                                   isForeground: Bool = false,
                                   frameCount: Int = 24) -> Double {
        KineticNotchSpeed.resolveTargetFPS(speed: speed, isACConnected: isACConnected, isLowPowerMode: isLowPowerMode, isForeground: isForeground)
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

        // Hill Runner maps 3 workload tiers (Low Uphill, Mid Flat, High Downhill) into 8 subphases each
        if style == .hillRunner {
            let clampedLoad = min(max(activeLoad, 0), 100)
            let tier: Int
            if clampedLoad < 25.0 {
                tier = 0 // 저부하: 오르막 (Frames 0..7)
            } else if clampedLoad < 65.0 {
                tier = 1 // 중부하: 평지 (Frames 8..15)
            } else {
                tier = 2 // 고부하: 내리막 질주 (Frames 16..23)
            }
            let subPhase = Int(safePhase * 8.0) % 8
            return tier * 8 + subPhase
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
        case .hillRunner:
            return 1.4
        default:
            return 1.0
        }
    }

    static func frameDelay(style: MenuBarIconStyle, phase: Int, frameRate: Double) -> TimeInterval {
        (1.0 / frameRate) * phaseDelayMultiplier(style: style, phase: phase)
    }
}
