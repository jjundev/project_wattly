import Foundation

protocol FanControlHardware: AnyObject {
    func fanIndexes() throws -> [Int]
    func modeKey(for index: Int) throws -> String
    func hasForceTestUnlock() throws -> Bool
    func writeForceTest() throws
    func setManual(index: Int, modeKey: String) throws -> Bool
    /// Returns true only after the controller confirms macOS automatic mode.
    func setAutomatic(index: Int, modeKey: String) throws -> Bool
    func limits(for index: Int) throws -> FanLimits
    func hottestCPUCelsius() throws -> Double?
    func setTarget(index: Int, rpm: Double) throws
}

enum FanControlFailure: Error, Equatable {
    case hardware(String)
    case engagementTimedOut(Int)
    case invalidTarget(Int)
}

/// The daemon's fail-safe state machine. Every retry is stateful: `tick(now:)` performs at
/// most one due write per fan and never sleeps, leaving the daemon queue free for watchdog,
/// XPC release, signals, and sleep handling.
final class FanControlEngine {
    private typealias ControlledFan = (index: Int, modeKey: String)

    private struct PendingManual {
        let index: Int
        let modeKey: String
        let generation: UInt64
        var nextAttemptAt: TimeInterval
        let deadline: TimeInterval
    }

    private let hardware: any FanControlHardware
    private var configuration: FanControlConfiguration?
    private var configurationGeneration: UInt64 = 0
    private var lastHeartbeat: TimeInterval?
    private var controlled: [ControlledFan] = []
    private var pendingManual: [PendingManual] = []
    private var engagementGeneration: UInt64?
    private var nextAutomaticRetryAt: TimeInterval?
    private var nextTargetUpdateAt: TimeInterval?
    private var automaticReason = "macOS automatic control"
    private var startupRecoveryPending = true

    private(set) var status = FanControlServiceStatus(mode: .automatic,
                                                      detail: "macOS automatic control",
                                                      updatedAt: 0)

    /// The daemon uses this gate to avoid accepting XPC clients until its startup reset was
    /// acknowledged by every discovered fan controller.
    var isSafeToAcceptClients: Bool { !startupRecoveryPending && controlled.isEmpty }

    init(hardware: any FanControlHardware) {
        self.hardware = hardware
    }

    /// Source-compatible for existing callers; retries no longer invoke this closure.
    convenience init(hardware: any FanControlHardware, sleeper: @escaping (TimeInterval) -> Void) {
        self.init(hardware: hardware)
    }

    func configure(_ configuration: FanControlConfiguration, now: TimeInterval) throws {
        configurationGeneration &+= 1
        pendingManual.removeAll()
        engagementGeneration = nil
        nextTargetUpdateAt = nil

        guard configuration.enabled else {
            release(now: now, reason: "control disabled")
            return
        }
        guard controlled.isEmpty else {
            status = .init(mode: .failed, detail: "automatic-mode recovery pending", updatedAt: now)
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

    /// Writes automatic mode to every discovered fan before the daemon opens its XPC listener.
    /// Failed confirmations remain in `controlled` and are retried by future ticks.
    func resetAllFansToAutomatic(now: TimeInterval) {
        startupRecoveryPending = true
        configuration = nil
        lastHeartbeat = nil
        pendingManual.removeAll()
        engagementGeneration = nil
        nextTargetUpdateAt = nil
        configurationGeneration &+= 1

        do {
            let discovered = try hardware.fanIndexes().map { index in
                (index: index, modeKey: try hardware.modeKey(for: index))
            }
            controlled = discovered
            automaticReason = "startup automatic-mode recovery"
            nextAutomaticRetryAt = now
            if controlled.isEmpty {
                startupRecoveryPending = false
                status = .init(mode: .automatic, detail: automaticReason, updatedAt: now)
            } else {
                retryAutomaticIfDue(now: now)
            }
        } catch {
            status = .init(mode: .failed,
                           detail: "startup fan discovery failed: \(error)",
                           updatedAt: now)
        }
    }

    func tick(now: TimeInterval) throws {
        retryAutomaticIfDue(now: now)
        // A non-nil retry deadline means these are fans awaiting confirmed automatic mode.
        // Ordinary controlled fans have no automatic retry deadline and continue through the
        // heartbeat/control path below.
        guard nextAutomaticRetryAt == nil else { return }

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
            guard pendingManual.isEmpty else { return }
            guard now >= (nextTargetUpdateAt ?? -.infinity) else { return }

            for fan in controlled {
                let target = FanControlPolicy.targetRPM(curve: configuration.curve,
                                                        hottestCPU: hottestCPU,
                                                        limits: try hardware.limits(for: fan.index))
                guard target.isFinite, target > 0 else {
                    throw FanControlFailure.invalidTarget(fan.index)
                }
                try hardware.setTarget(index: fan.index, rpm: target)
            }
            nextTargetUpdateAt = now + FanControlPolicy.controlInterval
            status = .init(mode: .controlling, detail: "CPU \(Int(hottestCPU))°C", updatedAt: now)
        } catch let failure as FanControlFailure {
            release(now: now, reason: "fan control failed")
            throw failure
        } catch {
            release(now: now, reason: "fan control failed")
            throw FanControlFailure.hardware(String(describing: error))
        }
    }

    /// Begins automatic-mode recovery. A failed write intentionally retains the fan in
    /// `controlled`; ownership is cleared only after the SMC acknowledges automatic mode.
    func release(now: TimeInterval, reason: String) {
        configuration = nil
        lastHeartbeat = nil
        pendingManual.removeAll()
        engagementGeneration = nil
        nextTargetUpdateAt = nil
        automaticReason = reason
        nextAutomaticRetryAt = now
        if controlled.isEmpty {
            nextAutomaticRetryAt = nil
            status = .init(mode: .automatic, detail: reason, updatedAt: now)
        } else {
            retryAutomaticIfDue(now: now)
        }
    }

    private func engageIfNeeded(now: TimeInterval) throws {
        guard configuration != nil else { return }
        guard engagementGeneration != configurationGeneration else {
            try attemptDueManualWrites(now: now)
            return
        }

        let discovered = try hardware.fanIndexes().map { index in
            (index: index, modeKey: try hardware.modeKey(for: index))
        }
        let pending = discovered.filter { candidate in
            !controlled.contains(where: { $0.index == candidate.index })
        }
        engagementGeneration = configurationGeneration
        guard !pending.isEmpty else { return }

        status = .init(mode: .engaging, detail: "engaging fan control", updatedAt: now)
        let usesLegacyMode = pending.contains { $0.modeKey.hasSuffix("Md") }
        let firstAttemptAt: TimeInterval
        if usesLegacyMode {
            if try hardware.hasForceTestUnlock() {
                try hardware.writeForceTest()
                // Legacy controllers require settling time after Ftst before the first F<n>Md write.
                firstAttemptAt = now + FanControlPolicy.modeRetryDelay
            } else {
                firstAttemptAt = now
            }
        } else {
            firstAttemptAt = now
        }
        pendingManual = pending.map {
            PendingManual(index: $0.index, modeKey: $0.modeKey, generation: configurationGeneration,
                          nextAttemptAt: firstAttemptAt,
                          deadline: now + FanControlPolicy.modeRetryDeadline)
        }
        try attemptDueManualWrites(now: now)
    }

    private func attemptDueManualWrites(now: TimeInterval) throws {
        var remaining: [PendingManual] = []
        for var pending in pendingManual {
            guard pending.generation == configurationGeneration, configuration != nil else { continue }
            if now >= pending.deadline { throw FanControlFailure.engagementTimedOut(pending.index) }
            guard now >= pending.nextAttemptAt else {
                remaining.append(pending)
                continue
            }
            if try hardware.setManual(index: pending.index, modeKey: pending.modeKey) {
                controlled.append((pending.index, pending.modeKey))
            } else {
                pending.nextAttemptAt = now + FanControlPolicy.modeRetryDelay
                remaining.append(pending)
            }
        }
        pendingManual = remaining
    }

    private func retryAutomaticIfDue(now: TimeInterval) {
        guard !controlled.isEmpty, now >= (nextAutomaticRetryAt ?? .infinity) else { return }

        var stillControlled: [ControlledFan] = []
        for fan in controlled {
            do {
                if try hardware.setAutomatic(index: fan.index, modeKey: fan.modeKey) { continue }
            } catch {
                // Keep this fan owned and retry it. The failed status below is the caller-visible report.
            }
            stillControlled.append(fan)
        }
        controlled = stillControlled

        if controlled.isEmpty {
            nextAutomaticRetryAt = nil
            startupRecoveryPending = false
            status = .init(mode: .automatic, detail: automaticReason, updatedAt: now)
        } else {
            nextAutomaticRetryAt = now + FanControlPolicy.modeRetryDelay
            let indexes = controlled.map { String($0.index) }.joined(separator: ", ")
            status = .init(mode: .failed,
                           detail: "\(automaticReason): automatic-mode recovery failed for fan \(indexes)",
                           updatedAt: now)
        }
    }
}
