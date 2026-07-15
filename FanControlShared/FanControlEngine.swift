import Foundation

protocol FanControlHardware: AnyObject {
    func fanIndexes() throws -> [Int]
    func modeKey(for index: Int) throws -> String
    func hasForceTestUnlock() throws -> Bool
    func writeForceTest() throws
    func setManual(index: Int, modeKey: String) throws -> Bool
    func setAutomatic(index: Int, modeKey: String) throws
    func limits(for index: Int) throws -> FanLimits
    func hottestCPUCelsius() throws -> Double?
    func setTarget(index: Int, rpm: Double) throws
}

enum FanControlFailure: Error, Equatable {
    case hardware(String)
    case engagementTimedOut(Int)
    case invalidTarget(Int)
}

/// The daemon's fail-safe state machine. It owns only manual-mode state; callers own the
/// cadence and must keep it alive with `heartbeat(now:)` while control is intended.
final class FanControlEngine {
    private typealias ControlledFan = (index: Int, modeKey: String)

    private let hardware: any FanControlHardware
    private let sleeper: (TimeInterval) -> Void
    private var configuration: FanControlConfiguration?
    private var lastHeartbeat: TimeInterval?
    private var controlled: [ControlledFan] = []
    private(set) var status = FanControlServiceStatus(mode: .automatic,
                                                      detail: "macOS automatic control",
                                                      updatedAt: 0)

    init(hardware: any FanControlHardware, sleeper: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)) {
        self.hardware = hardware
        self.sleeper = sleeper
    }

    func configure(_ configuration: FanControlConfiguration, now: TimeInterval) throws {
        guard configuration.enabled else {
            release(now: now, reason: "control disabled")
            return
        }
        self.configuration = configuration
        lastHeartbeat = now
        status = .init(mode: .engaging, detail: "waiting to engage fan control", updatedAt: now)
    }

    func heartbeat(now: TimeInterval) {
        guard configuration != nil else { return }
        lastHeartbeat = now
    }

    func tick(now: TimeInterval) throws {
        guard let configuration, let lastHeartbeat else { return }
        guard !FanControlPolicy.heartbeatExpired(last: lastHeartbeat, now: now) else {
            release(now: now, reason: "heartbeat expired")
            return
        }

        do {
            guard let hottestCPU = try hardware.hottestCPUCelsius() else {
                release(now: now, reason: "CPU temperature unavailable")
                return
            }
            try engageIfNeeded(now: now)
            for fan in controlled {
                let target = FanControlPolicy.targetRPM(curve: configuration.curve,
                                                        hottestCPU: hottestCPU,
                                                        limits: try hardware.limits(for: fan.index))
                guard target.isFinite, target > 0 else {
                    throw FanControlFailure.invalidTarget(fan.index)
                }
                try hardware.setTarget(index: fan.index, rpm: target)
            }
            status = .init(mode: .controlling, detail: "CPU \(Int(hottestCPU))°C", updatedAt: now)
        } catch let failure as FanControlFailure {
            release(now: now, reason: "fan control failed")
            throw failure
        } catch {
            release(now: now, reason: "fan control failed")
            throw FanControlFailure.hardware(String(describing: error))
        }
    }

    func release(now: TimeInterval, reason: String) {
        for fan in controlled {
            try? hardware.setAutomatic(index: fan.index, modeKey: fan.modeKey)
        }
        controlled.removeAll()
        configuration = nil
        lastHeartbeat = nil
        status = .init(mode: .automatic, detail: reason, updatedAt: now)
    }

    private func engageIfNeeded(now: TimeInterval) throws {
        let indexes = try hardware.fanIndexes()
        let pending = indexes.filter { index in !controlled.contains(where: { $0.index == index }) }
        guard !pending.isEmpty else { return }

        status = .init(mode: .engaging, detail: "engaging fan control", updatedAt: now)
        if try hardware.hasForceTestUnlock() {
            try hardware.writeForceTest()
        }
        for index in pending {
            let modeKey = try hardware.modeKey(for: index)
            try engage(index: index, modeKey: modeKey)
        }
    }

    private func engage(index: Int, modeKey: String) throws {
        var elapsed = 0.0
        while true {
            if try hardware.setManual(index: index, modeKey: modeKey) {
                controlled.append((index, modeKey))
                return
            }
            guard elapsed < FanControlPolicy.modeRetryDeadline else {
                throw FanControlFailure.engagementTimedOut(index)
            }
            sleeper(FanControlPolicy.modeRetryDelay)
            elapsed += FanControlPolicy.modeRetryDelay
        }
    }
}
