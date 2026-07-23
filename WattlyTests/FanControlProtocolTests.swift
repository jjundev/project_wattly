import Foundation
import Testing
@testable import Wattly

struct FanControlProtocolTests {
    @Test func configurationRoundTrips() throws {
        let input = FanControlConfiguration(enabled: true,
                                            curve: FanCurve(rpms: [800,900,1000,1200,1500,1900,2400,3000,3600,4200,4800,5500,6200,6800,7400]))
        #expect(try FanControlCodec.decode(FanControlConfiguration.self,
                                           from: FanControlCodec.encode(input)) == input)
    }

    @Test func stateChangingRequestsCarryGeneration() throws {
        let configuration = FanControlConfiguration(enabled: false,
                                                     curve: FanCurve(rpms: [800,900,1000,1200,1500,1900,2400,3000,3600,4200,4800,5500,6200,6800,7400]))
        let configure = FanControlConfigurationRequest(configuration: configuration, generation: 41)
        let release = FanControlReleaseRequest(generation: 42)

        #expect(try FanControlCodec.decode(FanControlConfigurationRequest.self,
                                           from: FanControlCodec.encode(configure)) == configure)
        #expect(try FanControlCodec.decode(FanControlReleaseRequest.self,
                                           from: FanControlCodec.encode(release)) == release)
    }

    @Test func malformedConfigurationIsRejected() {
        #expect(throws: (any Error).self) {
            try FanControlCodec.decode(FanControlConfiguration.self, from: Data("{}".utf8))
        }
    }

    @Test func controllingStatusRoundTrips() throws {
        let input = FanControlServiceStatus(mode: .controlling, detail: "CPU 70°C", updatedAt: 100)
        #expect(try FanControlCodec.decode(FanControlServiceStatus.self,
                                          from: FanControlCodec.encode(input)) == input)
    }

    @Test func menuBarRecoveryOnlyReappliesWhenEnabledAndAutomatic() {
        #expect(FanControlPolicy.shouldReapplyAfterMenuBarOpen(enabled: true, mode: .automatic))
        #expect(!FanControlPolicy.shouldReapplyAfterMenuBarOpen(enabled: true, mode: .controlling))
        #expect(!FanControlPolicy.shouldReapplyAfterMenuBarOpen(enabled: true, mode: .engaging))
        #expect(!FanControlPolicy.shouldReapplyAfterMenuBarOpen(enabled: true, mode: .failed))
        #expect(!FanControlPolicy.shouldReapplyAfterMenuBarOpen(enabled: true, mode: .unavailable))
        #expect(!FanControlPolicy.shouldReapplyAfterMenuBarOpen(enabled: false, mode: .automatic))
    }

    @MainActor @Test func disabledMenuBarRecoverySendsNoRequest() async {
        let fake = FanControlRequestFake(responses: [])
        let client = FanControlClient(requestHandler: fake.handle)

        await client.reconcileAfterMenuBarOpen(enabled: false, curve: testCurve)

        #expect(fake.requests.isEmpty)
    }

    @MainActor @Test func automaticMenuBarRecoveryRefreshesThenConfigures() async throws {
        let fake = FanControlRequestFake(responses: [
            .success(FanControlServiceStatus(mode: .automatic, detail: "자동", updatedAt: 1)),
            .success(FanControlServiceStatus(mode: .controlling, detail: "제어 중", updatedAt: 2))
        ])
        let client = FanControlClient(requestHandler: fake.handle)

        await client.reconcileAfterMenuBarOpen(enabled: true, curve: testCurve)

        #expect(fake.requests.count == 2)
        #expect(fake.requests[0] == .status)
        guard case let .configure(data) = fake.requests[1] else {
            Issue.record("automatic recovery should dispatch configure after status")
            return
        }
        let request = try FanControlCodec.decode(FanControlConfigurationRequest.self, from: data)
        #expect(request.configuration == FanControlConfiguration(enabled: true, curve: testCurve))
    }

    @MainActor @Test func nonAutomaticMenuBarRecoveryRefreshesWithoutConfiguring() async {
        let fake = FanControlRequestFake(responses: [
            .success(FanControlServiceStatus(mode: .controlling, detail: "제어 중", updatedAt: 1))
        ])
        let client = FanControlClient(requestHandler: fake.handle)

        await client.reconcileAfterMenuBarOpen(enabled: true, curve: testCurve)

        #expect(fake.requests == [.status])
    }

    private static let testCurve = FanCurve(rpms: [800, 900, 1000, 1200, 1500,
                                                     1900, 2400, 3000, 3600, 4200,
                                                     4800, 5500, 6200, 6800, 7400])

    private var testCurve: FanCurve { Self.testCurve }
}

private final class FanControlRequestFake: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [FanControlClientRequest] = []
    private var responses: [Result<FanControlServiceStatus, FanControlClientRequestFailure>]

    init(responses: [Result<FanControlServiceStatus, FanControlClientRequestFailure>]) {
        self.responses = responses
    }

    var requests: [FanControlClientRequest] {
        withLock { recordedRequests }
    }

    func handle(_ request: FanControlClientRequest) async -> Result<FanControlServiceStatus, FanControlClientRequestFailure> {
        withLock {
            recordedRequests.append(request)
            return responses.removeFirst()
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
