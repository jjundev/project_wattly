#!/usr/bin/env swift

import Darwin
import Foundation

private struct Arguments {
    let pid: Int32
    let seconds: TimeInterval
    let runs: Int

    init?(_ raw: [String]) {
        guard raw.count == 3,
              let pid = Int32(raw[0]), pid > 0,
              let seconds = TimeInterval(raw[1]), seconds > 0,
              let runs = Int(raw[2]), runs > 0 else { return nil }
        self.pid = pid
        self.seconds = seconds
        self.runs = runs
    }
}

private func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

private func energyNanojoules(pid: Int32) -> UInt64? {
    var info = rusage_info_v6()
    let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
        }
    }
    return result == 0 ? info.ri_energy_nj : nil
}

guard let arguments = Arguments(Array(CommandLine.arguments.dropFirst())) else {
    fail("usage: swift scripts/measure-process-energy.swift <pid> <seconds> <runs>", code: 64)
}

guard kill(arguments.pid, 0) == 0 else {
    fail("target pid \(arguments.pid) is not running or is not accessible", code: 66)
}

var readings: [Double] = []
readings.reserveCapacity(arguments.runs)
print("run,watts")

for run in 1...arguments.runs {
    guard let startEnergy = energyNanojoules(pid: arguments.pid) else {
        fail("could not read starting ri_energy_nj for pid \(arguments.pid)", code: 69)
    }
    let start = ContinuousClock.now
    Thread.sleep(forTimeInterval: arguments.seconds)
    let end = ContinuousClock.now
    guard let endEnergy = energyNanojoules(pid: arguments.pid), endEnergy >= startEnergy else {
        fail("could not read a monotonic ending ri_energy_nj for pid \(arguments.pid)", code: 69)
    }

    let duration = start.duration(to: end)
    let elapsed = Double(duration.components.seconds)
        + Double(duration.components.attoseconds) * 1e-18
    let watts = Double(endEnergy - startEnergy) / 1_000_000_000 / elapsed
    readings.append(watts)
    print("\(run),\(String(format: "%.6f", watts))")
}

let mean = readings.reduce(0, +) / Double(readings.count)
print("mean,\(String(format: "%.6f", mean))")
