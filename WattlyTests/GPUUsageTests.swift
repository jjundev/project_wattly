import Testing
@testable import Wattly

struct GPUUsageTests {
    @Test func makeGPUSampleClampsAndPreservesEngineMetrics() {
        let sample = makeGPUSample(overall: 42.6,
                                   rendererUsage: 45.0,
                                   tilerUsage: 20.0,
                                   inUseMemoryBytes: 858 * 1024 * 1024,
                                   allocMemoryBytes: 2048 * 1024 * 1024,
                                   coreCount: 10,
                                   activeGHz: 1.28)
        #expect(abs(sample.overall - 42.6) < 1e-4)
        #expect(abs(sample.rendererUsage - 45.0) < 1e-4)
        #expect(abs(sample.tilerUsage - 20.0) < 1e-4)
        #expect(sample.inUseMemoryBytes == 858 * 1024 * 1024)
        #expect(sample.allocMemoryBytes == 2048 * 1024 * 1024)
        #expect(sample.coreCount == 10)
        #expect(sample.activeGHz == 1.28)
    }

    @Test func makeGPUSampleClampsBounds() {
        let low = makeGPUSample(overall: -5.0,
                                rendererUsage: -10.0,
                                tilerUsage: -2.0,
                                inUseMemoryBytes: 0,
                                allocMemoryBytes: 0,
                                coreCount: 8,
                                activeGHz: nil)
        #expect(low.overall == 0.0)
        #expect(low.rendererUsage == 0.0)
        #expect(low.tilerUsage == 0.0)

        let high = makeGPUSample(overall: 120.0,
                                 rendererUsage: 110.0,
                                 tilerUsage: 105.0,
                                 inUseMemoryBytes: 100,
                                 allocMemoryBytes: 100,
                                 coreCount: 8,
                                 activeGHz: nil)
        #expect(high.overall == 100.0)
        #expect(high.rendererUsage == 100.0)
        #expect(high.tilerUsage == 100.0)
    }

    @Test func makeGPUSampleFallbackZeroCoreCount() {
        let sample = makeGPUSample(overall: 50.0,
                                   rendererUsage: 50.0,
                                   tilerUsage: 25.0,
                                   inUseMemoryBytes: 0,
                                   allocMemoryBytes: 0,
                                   coreCount: 0,
                                   activeGHz: nil)
        #expect(sample.coreCount == 1)
    }
}

