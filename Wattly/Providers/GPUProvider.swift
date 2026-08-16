import Foundation

/// Real GPU provider reading IOAccelerator's `PerformanceStatistics` for utilization and
/// `gpu-core-count`, coupled with `RealGPUClock` for DVFS active clock.
actor GPUProvider: MetricProvider {
    let kind: ProviderKind = .gpu

    private let transport: any GPUTransport
    private var coreCount: Int?
    private var clockSetupAttempted = false
    private var clock: RealGPUClock?

    init(transport: any GPUTransport = IOAcceleratorGPUTransport()) {
        self.transport = transport
    }

    func read(at instant: ContinuousClock.Instant) async -> ProviderReading {
        if coreCount == nil { coreCount = transport.readCoreCount() }
        if !clockSetupAttempted { clockSetupAttempted = true; clock = RealGPUClock() }

        guard let stats = transport.readPerformanceStatistics() else {
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
}
