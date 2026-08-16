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

