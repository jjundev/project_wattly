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

    @MainActor @Test func clientInitialStateIsUnavailableAndNotInstalling() {
        let client = FanControlClient()
        #expect(client.status.mode == .unavailable)
        #expect(client.isInstallingHelper == false)
    }

    @Test func xpcServiceProtocolDeclaresAllMethods() {
        let interface = NSXPCInterface(with: FanControlXPCService.self)
        #expect(NSStringFromProtocol(interface.protocol) == "FanControlXPCService")

        final class MockService: NSObject, FanControlXPCService {
            func configure(_ data: Data, withReply reply: @escaping (Data?, NSError?) -> Void) { reply(nil, nil) }
            func heartbeat(withReply reply: @escaping (Data?, NSError?) -> Void) { reply(nil, nil) }
            func release(_ data: Data, withReply reply: @escaping (Data?, NSError?) -> Void) { reply(nil, nil) }
            func status(withReply reply: @escaping (Data?, NSError?) -> Void) { reply(nil, nil) }
            func configureBattery(_ data: Data, withReply reply: @escaping (Data?, NSError?) -> Void) { reply(nil, nil) }
            func batteryStatus(withReply reply: @escaping (Data?, NSError?) -> Void) { reply(nil, nil) }
        }

        let mock: any FanControlXPCService = MockService()
        var replyCalled = false
        mock.configureBattery(Data()) { _, _ in replyCalled = true }
        #expect(replyCalled)
    }

    @Test func batteryReleaseVerificationDispatchesBeforeUIDValidation() throws {
        let source = try daemonSource(named: "main.swift")
        let oneShot = try #require(source.range(
            of: "CommandLine.arguments.contains(\"--verify-battery-release\")"))
        let uidValidation = try #require(source.range(
            of: "WATTLY_ALLOWED_UID"))

        #expect(oneShot.lowerBound < uidValidation.lowerBound)
    }

    @Test func batteryKeyInfoUsesTheSharedSafetyClassifier() throws {
        let source = try daemonSource(named: "SMCControlConnection.swift")
        let methodStart = try #require(source.range(of: "func batteryKeyProbe(_ key: String)"))
        let methodEnd = try #require(source.range(
            of: "func read(_ key: String)",
            range: methodStart.upperBound..<source.endIndex))
        let method = source[methodStart.lowerBound..<methodEnd.lowerBound]

        #expect(method.contains(".fromSMCKeyInfo("))
        #expect(!method.contains("keyNotFoundResult"))
    }

    @Test func cliReplacementTransactionLocksOwnershipThroughKickstart() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let scriptURL = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("scripts/install-fan-helper.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let acquire = try #require(script.range(of: "/usr/bin/shlock -f \"$ownership_lock\" -p \"$$\""))
        let finalCheck = try #require(script.range(of: "validate_installed_owner\n\"$daemon_path\" --verify-battery-release"))
        let bootout = try #require(script.range(of: "launchctl bootout \"system/$daemon_label\""))
        let kickstart = try #require(script.range(of: "launchctl kickstart -k \"system/$daemon_label\""))
        let releaseTrap = try #require(script.range(of: "trap cleanup_ownership_lock EXIT"))

        #expect(acquire.lowerBound < finalCheck.lowerBound)
        #expect(finalCheck.lowerBound < bootout.lowerBound)
        #expect(bootout.lowerBound < kickstart.lowerBound)
        #expect(releaseTrap.lowerBound < finalCheck.lowerBound)
        #expect(script.contains("Ownership replacement is already in progress."))
    }

    @Test func batteryConfigurationXPCDelegatesInsideSerializedQueue() throws {
        let source = try daemonSource(named: "FanControlDaemon.swift")
        let start = try #require(source.range(of: "func configureBattery("))
        let end = try #require(source.range(
            of: "func batteryStatus(",
            range: start.upperBound..<source.endIndex))
        let method = source[start.lowerBound..<end.lowerBound]

        #expect(method.contains("queue.async"))
        #expect(method.contains("batteryControlService.configure("))
        #expect(method.contains("encodedStatus"))
        #expect(!method.contains("BatteryControlCodec.decode("))
        #expect(!method.contains("lastBatteryGeneration"))
        #expect(!method.contains("batteryCoordinator.configure"))
    }

    private static let testCurve = FanCurve(rpms: [800, 900, 1000, 1200, 1500,
                                                     1900, 2400, 3000, 3600, 4200,
                                                     4800, 5500, 6200, 6800, 7400])

    private var testCurve: FanCurve { Self.testCurve }

    private func daemonSource(named name: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("WattlyFanDaemon")
            .appendingPathComponent(name)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
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
