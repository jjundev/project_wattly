import Foundation
import IOKit

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

        guard let util = Self.readDeviceUtilization() else {
            return .unavailable(.providerError("GPU 사용률을 읽을 수 없음"))
        }

        let ghz = clock?.sampleGHz()
        let sample = makeGPUSample(overall: util, coreCount: coreCount ?? 8, activeGHz: ghz)
        return .value(.gpu(sample))
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

    private static func readDeviceUtilization() -> Double? {
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
               let util = dict["Device Utilization %"] as? Int {
                return Double(util)
            }
        }
        return nil
    }
}
