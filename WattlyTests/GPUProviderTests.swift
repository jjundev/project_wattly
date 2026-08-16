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
            #expect(sample.cores.count == sample.coreCount)
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
}
