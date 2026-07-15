import Foundation
import IOKit

/// Root-only SMC implementation used by the helper target. The app's `FanTransport` remains
/// strictly read-only; this is the sole adapter that can request manual fan control.
final class SMCFanControlHardware: FanControlHardware {
    private static let maximumFanCount = 16
    private let smc: SMCControlConnection

    init?(smc: SMCControlConnection? = SMCControlConnection()) {
        guard let smc else { return nil }
        self.smc = smc
    }

    func fanIndexes() throws -> [Int] {
        guard let raw = smc.read("FNum"), Self.isUI8(raw.type), let first = raw.bytes.first else {
            throw FanControlFailure.hardware("FNum unavailable")
        }
        let count = Int(first)
        guard count > 0, count <= Self.maximumFanCount else {
            throw FanControlFailure.hardware("invalid FNum")
        }
        return try (0..<count).map { index in
            _ = try modeKey(for: index)
            return index
        }
    }

    func modeKey(for index: Int) throws -> String {
        for key in ["F\(index)md", "F\(index)Md"] {
            if let info = smc.keyInfo(key), Self.isUI8(info.type), info.size == 1 {
                return key
            }
        }
        throw FanControlFailure.hardware("manual mode key missing for fan \(index)")
    }

    func hasForceTestUnlock() throws -> Bool {
        smc.keyInfo("Ftst") != nil
    }

    func writeForceTest() throws {
        guard let info = smc.keyInfo("Ftst"), Self.isUI8(info.type), info.size == 1,
              let reply = smc.write("Ftst", bytes: [1]),
              reply.kernel == KERN_SUCCESS, reply.smcResult == 0 else {
            throw FanControlFailure.hardware("Ftst write failed")
        }
    }

    func setManual(index: Int, modeKey: String) throws -> Bool {
        guard try self.modeKey(for: index) == modeKey else {
            throw FanControlFailure.hardware("manual mode key changed for fan \(index)")
        }
        guard let reply = smc.write(modeKey, bytes: [1]) else {
            throw FanControlFailure.hardware("manual mode write unavailable")
        }
        return reply.kernel == KERN_SUCCESS && reply.smcResult == 0
    }

    func setAutomatic(index: Int, modeKey: String) throws {
        guard let reply = smc.write(modeKey, bytes: [0]),
              reply.kernel == KERN_SUCCESS, reply.smcResult == 0 else {
            throw FanControlFailure.hardware("automatic mode write failed for fan \(index)")
        }
    }

    func limits(for index: Int) throws -> FanLimits {
        FanLimits(minimum: try rpm(index, suffix: "Mn"), maximum: try rpm(index, suffix: "Mx"))
    }

    func hottestCPUCelsius() throws -> Double? {
        guard let profile = TemperatureProfiles.profile(forModel: currentHardwareModel()) else { return nil }
        let readings = profile.cpuGroups.flatMap(\.keys).compactMap { key -> Double? in
            guard let info = smc.keyInfo(key), info.type == "flt ", info.size == 4,
                  let raw = smc.read(key), raw.type == "flt ", raw.bytes.count == 4 else { return nil }
            let value = smcDouble(raw.bytes, type: raw.type)
            return value.isFinite ? value : nil
        }
        return hottestCelsius(readings, in: profile.validRange)
    }

    func setTarget(index: Int, rpm: Double) throws {
        guard rpm.isFinite, Float32(rpm).isFinite else {
            throw FanControlFailure.hardware("invalid target RPM")
        }
        let key = "F\(index)Tg"
        guard let info = smc.keyInfo(key), info.type == "flt ", info.size == 4 else {
            throw FanControlFailure.hardware("target key unavailable for fan \(index)")
        }
        var bits = Float32(rpm).bitPattern.littleEndian
        let bytes = withUnsafeBytes(of: &bits) { Array($0) }
        guard let reply = smc.write(key, bytes: bytes),
              reply.kernel == KERN_SUCCESS, reply.smcResult == 0 else {
            throw FanControlFailure.hardware("target write failed for fan \(index)")
        }
    }

    private func rpm(_ index: Int, suffix: String) throws -> Double {
        let key = "F\(index)\(suffix)"
        guard let info = smc.keyInfo(key), info.type == "flt ", info.size == 4,
              let raw = smc.read(key), raw.type == "flt ", raw.bytes.count == 4 else {
            throw FanControlFailure.hardware("RPM key unavailable: \(key)")
        }
        let value = smcDouble(raw.bytes, type: raw.type)
        guard value.isFinite else { throw FanControlFailure.hardware("invalid RPM: \(key)") }
        return value
    }

    private static func isUI8(_ type: String) -> Bool {
        type.trimmingCharacters(in: .whitespaces) == "ui8"
    }
}
