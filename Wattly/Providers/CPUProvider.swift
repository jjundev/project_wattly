import Foundation

/// Real CPU provider (issue 04) — no entitlements required. Holds the previous
/// tick snapshot across polls (off the MainActor) and diffs it via the pure
/// `cpuUsage` function. Raw Mach pointers are consumed and freed here; only the
/// Sendable `CPUSample` (inside `MetricSample`) crosses the actor boundary.
actor CPUProvider: MetricProvider {
    let kind: ProviderKind = .cpu

    private let host = mach_host_self()
    private var prev: [CoreTicks]?
    private var topology: [PerfLevel]?

    func read(at instant: ContinuousClock.Instant) async -> ProviderReading {
        guard let curr = sampleTicks() else {
            return .unavailable(.providerError("CPU 사용률을 읽을 수 없음"))
        }
        if topology == nil { topology = Self.readTopology() }
        defer { prev = curr }
        guard let prev else { return .pending }   // first poll: no baseline yet
        return .value(.cpu(cpuUsage(prev: prev, curr: curr, topology: topology ?? [])))
    }

    // MARK: Mach tick snapshot (freed before returning — no leak, plan §1)

    private func sampleTicks() -> [CoreTicks]? {
        var count: natural_t = 0
        var infoPtr: processor_info_array_t?
        var infoCnt: mach_msg_type_number_t = 0
        let kr = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &infoPtr, &infoCnt)
        guard kr == KERN_SUCCESS, let info = infoPtr else { return nil }
        defer {
            let address = vm_address_t(UInt(bitPattern: UnsafeRawPointer(info)))
            vm_deallocate(mach_task_self_, address,
                          vm_size_t(Int(infoCnt) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        var ticks: [CoreTicks] = []
        ticks.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let base = i * states
            ticks.append(CoreTicks(
                user:   UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle:   UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice:   UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])))
        }
        return ticks
    }

    // MARK: Runtime topology (sysctl — never hardcoded, plan §2)

    private static func readTopology() -> [PerfLevel] {
        guard let n = sysctlInt("hw.nperflevels"), n > 0 else { return [] }
        return (0..<n).map { i in
            PerfLevel(name: sysctlString("hw.perflevel\(i).name") ?? "C",
                      coreCount: sysctlInt("hw.perflevel\(i).physicalcpu") ?? 0)
        }
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        if size <= MemoryLayout<Int32>.size {
            var v: Int32 = 0
            guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
            return Int(v)
        } else {
            var v: Int64 = 0
            guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
            return Int(v)
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}
