import Foundation

/// Real memory provider (issue 05) — no entitlements. Reads VM statistics +
/// physical memory size every poll (cheap), and enumerates the top memory-using
/// applications via `libproc` ONLY while enabled (the memory card's expand is
/// on-screen — issue 05 §M11). Every buffer here is caller-allocated, so unlike
/// `CPUProvider` (which frees `host_processor_info`'s array) there is nothing to
/// `vm_deallocate`. Only the Sendable `MemorySample` crosses the actor boundary.

/// Private XNU syscall #453 — the exact call `/usr/bin/memory_pressure` and the
/// open-source *Stats* app use to read the free-memory percentage that backs Activity
/// Monitor's "메모리 압력" graph. There is no public API for this number (Apple DTS
/// explicitly discourages any free-memory statistic), and the `host_statistics64`
/// occupancy ratio does NOT match the kernel's figure — so we bind the syscall directly.
/// Distinct Swift name via `@_silgen_name` so it never shadows a future SDK import.
@_silgen_name("memorystatus_get_level")
private func wattly_memorystatus_get_level(_ level: UnsafeMutablePointer<UInt32>) -> Int32

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
        let processLimit: Int
        let procs: [ProcessUsage]
        if enumerating {
            processLimit = memoryProcessLimit(
                UserDefaults.standard.object(forKey: StorageKey.memoryProcessLimit) as? Int)
            procs = Self.topMemoryProcesses(limit: processLimit)
        } else {
            processLimit = memoryProcessLimit(nil)
            procs = []
        }
        // Kernel memory-pressure verdict. A failed sysctl yields nil; presentation keeps the
        // memory card neutral rather than substituting an occupancy-based warning level.
        let pressure = Self.sysctlInt32("kern.memorystatus_vm_pressure_level").map(MemoryPressure.init(fromSysctl:))
        // Exact RAM-pressure percentage (Activity Monitor "메모리 압력") — the sub-line readout.
        let pressurePercent = Self.pressurePercent()
        return .value(.memory(memorySample(
            active: UInt64(vm.active_count),
            wire: UInt64(vm.wire_count),
            compressor: UInt64(vm.compressor_page_count),
            pageSize: pageSize == 0 ? 16384 : pageSize,
            memsize: memsize,
            processes: procs,
            processLimit: processLimit,
            pressure: pressure,
            pressurePercent: pressurePercent,
            swapUsedBytes: Self.swapUsedBytes())))
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

    /// Swap used in bytes from `vm.swapusage` (`xsw_usage.xsu_used`) — the counter macOS
    /// Activity Monitor labels "사용된 스왑 공간". A struct-valued sysctl (not a scalar), so it
    /// gets its own helper. 0 on failure → the card shows "스왑 0.0 GB" rather than a wrong number.
    private static func swapUsedBytes() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    /// Kernel RAM-pressure percent (0–100) via `memorystatus_get_level` (#453). The syscall
    /// fills a free-memory percentage; `memoryPressurePercent` inverts it. nil on failure →
    /// the card omits the 압력 segment rather than showing a wrong number. A cheap scalar
    /// read every poll (no gating), like `kern.memorystatus_vm_pressure_level`.
    private static func pressurePercent() -> Int? {
        var free: UInt32 = 0
        guard wattly_memorystatus_get_level(&free) == 0 else { return nil }
        return memoryPressurePercent(freeLevel: free)
    }

    // MARK: Top applications (libproc — no entitlement; own-user procs only, §M10)

    private static func topMemoryProcesses(limit: Int) -> [ProcessUsage] {
        // Resolve an application key for every readable PID before ranking: several helper
        // processes can together outrank a single larger process. The pid list + path helper
        // are shared with the power Top-N provider (`ProcessList`).
        var perProcess: [(key: String, bytes: UInt64)] = []
        for pid in listPIDs() where pid > 0 {
            guard let bytes = physFootprint(pid) else { continue }
            let path = pidPath(pid)
            let key = appBundlePath(forExecutable: path) ?? "PID \(pid)"
            perProcess.append((key: key, bytes: bytes))
        }
        return topMemoryApps(perProcess: perProcess, limit: limit)
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
