import Foundation
import IOKit

/// Snapshot of raw GPU statistics parsed from IOAccelerator.
struct GPUStatsSnapshot: Sendable {
    var deviceUtilization: Double
    var rendererUtilization: Double
    var tilerUtilization: Double
    var inUseMemoryBytes: UInt64
    var allocMemoryBytes: UInt64
}

/// Real GPU provider reading IOAccelerator's `PerformanceStatistics` for utilization and
/// `gpu-core-count`, coupled with `RealGPUClock` for DVFS active clock.
actor GPUProvider: MetricProvider {
    let kind: ProviderKind = .gpu

    private var coreCount: Int?
    private var clockSetupAttempted = false
    private var clock: RealGPUClock?

    func read(at instant: ContinuousClock.Instant) async -> ProviderReading {
        if coreCount == nil { coreCount = Self.readCoreCount() }
        if !clockSetupAttempted { clockSetupAttempted = true; clock = RealGPUClock() }

        guard let stats = Self.readPerformanceStatistics() else {
            return .unavailable(.providerError("GPU 사용률을 읽을 수 없음"))
        }

        let ghz = clock?.sampleGHz()
        let sample = makeGPUSample(
            overall: stats.deviceUtilization,
            rendererUsage: stats.rendererUtilization,
            tilerUsage: stats.tilerUtilization,
            inUseMemoryBytes: stats.inUseMemoryBytes,
            allocMemoryBytes: stats.allocMemoryBytes,
            coreCount: coreCount ?? 8,
            activeGHz: ghz
        )
        return .value(.gpu(sample))
    }

    private static func readPerformanceStatistics() -> GPUStatsSnapshot? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        while true {
            let service = IOIteratorNext(iter)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            if let cf = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let dict = cf as? [String: Any],
               let devUtil = dict["Device Utilization %"] as? Int {
                let rendUtil = dict["Renderer Utilization %"] as? Int ?? devUtil
                let tileUtil = dict["Tiler Utilization %"] as? Int ?? 0
                let inUseMem = (dict["In use system memory"] as? NSNumber)?.uint64Value ?? 0
                let allocMem = (dict["Alloc system memory"] as? NSNumber)?.uint64Value ?? inUseMem
                return GPUStatsSnapshot(
                    deviceUtilization: Double(devUtil),
                    rendererUtilization: Double(rendUtil),
                    tilerUtilization: Double(tileUtil),
                    inUseMemoryBytes: inUseMem,
                    allocMemoryBytes: allocMem
                )
            }
        }
        return nil
    }

    private static func readCoreCount() -> Int {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return 8 }
        defer { IOObjectRelease(iter) }
        while true {
            let service = IOIteratorNext(iter)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            if let cf = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let count = cf as? Int, count > 0 {
                return count
            }
        }
        return 8
    }
}

