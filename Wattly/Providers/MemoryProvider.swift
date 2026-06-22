import Foundation

/// Real memory provider (issue 05) — no entitlements. Reads VM statistics +
/// physical memory size every poll (cheap), and enumerates the top memory-using
/// processes via `libproc` ONLY while enabled (the memory card's expand is
/// on-screen — issue 05 §M11). Every buffer here is caller-allocated, so unlike
/// `CPUProvider` (which frees `host_processor_info`'s array) there is nothing to
/// `vm_deallocate`. Only the Sendable `MemorySample` crosses the actor boundary.
actor MemoryProvider: MetricProvider, ProcessEnumerating {
    let kind: ProviderKind = .memory

    private let host = mach_host_self()
    /// Gate the process sweep to when the expand is visible (issue 05 §M11).
    private var enumerating = false
    /// Constants — read once, then cached (actor-isolated lazy).
    private lazy var memsize: UInt64 = Self.sysctlUInt64("hw.memsize") ?? 0
    private lazy var pageSize: UInt64 = hostPageSize()

    func setEnumerating(_ enabled: Bool) { enumerating = enabled }

    func read(at instant: ContinuousClock.Instant) async -> ProviderReading {
        guard let vm = vmStatistics() else {
            return .unavailable(.providerError("메모리 통계를 읽을 수 없음"))
        }
        let procs = enumerating ? Self.topMemoryProcesses(limit: 3) : []
        // Kernel memory-pressure verdict — cheap scalar read every poll (no gating). nil on
        // failure → the card falls back to the used% band (CardPresentation).
        let pressure = Self.sysctlInt32("kern.memorystatus_vm_pressure_level").map(MemoryPressure.init(fromSysctl:))
        return .value(.memory(memorySample(
            active: UInt64(vm.active_count),
            wire: UInt64(vm.wire_count),
            compressor: UInt64(vm.compressor_page_count),
            pageSize: pageSize == 0 ? 16384 : pageSize,
            memsize: memsize,
            processes: procs,
            pressure: pressure)))
    }

    // MARK: VM statistics + constants (host_statistics64 fills a caller struct — no free)

    private func vmStatistics() -> vm_statistics64_data_t? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? stats : nil
    }

    private func hostPageSize() -> UInt64 {
        var size: vm_size_t = 0
        guard host_page_size(host, &size) == KERN_SUCCESS else { return 0 }
        return UInt64(size)
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    /// Read a 4-byte `Int32` sysctl (e.g. `kern.memorystatus_vm_pressure_level`). A separate
    /// helper from `sysctlUInt64` because that one passes an 8-byte buffer — wrong width for a
    /// 32-bit sysctl. Size-probes first (mirrors `CPUProvider.sysctlInt`).
    private static func sysctlInt32(_ name: String) -> Int32? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size else { return nil }
        var value: Int32 = 0
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    // MARK: Top processes (libproc — no entitlement; own-user procs only, §M10)

    private static func topMemoryProcesses(limit: Int) -> [ProcessUsage] {
        // Footprint-only sweep over all readable pids (cheap), then resolve name +
        // icon path for JUST the top-N — avoids hundreds of proc_name/proc_pidpath
        // calls per refresh (skip unreadable: other user / system, §M10). The pid list
        // + name/path helpers are shared with the power Top-3 (`ProcessList`).
        var footprints: [(pid: pid_t, bytes: UInt64)] = []
        for pid in listPIDs() where pid > 0 {
            if let bytes = physFootprint(pid) { footprints.append((pid, bytes)) }
        }
        return footprints.sorted { $0.bytes > $1.bytes }.prefix(limit).map { entry in
            let path = pidPath(entry.pid)
            return ProcessUsage(pid: entry.pid,
                                name: procName(of: entry.pid, path: path),
                                footprintBytes: entry.bytes,
                                iconPath: appBundlePath(forExecutable: path))
        }
    }

    /// `ri_phys_footprint` via `proc_pid_rusage`; nil if the process is unreadable.
    /// `ri_phys_footprint` is present from `RUSAGE_INFO_V0`; V2 used for headroom.
    private static func physFootprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v2()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        return rc == 0 ? info.ri_phys_footprint : nil
    }
}
