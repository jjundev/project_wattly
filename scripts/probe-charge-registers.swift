#!/usr/bin/swift
//
// Wattly — charge-control register probe (READ-ONLY)
//
// Prints which SMC charge-control registers this Mac exposes, so the register table in
// `FanControlShared/BatteryControlKeys.swift` can be checked against real hardware other than the
// single M5 it was measured on.
//
// This script only ever issues the SMC "key info" command (9) and the "read" command (5). It
// contains no write path at all — the write opcode is not implemented here — so it cannot change
// any hardware state, and it needs no root. Run it with:
//
//     swift probe-charge-registers.swift
//
import Foundation
import IOKit

// MARK: - Minimal read-only AppleSMC client

private typealias Bytes32 = (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                             UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                             UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                             UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8)
private struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
private struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
private struct KeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0; var p0: UInt8 = 0, p1: UInt8 = 0, p2: UInt8 = 0 }
private struct Param {
    var key: UInt32 = 0
    var vers = Vers()
    var pLimit = PLimit()
    var keyInfo = KeyInfo()
    var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes32 = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

private let cmdRead: UInt8 = 5
private let cmdKeyInfo: UInt8 = 9
private let kernelIndex: UInt32 = 2

private func fourCC(_ string: String) -> UInt32 {
    var result: UInt32 = 0
    for byte in string.utf8.prefix(4) { result = (result << 8) | UInt32(byte) }
    return result
}

private func string(_ value: UInt32) -> String {
    String(bytes: [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
                   UInt8((value >> 8) & 0xff), UInt8(value & 0xff)], encoding: .ascii) ?? ""
}

private final class SMCReader {
    private let connection: io_connect_t

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS, conn != 0 else { return nil }
        connection = conn
    }

    deinit { IOServiceClose(connection) }

    func keyInfo(_ key: String) -> (type: String, size: Int, attributes: UInt8)? {
        var probe = Param(); probe.key = fourCC(key); probe.data8 = cmdKeyInfo
        let reply = call(&probe)
        guard reply.kernel == KERN_SUCCESS else { return nil }
        let size = Int(reply.output.keyInfo.dataSize)
        guard (1...32).contains(size) else { return nil }
        return (string(reply.output.keyInfo.dataType), size, reply.output.keyInfo.dataAttributes)
    }

    func read(_ key: String) -> [UInt8]? {
        let k = fourCC(key)
        var probe = Param(); probe.key = k; probe.data8 = cmdKeyInfo
        let infoReply = call(&probe)
        guard infoReply.kernel == KERN_SUCCESS else { return nil }
        let info = infoReply.output
        let size = Int(info.keyInfo.dataSize)
        guard (1...32).contains(size) else { return nil }
        var request = Param(); request.key = k; request.keyInfo = info.keyInfo; request.data8 = cmdRead
        let readReply = call(&request)
        guard readReply.kernel == KERN_SUCCESS else { return nil }
        var tuple = readReply.output.bytes
        return withUnsafeBytes(of: &tuple) { Array($0.prefix(size)) }
    }

    private func call(_ input: inout Param) -> (kernel: kern_return_t, output: Param) {
        var output = Param()
        var outSize = MemoryLayout<Param>.stride
        let kernel = IOConnectCallStructMethod(connection, kernelIndex, &input,
                                               MemoryLayout<Param>.stride, &output, &outSize)
        return (kernel, output)
    }
}

// MARK: - Report

/// Mirrors `BatteryControlKeys.probeOrder`: first key present *at the expected size* wins.
let probeOrder: [(generation: String, key: String, expectedSize: Int)] = [
    ("modern", "CHTE", 4),
    ("legacy", "CH0B", 1),
    ("intel",  "BCLM", 1)
]
/// macOS 27-era firmware (`20xxx`) hands the limit to the firmware itself through these three keys.
/// All three are printed below for the raw per-key data — that is the point of this script — but
/// only two of them decide the verdict; see `firmwareManagedDecidingKeys`.
let firmwareManagedKeys = ["bfF0", "bfD0", "bfE0"]
/// Mirrors `BatteryControlKeys.firmwareManagedKeys`: the verdict takes precedence over `CHTE`/`CH0B`
/// when both of *these* are present, and `bfD0` is deliberately left out of the vote. `bfD0` shows up
/// on Tahoe firmware all by itself as a 2-byte read-only key (confirmed on the M5 this table was
/// measured on, where the charge limit works fine through `CHTE`), so counting it would report
/// firmware-managed status on a Mac that works today. See the doc comment on
/// `BatteryControlKeys.firmwareManagedKeys` for the full reasoning — this must stay in lockstep with
/// that property, not drift into requiring all three the way `charlie0129/batt` does.
let firmwareManagedDecidingKeys = ["bfF0", "bfE0"]
/// Written alongside the deciding key, or simply worth knowing about. Never decides the generation.
let companionKeys = ["CH0C", "CH0I", "CH0J", "CHWA", "CHIE"]
/// Not charge control — the current the cell is actually taking, which is how a volunteer can tell
/// whether an applied limit really stopped charging.
let observationKeys = ["B0AC", "BC1I"]

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
    return String(cString: buffer)
}

func shell(_ launchPath: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return "unknown" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
}

var lines: [String] = []
lines.append("--- Wattly charge-register probe v1 (read-only) ---")
// Deliberately no serial number and no user or host name: the register table only needs the model,
// the chip and the OS, and a paste headed for a public forum should carry nothing else.
lines.append("model:  \(sysctlString("hw.model"))")
lines.append("chip:   \(sysctlString("machdep.cpu.brand_string"))")
lines.append("macOS:  \(shell("/usr/bin/sw_vers", ["-productVersion"])) (\(shell("/usr/bin/sw_vers", ["-buildVersion"])))")
// The register set tracks the *firmware*, not the chip and not the OS release: an old macOS can
// carry new firmware and vice versa. `system_profiler` also prints the serial number, the hardware
// UUID and the provisioning UDID — each on its own line — so exactly one line is lifted out of it
// and the rest is dropped on the floor.
//
// Two labels, because Apple silicon reports `System Firmware Version` while Intel Macs report
// `Boot ROM Version` for the same field. Taking only the first would print `unknown` on precisely
// the machines whose firmware string is least known.
let hardware = shell("/usr/sbin/system_profiler", ["SPHardwareDataType"])
let firmwareLabels = ["System Firmware Version", "Boot ROM Version"]
let firmware = hardware.split(separator: "\n")
    .compactMap { line -> String? in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let label = firmwareLabels.first(where: { trimmed.hasPrefix($0 + ":") }) else { return nil }
        return trimmed.replacingOccurrences(of: label + ": ", with: "")
    }
    .first ?? "unknown"
lines.append("fw:     \(firmware)")

guard let smc = SMCReader() else {
    lines.append("result: FAILED — could not open AppleSMC")
    print(lines.joined(separator: "\n"))
    exit(1)
}

func describe(_ key: String, expectedSize: Int?) -> String {
    guard let info = smc.keyInfo(key) else {
        return "  \(key)  absent"
    }
    let hex = smc.read(key).map { $0.map { String(format: "%02x", $0) }.joined(separator: " ") } ?? "??"
    let writable = (info.attributes & 0x40) != 0 ? "writable" : "read-only"
    var line = "  \(key)  present  type=\(info.type) size=\(info.size) attr=0x\(String(format: "%02x", info.attributes)) \(writable)  value=[\(hex)]"
    if let expectedSize, info.size != expectedSize {
        line += "  ** SIZE MISMATCH (expected \(expectedSize)) **"
    }
    return line
}

lines.append("deciding keys:")
for candidate in probeOrder {
    lines.append(describe(candidate.key, expectedSize: candidate.expectedSize))
}
lines.append("firmware-managed keys (macOS 27-era):")
for key in firmwareManagedKeys {
    lines.append(describe(key, expectedSize: nil))
}
lines.append("companion keys:")
for key in companionKeys {
    lines.append(describe(key, expectedSize: nil))
}
lines.append("battery observation:")
for key in observationKeys {
    lines.append(describe(key, expectedSize: nil))
}

// Firmware-managed is decided first, exactly like `BatteryControlKeys.registerSet(probing:)`: it
// must win over any of `probeOrder` below, or this script could print `verdict: modern` on a Mac
// where the app itself would decide `.firmwareManaged` and refuse to touch `CHTE`.
let isFirmwareManaged = firmwareManagedDecidingKeys.allSatisfy { smc.keyInfo($0) != nil }
let verdict = isFirmwareManaged
    ? "firmware-managed"
    : probeOrder.first {
        guard let info = smc.keyInfo($0.key) else { return false }
        return info.size == $0.expectedSize
    }?.generation ?? "unsupported"
lines.append("verdict: \(verdict)")
if isFirmwareManaged {
    lines.append("note:    firmware-managed charge limit present (bfF0+bfE0 decide; bfD0 shown above but never votes)")
}
lines.append("--- end ---")

print(lines.joined(separator: "\n"))
