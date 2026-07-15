import Foundation
import Testing
@testable import Wattly

struct FanControlEngineTests {
    @Test func m5UsesLowercaseModeWithoutFtst() throws {
        let hw = FakeFanControlHardware(modeKey: "F0md", hasFtst: false, hottestCPU: 40,
                                        limits: FanLimits(minimum: 2317, maximum: 6550))
        let engine = FanControlEngine(hardware: hw, sleeper: { _ in })
        try engine.configure(.init(enabled: true, curve: .init(rpms: [1200, 2500, 4500, 6000])), now: 0)
        try engine.tick(now: 0)
        #expect(hw.writes == [.mode("F0md", 1), .target(0, 2317)])
        #expect(hw.forceTestWrites == 0)
    }

    @Test func legacyModeUsesFtstAndRetries() throws {
        let hw = FakeFanControlHardware(modeKey: "F0Md", hasFtst: true, modeFailures: 2, hottestCPU: 70,
                                        limits: FanLimits(minimum: 2000, maximum: 6000))
        let engine = FanControlEngine(hardware: hw)
        try engine.configure(.init(enabled: true, curve: .init(rpms: [1200, 2500, 4500, 6000])), now: 0)
        try engine.tick(now: 0)
        #expect(hw.modeAttempts == 0)
        try engine.tick(now: 0.5)
        try engine.tick(now: 1.0)
        try engine.tick(now: 1.5)
        #expect(hw.forceTestWrites == 1)
        #expect(hw.modeAttempts == 3)
        #expect(hw.writes.last == .target(0, 3500))
    }

    @Test func legacyFtstWaitsBeforeFirstManualAttempt() throws {
        let hw = FakeFanControlHardware(modeKey: "F0Md", hasFtst: true, hottestCPU: 70,
                                        limits: FanLimits(minimum: 2000, maximum: 6000))
        let engine = FanControlEngine(hardware: hw)
        try engine.configure(.init(enabled: true, curve: .init(rpms: [1200, 2500, 4500, 6000])), now: 10)
        try engine.tick(now: 10)
        #expect(hw.forceTestWrites == 1)
        #expect(hw.modeAttempts == 0)
        try engine.tick(now: 10.49)
        #expect(hw.modeAttempts == 0)
        try engine.tick(now: 10.5)
        #expect(hw.modeAttempts == 1)
    }

    @Test func manualRetryIsStatefulAndChecksHeartbeatWhileWaiting() throws {
        let hw = FakeFanControlHardware(modeKey: "F0md", hasFtst: false, modeFailures: 99, hottestCPU: 70,
                                        limits: FanLimits(minimum: 2000, maximum: 6000))
        let engine = FanControlEngine(hardware: hw)
        try engine.configure(.init(enabled: true, curve: .init(rpms: [1200, 2500, 4500, 6000])), now: 0)
        try engine.tick(now: 0)
        #expect(hw.modeAttempts == 1)
        try engine.tick(now: 0.1)
        #expect(hw.modeAttempts == 1)
        try engine.tick(now: 15)
        #expect(engine.status.mode == .automatic)
        #expect(engine.status.detail == "heartbeat expired")
    }

    @Test func disableInvalidatesPendingEngagementGeneration() throws {
        let hw = FakeFanControlHardware(modeKey: "F0Md", hasFtst: true, hottestCPU: 70,
                                        limits: FanLimits(minimum: 2000, maximum: 6000))
        let engine = FanControlEngine(hardware: hw)
        let enabled = FanControlConfiguration(enabled: true, curve: .init(rpms: [1200, 2500, 4500, 6000]))
        try engine.configure(enabled, now: 0)
        try engine.tick(now: 0) // Ftst schedules the delayed legacy attempt.
        try engine.configure(.init(enabled: false, curve: enabled.curve), now: 0.1)
        try engine.tick(now: 0.5)
        #expect(hw.modeAttempts == 0)
        #expect(engine.status.mode == .automatic)
    }

    @Test func expiredHeartbeatReturnsAutomaticMode() throws {
        let hw = FakeFanControlHardware(modeKey: "F0md", hasFtst: false, hottestCPU: 70,
                                        limits: FanLimits(minimum: 2000, maximum: 6000))
        let engine = FanControlEngine(hardware: hw, sleeper: { _ in })
        try engine.configure(.init(enabled: true, curve: .init(rpms: [1200, 2500, 4500, 6000])), now: 0)
        try engine.tick(now: 0)
        try engine.tick(now: 15)
        #expect(hw.writes.last == .mode("F0md", 0))
        #expect(engine.status.mode == .automatic)
    }

    @Test func explicitDisableReturnsAutomaticMode() throws {
        let hw = FakeFanControlHardware(modeKey: "F0md", hasFtst: false, hottestCPU: 70,
                                        limits: FanLimits(minimum: 2000, maximum: 6000))
        let engine = FanControlEngine(hardware: hw, sleeper: { _ in })
        try engine.configure(.init(enabled: true, curve: .init(rpms: [1200, 2500, 4500, 6000])), now: 0)
        try engine.tick(now: 0)
        try engine.configure(.init(enabled: false, curve: .init(rpms: [1200, 2500, 4500, 6000])), now: 1)
        #expect(hw.writes.last == .mode("F0md", 0))
    }

    @Test func missingSensorReleasesManualMode() throws {
        let hw = FakeFanControlHardware(modeKey: "F0md", hasFtst: false, hottestCPU: 70,
                                        limits: FanLimits(minimum: 2000, maximum: 6000))
        let engine = FanControlEngine(hardware: hw, sleeper: { _ in })
        try engine.configure(.init(enabled: true, curve: .init(rpms: [1200, 2500, 4500, 6000])), now: 0)
        try engine.tick(now: 0)
        hw.hottestCPU = nil
        try engine.tick(now: 1)
        #expect(hw.writes.last == .mode("F0md", 0))
    }

    @Test func acquisitionDeadlineLeavesAutomaticMode() {
        let hw = FakeFanControlHardware(modeKey: "F0md", hasFtst: false, modeFailures: 99, hottestCPU: 70,
                                        limits: FanLimits(minimum: 2000, maximum: 6000))
        let engine = FanControlEngine(hardware: hw)
        #expect(throws: FanControlFailure.self) {
            try engine.configure(.init(enabled: true, curve: .init(rpms: [1200, 2500, 4500, 6000])), now: 0)
            for now in stride(from: 0.0, through: 10.0, by: 0.5) {
                try engine.tick(now: now)
            }
        }
        #expect(engine.status.mode == .automatic)
    }

    @Test func failedAutomaticWriteRemainsOwnedAndIsRetried() throws {
        let hw = FakeFanControlHardware(modeKey: "F0md", hasFtst: false, hottestCPU: 70,
                                        limits: FanLimits(minimum: 2000, maximum: 6000))
        let engine = FanControlEngine(hardware: hw)
        try engine.configure(.init(enabled: true, curve: .init(rpms: [1200, 2500, 4500, 6000])), now: 0)
        try engine.tick(now: 0)
        hw.automaticFailuresByFan[0] = 1
        engine.release(now: 1, reason: "test release")
        #expect(engine.status.mode == .failed)
        #expect(hw.automaticAttempts == 1)
        try engine.configure(.init(enabled: true, curve: .init(rpms: [1200, 2500, 4500, 6000])), now: 1.1)
        #expect(engine.status.mode == .failed)
        try engine.tick(now: 1.49)
        #expect(hw.automaticAttempts == 1)
        try engine.tick(now: 1.5)
        #expect(hw.automaticAttempts == 2)
        #expect(engine.status.mode == .automatic)
    }

    @Test func startupResetRetriesEveryDiscoveredFanBeforeSafe() throws {
        let hw = FakeFanControlHardware(fans: [0, 1], modeKeys: ["F0md", "F1Md"],
                                        modeFailuresByFan: [:], hottestCPU: 70,
                                        limits: FanLimits(minimum: 2000, maximum: 6000))
        hw.automaticFailuresByFan[1] = 1
        let engine = FanControlEngine(hardware: hw)
        engine.resetAllFansToAutomatic(now: 0)
        #expect(engine.status.mode == .failed)
        #expect(!engine.isSafeToAcceptClients)
        try engine.tick(now: 0.5)
        #expect(engine.status.mode == .automatic)
        #expect(engine.isSafeToAcceptClients)
        #expect(hw.writes.contains(.mode("F0md", 0)))
        #expect(hw.writes.contains(.mode("F1Md", 0)))
    }

    @Test func laterFanFailureReleasesEarlierManualFan() {
        let hw = FakeFanControlHardware(fans: [0, 1], modeKeys: ["F0md", "F1md"],
                                        modeFailuresByFan: [1: 99], hottestCPU: 70,
                                        limits: FanLimits(minimum: 2000, maximum: 6000))
        let engine = FanControlEngine(hardware: hw, sleeper: { _ in })
        #expect(throws: FanControlFailure.self) {
            try engine.configure(.init(enabled: true, curve: .init(rpms: [1200, 2500, 4500, 6000])), now: 0)
            for now in stride(from: 0.0, through: 10.0, by: 0.5) {
                try engine.tick(now: now)
            }
        }
        #expect(hw.writes.contains(.mode("F0md", 0)))
    }
}

private final class FakeFanControlHardware: FanControlHardware {
    enum Write: Equatable {
        case mode(String, UInt8)
        case target(Int, Double)
    }

    let fans: [Int]
    let modeKeys: [Int: String]
    let hasFtst: Bool
    var modeFailuresByFan: [Int: Int]
    var hottestCPU: Double?
    let fanLimits: [Int: FanLimits]
    var writes: [Write] = []
    var forceTestWrites = 0
    var modeAttempts = 0
    var automaticAttempts = 0
    var automaticFailuresByFan: [Int: Int] = [:]

    init(modeKey: String, hasFtst: Bool, modeFailures: Int = 0, hottestCPU: Double?, limits: FanLimits) {
        self.fans = [0]
        self.modeKeys = [0: modeKey]
        self.hasFtst = hasFtst
        self.modeFailuresByFan = [0: modeFailures]
        self.hottestCPU = hottestCPU
        self.fanLimits = [0: limits]
    }

    init(fans: [Int], modeKeys: [String], modeFailuresByFan: [Int: Int], hottestCPU: Double?, limits: FanLimits) {
        self.fans = fans
        self.modeKeys = Dictionary(uniqueKeysWithValues: zip(fans, modeKeys))
        self.hasFtst = false
        self.modeFailuresByFan = modeFailuresByFan
        self.hottestCPU = hottestCPU
        self.fanLimits = Dictionary(uniqueKeysWithValues: fans.map { ($0, limits) })
    }

    func fanIndexes() throws -> [Int] { fans }
    func modeKey(for index: Int) throws -> String { try value(modeKeys[index]) }
    func hasForceTestUnlock() throws -> Bool { hasFtst }
    func writeForceTest() throws { forceTestWrites += 1 }
    func setManual(index: Int, modeKey: String) throws -> Bool {
        modeAttempts += 1
        guard modeKeys[index] == modeKey else { return false }
        if modeFailuresByFan[index, default: 0] > 0 {
            modeFailuresByFan[index, default: 0] -= 1
            return false
        }
        writes.append(.mode(modeKey, 1))
        return true
    }
    func setAutomatic(index: Int, modeKey: String) throws -> Bool {
        automaticAttempts += 1
        if automaticFailuresByFan[index, default: 0] > 0 {
            automaticFailuresByFan[index, default: 0] -= 1
            return false
        }
        writes.append(.mode(modeKey, 0))
        return true
    }
    func limits(for index: Int) throws -> FanLimits { try value(fanLimits[index]) }
    func hottestCPUCelsius() throws -> Double? { hottestCPU }
    func setTarget(index: Int, rpm: Double) throws { writes.append(.target(index, rpm)) }

    private func value<T>(_ value: T?) throws -> T {
        guard let value else { throw FanControlFailure.hardware("invalid fake") }
        return value
    }
}
