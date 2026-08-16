import Testing
import Foundation
@testable import Wattly

struct GPUProviderTests {
    @Test func gpuProviderKind() async {
        let provider = GPUProvider()
        #expect(await provider.kind == .gpu)
    }

    @Test func gpuProviderReadReturnsValueOrUnavailable() async {
        let provider = GPUProvider()
        let reading = await provider.read(at: ContinuousClock.now)
        switch reading {
        case .value(.gpu(let sample)):
            #expect(sample.overall >= 0.0 && sample.overall <= 100.0)
            #expect(sample.coreCount > 0)
        case .unavailable:
            // Graceful degrade if IOAccelerator is not present or unreadable in environment
            break
        default:
            Issue.record("Unexpected reading: \(reading)")
        }
    }

    @Test func fakeProvidersIncludesGPUProvider() {
        let providers = FakeProviders.all(scenario: .laptop)
        let gpuProvider = providers.first { $0.kind == .gpu }
        #expect(gpuProvider is GPUProvider)
    }

    @Test func gpuProviderPopulatesEngineAndMemoryMetrics() async {
        let fake = FakeProvider(kind: .gpu, scenario: .laptop)
        let reading = await fake.read(at: .now)
        if case .value(.gpu(let sample)) = reading {
            #expect(sample.overall >= 0)
            #expect(sample.rendererUsage >= 0)
            #expect(sample.tilerUsage >= 0)
            #expect(sample.inUseMemoryBytes > 0)
            #expect(sample.allocMemoryBytes >= sample.inUseMemoryBytes)
            #expect(sample.coreCount > 0)
        } else {
            Issue.record("Expected .value(.gpu) from FakeProvider")
        }
    }
}

struct FakeGPUTransport: GPUTransport {
    var stats: GPUStatsSnapshot?
    var coreCount: Int = 10
    
    func readPerformanceStatistics() -> GPUStatsSnapshot? { stats }
    func readCoreCount() -> Int { coreCount }
}

final class SpyGPUTransport: GPUTransport, @unchecked Sendable {
    var stats: GPUStatsSnapshot?
    var coreCount: Int = 10
    private(set) var readCoreCountCallCount: Int = 0
    private(set) var readPerformanceStatisticsCallCount: Int = 0

    init(stats: GPUStatsSnapshot? = nil, coreCount: Int = 10) {
        self.stats = stats
        self.coreCount = coreCount
    }

    func readPerformanceStatistics() -> GPUStatsSnapshot? {
        readPerformanceStatisticsCallCount += 1
        return stats
    }

    func readCoreCount() -> Int {
        readCoreCountCallCount += 1
        return coreCount
    }
}

@Suite struct GPUProviderSeamTests {
    @Test func unavailableWhenTransportFails() async {
        let provider = GPUProvider(transport: FakeGPUTransport(stats: nil))
        let reading = await provider.read(at: ContinuousClock().now)
        guard case .unavailable(let reason) = reading else {
            Issue.record("Expected unavailable, got \(reading)")
            return
        }
        #expect(reason.shortMessage == "오류")
    }

    @Test func valueWhenTransportSucceeds() async {
        let stats = GPUStatsSnapshot(
            deviceUtilization: 42.0,
            rendererUtilization: 35.0,
            tilerUtilization: 12.0,
            inUseMemoryBytes: 2 * 1024 * 1024 * 1024,
            allocMemoryBytes: 4 * 1024 * 1024 * 1024
        )
        let provider = GPUProvider(transport: FakeGPUTransport(stats: stats, coreCount: 16))
        let reading = await provider.read(at: ContinuousClock().now)
        guard case .value(.gpu(let sample)) = reading else {
            Issue.record("Expected .value(.gpu), got \(reading)")
            return
        }
        #expect(sample.overall == 42.0)
        #expect(sample.rendererUsage == 35.0)
        #expect(sample.tilerUsage == 12.0)
        #expect(sample.inUseMemoryBytes == 2 * 1024 * 1024 * 1024)
        #expect(sample.allocMemoryBytes == 4 * 1024 * 1024 * 1024)
        #expect(sample.coreCount == 16)
    }

    @Test func coreCountCachesAcrossMultipleReads() async {
        let stats = GPUStatsSnapshot(
            deviceUtilization: 10.0,
            rendererUtilization: 10.0,
            tilerUtilization: 5.0,
            inUseMemoryBytes: 1024,
            allocMemoryBytes: 2048
        )
        let spy = SpyGPUTransport(stats: stats, coreCount: 12)
        let provider = GPUProvider(transport: spy)

        let reading1 = await provider.read(at: ContinuousClock().now)
        let reading2 = await provider.read(at: ContinuousClock().now)

        guard case .value(.gpu(let s1)) = reading1, case .value(.gpu(let s2)) = reading2 else {
            Issue.record("Expected .value(.gpu)")
            return
        }
        #expect(s1.coreCount == 12)
        #expect(s2.coreCount == 12)
        #expect(spy.readCoreCountCallCount == 1)
        #expect(spy.readPerformanceStatisticsCallCount == 2)
    }
}


