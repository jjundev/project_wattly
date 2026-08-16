import Testing
@testable import Wattly

struct GPUUsageTests {
    @Test func makeGPUSampleClampsOverallAndFillsCores() {
        let sample = makeGPUSample(overall: 42.6, coreCount: 10, activeGHz: 1.28)
        #expect(abs(sample.overall - 42.6) < 1e-4)
        #expect(sample.coreCount == 10)
        #expect(sample.activeGHz == 1.28)
        #expect(sample.cores.count == 10)
        for core in sample.cores {
            #expect(abs(core - 42.6) < 1e-4)
        }
    }

    @Test func makeGPUSampleClampsBounds() {
        let low = makeGPUSample(overall: -5.0, coreCount: 8, activeGHz: nil)
        #expect(low.overall == 0.0)
        #expect(low.cores.count == 8)
        #expect(low.cores.allSatisfy { $0 == 0.0 })

        let high = makeGPUSample(overall: 120.0, coreCount: 8, activeGHz: nil)
        #expect(high.overall == 100.0)
        #expect(high.cores.count == 8)
        #expect(high.cores.allSatisfy { $0 == 100.0 })
    }

    @Test func makeGPUSampleFallbackZeroCoreCount() {
        let sample = makeGPUSample(overall: 50.0, coreCount: 0, activeGHz: nil)
        #expect(sample.overall == 50.0)
        #expect(sample.coreCount == 1)
        #expect(sample.cores.count == 1)
    }
}
