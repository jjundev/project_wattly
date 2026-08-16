import Foundation
import IOKit

/// Snapshot of raw GPU statistics parsed from IOAccelerator.
struct GPUStatsSnapshot: Sendable, Equatable {
    var deviceUtilization: Double
    var rendererUtilization: Double
    var tilerUtilization: Double
    var inUseMemoryBytes: UInt64
    var allocMemoryBytes: UInt64

    init(
        deviceUtilization: Double,
        rendererUtilization: Double,
        tilerUtilization: Double,
        inUseMemoryBytes: UInt64,
        allocMemoryBytes: UInt64
    ) {
        self.deviceUtilization = deviceUtilization
        self.rendererUtilization = rendererUtilization
        self.tilerUtilization = tilerUtilization
        self.inUseMemoryBytes = inUseMemoryBytes
        self.allocMemoryBytes = allocMemoryBytes
    }
}

/// What the GPU provider reads through — a single read-only transport seam
/// abstracting IOAccelerator IOKit access for utilization, memory, and core counts.
protocol GPUTransport: Sendable {
    /// Reads raw performance statistics snapshot from IOAccelerator driver, or `nil` if unavailable.
    func readPerformanceStatistics() -> GPUStatsSnapshot?

    /// Reads the GPU core count from IOAccelerator, returning a fallback default if unavailable.
    func readCoreCount() -> Int
}

/// Live `GPUTransport` implementation reading from IOKit's `IOAccelerator` service.
final class IOAcceleratorGPUTransport: GPUTransport, @unchecked Sendable {
    func readPerformanceStatistics() -> GPUStatsSnapshot? {
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

    func readCoreCount() -> Int {
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
