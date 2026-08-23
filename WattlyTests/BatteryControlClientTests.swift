import Foundation
import Testing
@testable import Wattly

private actor RequestReceiver {
    var request: BatteryControlClient.BatteryControlClientRequest?
    func set(_ request: BatteryControlClient.BatteryControlClientRequest) {
        self.request = request
    }
}

private actor FailureSwitch {
    var isOn = false
    func turnOn() { isOn = true }
}

private actor RequestRecorder {
    var kinds: [String] = []
    func record(_ request: BatteryControlClient.BatteryControlClientRequest) {
        switch request {
        case .configure: kinds.append("configure")
        case .status: kinds.append("status")
        }
    }
}

private actor ScriptRecorder {
    private var script = ""
    func record(_ script: String) { self.script = script }
    var value: String { script }
}

struct BatteryControlClientTests {
    @MainActor @Test func clientAppliesConfigurationAndUpdatesStatus() async throws {
        let expectedStatus = BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 85,
            isPowerAdapterConnected: true,
            detail: "85% 바이패스 구동 중",
            updatedAt: 1.0
        )
        let receiver = RequestReceiver()
        let client = BatteryControlClient { request in
            await receiver.set(request)
            switch request {
            case .configure:
                let data = try? BatteryControlCodec.encode(expectedStatus)
                return (data, nil)
            case .status:
                let data = try? BatteryControlCodec.encode(expectedStatus)
                return (data, nil)
            }
        }

        let acknowledged = await client.apply(enabled: true, limitPercentage: 85)
        #expect(acknowledged == expectedStatus)
        #expect(client.status.mode == .inhibited)
        #expect(client.status.currentPercentage == 85)
        #expect(client.status.isPowerAdapterConnected == true)

        let receivedRequest = await receiver.request
        if case .configure(let data) = receivedRequest {
            let req = try BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
            #expect(req.configuration.enabled == true)
            #expect(req.configuration.limitPercentage == 85)
        } else {
            Issue.record("Expected configure request")
        }
    }

    @MainActor @Test func clientSendsConfiguredDeltaToDaemon() async throws {
        let receiver = RequestReceiver()
        let client = BatteryControlClient(requestHandler: { request in
            await receiver.set(request)
            let status = BatteryControlServiceStatus(mode: .charging, currentPercentage: 80, isPowerAdapterConnected: true, detail: "OK", updatedAt: Date().timeIntervalSince1970)
            let data = try? BatteryControlCodec.encode(status)
            return (data, nil)
        })

        await client.apply(enabled: true, limitPercentage: 85, lowerHysteresisDelta: 5)
        let receivedRequest = await receiver.request
        if case .configure(let data) = receivedRequest {
            let req = try BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
            #expect(req.configuration.enabled == true)
            #expect(req.configuration.limitPercentage == 85)
            #expect(req.configuration.lowerHysteresisDelta == 5)
        } else {
            Issue.record("Expected configure request")
        }
    }

    @MainActor @Test func disableFailsWhenTheHelperDoesNotAcknowledge() async {
        let client = BatteryControlClient(requestHandler: { _ in (nil, nil) })
        #expect(await client.disableAndConfirm() == .helperUnavailable)
    }

    @MainActor @Test func disableFailsWhenPersistenceIsNotAcknowledged() async throws {
        let status = BatteryControlServiceStatus(
            mode: .charging, currentPercentage: 70, isPowerAdapterConnected: true,
            detail: "OK", updatedAt: 1,
            desiredConfiguration: .init(enabled: true, limitPercentage: 85),
            actualGate: .allowed)
        let client = BatteryControlClient(requestHandler: { _ in
            (try? BatteryControlCodec.encode(status), nil)
        })
        #expect(await client.disableAndConfirm() == .persistenceRejected)
    }

    @MainActor @Test func disableFailsWhenReleaseCannotBeVerified() async throws {
        let status = BatteryControlServiceStatus(
            mode: .charging, currentPercentage: 70, isPowerAdapterConnected: true,
            detail: "OK", updatedAt: 1,
            desiredConfiguration: .init(enabled: false, limitPercentage: 100),
            actualGate: .inhibited(appliedLimitPercentage: 85), releaseVerdict: .failed)
        let client = BatteryControlClient(requestHandler: { _ in
            (try? BatteryControlCodec.encode(status), nil)
        })
        #expect(await client.disableAndConfirm() == .releaseUnverified)
    }

    @MainActor @Test func disableSucceedsOnlyWithVerifiedRelease() async throws {
        let status = BatteryControlServiceStatus(
            mode: .charging, currentPercentage: 70, isPowerAdapterConnected: true,
            detail: "OK", updatedAt: 1,
            desiredConfiguration: .init(enabled: false, limitPercentage: 100),
            actualGate: .allowed, releaseVerdict: .verifiedAllowed)
        let client = BatteryControlClient(requestHandler: { _ in
            (try? BatteryControlCodec.encode(status), nil)
        })
        #expect(await client.disableAndConfirm() == nil)
        #expect(client.status.actualGate?.state == .allowed)
    }

    @MainActor @Test func disableAcknowledgesTheRequestedFullConfiguration() async throws {
        let requested = BatteryControlConfiguration(
            enabled: false, limitPercentage: 85, lowerHysteresisDelta: 5)
        let status = BatteryControlServiceStatus(
            mode: .charging, currentPercentage: 70, isPowerAdapterConnected: true,
            detail: "OK", updatedAt: 1, desiredConfiguration: requested,
            actualGate: .allowed)
        let receiver = RequestReceiver()
        let client = BatteryControlClient(requestHandler: { request in
            await receiver.set(request)
            return (try? BatteryControlCodec.encode(status), nil)
        })

        #expect(await client.disableAndConfirm(
            limitPercentage: 85, lowerHysteresisDelta: 5) == nil)
        guard case .configure(let data) = await receiver.request else {
            Issue.record("Expected configure request")
            return
        }
        let sent = try BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
        #expect(sent.configuration == requested)
    }

    @Test func legacyWakeWithDisabledConfigurationUsesVerifiedDisable() {
        let configuration = BatteryControlConfiguration(
            enabled: false, limitPercentage: 85, lowerHysteresisDelta: 5)
        let legacy = BatteryControlServiceStatus(
            mode: .charging, currentPercentage: 80, isPowerAdapterConnected: true,
            detail: "OK", updatedAt: 1, appliedLimitPercentage: nil)

        #expect(BatteryControlBridge.wakeAction(
            configuration: configuration, status: legacy) == .disableAndConfirm)
    }

    @Test func differentInstalledOwnerIsBlockedWithoutTransfer() throws {
        #expect(throws: FanHelperInstaller.OwnershipError.self) {
            try FanHelperInstaller.validateOwnership(
                installedOwnership: .owner(UInt32(getuid()) + 1),
                currentUID: UInt32(getuid()), transferringOwnership: false)
        }
    }

    @Test func explicitTransferAllowsTheNewOwner() throws {
        try FanHelperInstaller.validateOwnership(
            installedOwnership: .owner(UInt32(getuid()) + 1),
            currentUID: UInt32(getuid()), transferringOwnership: true)
    }

    @Test func installedOwnershipReadsTheLaunchDaemonEnvironment() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let object: [String: Any] = ["EnvironmentVariables": ["WATTLY_ALLOWED_UID": "502"]]
        let data = try PropertyListSerialization.data(
            fromPropertyList: object, format: .xml, options: 0)
        try data.write(to: fixture)
        #expect(FanHelperInstaller.installedOwnership(plistURL: fixture) == .owner(502))
    }

    @Test func malformedInstalledPlistRequiresExplicitTransfer() throws {
        #expect(throws: FanHelperInstaller.OwnershipError.self) {
            try FanHelperInstaller.validateOwnership(
                installedOwnership: .invalidMetadata, currentUID: 501,
                transferringOwnership: false)
        }
        try FanHelperInstaller.validateOwnership(
            installedOwnership: .invalidMetadata, currentUID: 501,
            transferringOwnership: true)
    }

    @Test func injectedRunnerReceivesTheCompleteInstallScript() async throws {
        let recorder = ScriptRecorder()
        let executable = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(
            atPath: executable.path, contents: Data(),
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: executable) }
        try await FanHelperInstaller.install(
            transferringOwnership: true,
            daemonURL: executable,
            installedPlistURL: executable.deletingLastPathComponent()
                .appendingPathComponent("missing-\(UUID().uuidString).plist"),
            currentUID: 501,
            privilegedRunner: { script in await recorder.record(script) })
        let script = await recorder.value
        #expect(script.contains("launchctl bootstrap system"))
        #expect(script.contains("launchctl kickstart -k"))
        #expect(script.contains("--verify-battery-release"))
        #expect(!script.contains("bootout system/\(FanHelperInstaller.label) 2>/dev/null || true"))
    }

    @MainActor @Test func clientInitialStateIsUnavailable() {
        let client = BatteryControlClient()
        #expect(client.status.mode == .unavailable)
        #expect(client.isInstallingHelper == false)
    }

    @MainActor @Test func clientRefreshesStatus() async {
        let expectedStatus = BatteryControlServiceStatus(
            mode: .charging,
            currentPercentage: 70,
            isPowerAdapterConnected: true,
            detail: "목표치(80%)까지 충전 중",
            updatedAt: 2.0
        )
        let client = BatteryControlClient { request in
            switch request {
            case .configure:
                return (nil, nil)
            case .status:
                let data = try? BatteryControlCodec.encode(expectedStatus)
                return (data, nil)
            }
        }

        await client.refreshStatus()
        #expect(client.status.mode == .charging)
        #expect(client.status.currentPercentage == 70)
        #expect(client.status.detail == "목표치(80%)까지 충전 중")
    }

    @MainActor @Test func clientMarksItselfUnavailableAfterAGoodStatusGoesBad() async {
        let good = BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 85,
            isPowerAdapterConnected: true,
            detail: "충전 제한 85% 도달 (전원 어댑터 바이패스 구동)",
            updatedAt: 1.0,
            appliedLimitPercentage: 85
        )
        let failNow = FailureSwitch()
        let client = BatteryControlClient { _ in
            if await failNow.isOn {
                return (nil, NSError(domain: "WattlyTest", code: -1,
                                     userInfo: [NSLocalizedDescriptionKey: "도우미 연결 끊김"]))
            }
            return (try? BatteryControlCodec.encode(good), nil)
        }

        await client.apply(enabled: true, limitPercentage: 85)
        #expect(client.status.mode == .inhibited)

        await failNow.turnOn()
        await client.refreshStatus()
        #expect(client.status.mode == .unavailable)
        #expect(client.status.detail == "도우미 연결 끊김")
        #expect(client.status.appliedLimitPercentage == nil)
    }

    @MainActor @Test func clientMarksItselfUnavailableWhenTheReplyIsUndecodable() async {
        let good = BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 85,
            isPowerAdapterConnected: true,
            detail: "충전 제한 85% 도달 (전원 어댑터 바이패스 구동)",
            updatedAt: 1.0,
            appliedLimitPercentage: 85
        )
        let garbage = FailureSwitch()
        let client = BatteryControlClient { _ in
            if await garbage.isOn { return (Data("not json".utf8), nil) }
            return (try? BatteryControlCodec.encode(good), nil)
        }

        await client.apply(enabled: true, limitPercentage: 85)
        #expect(client.status.mode == .inhibited)

        // A reply that arrives but cannot be decoded is just as much a dead helper as no reply.
        await garbage.turnOn()
        await client.refreshStatus()
        #expect(client.status.mode == .unavailable)
        #expect(client.status.detail == "도우미 응답 오류")
    }

    @MainActor @Test func reconcileRepushesTheLimitWhenTheHelperForgotIt() async {
        let forgetful = BatteryControlServiceStatus(
            mode: .charging,
            currentPercentage: 70,
            isPowerAdapterConnected: true,
            detail: "충전 제한 비활성화됨",
            updatedAt: 1.0,
            appliedLimitPercentage: nil
        )
        let recorder = RequestRecorder()
        let client = BatteryControlClient { request in
            await recorder.record(request)
            return (try? BatteryControlCodec.encode(forgetful), nil)
        }

        await client.reconcile(enabled: true, limitPercentage: 85)

        let kinds = await recorder.kinds
        #expect(kinds.count == 2)
        #expect(kinds.first == "status")
        #expect(kinds.last == "configure")
    }

    @MainActor @Test func reconcileIsSilentWhenTheHelperAlreadyAgrees() async {
        let agreeing = BatteryControlServiceStatus(
            mode: .charging,
            currentPercentage: 70,
            isPowerAdapterConnected: true,
            detail: "목표치(85%)까지 충전 중",
            updatedAt: 1.0,
            appliedLimitPercentage: 85
        )
        let recorder = RequestRecorder()
        let client = BatteryControlClient { request in
            await recorder.record(request)
            return (try? BatteryControlCodec.encode(agreeing), nil)
        }

        await client.reconcile(enabled: true, limitPercentage: 85)

        let kinds = await recorder.kinds
        #expect(kinds == ["status"])
    }

    @MainActor @Test func reconcileDoesNotWriteAfterItsTaskIsCancelled() async {
        let forgetful = BatteryControlServiceStatus(
            mode: .charging,
            currentPercentage: 70,
            isPowerAdapterConnected: true,
            detail: "충전 제한 비활성화됨",
            updatedAt: 1.0,
            appliedLimitPercentage: nil
        )
        let recorder = RequestRecorder()
        let client = BatteryControlClient { request in
            await recorder.record(request)
            return (try? BatteryControlCodec.encode(forgetful), nil)
        }

        // A status that disagrees with the opt-in would normally trigger a re-push. Cancellation
        // must stop the write even though the status read still completes.
        let task = Task { await client.reconcile(enabled: true, limitPercentage: 85) }
        task.cancel()
        await task.value

        let kinds = await recorder.kinds
        #expect(kinds == ["status"])
    }

    @MainActor
    @Test func installFailureCarriesTheStatusRatherThanAKoreanSentence() async {
        // 도우미는 설치됐지만 설정 푸시가 거부된 상황. 클라이언트는 문장을 조립하지 않고
        // 사유와 원문을 그대로 넘겨야 한다 — 언어를 아는 쪽은 뷰다.
        let client = BatteryControlClient(requestHandler: { _ in
            let status = BatteryControlServiceStatus(
                mode: .unsupported,
                currentPercentage: 70,
                isPowerAdapterConnected: true,
                detail: "이 Mac에서 충전 제어를 적용하지 못했습니다",
                updatedAt: 1,
                appliedLimitPercentage: nil,
                isHardwareSupported: true,
                detailReason: .init(kind: .applyFailed))
            return (try? BatteryControlCodec.encode(status), nil)
        })
        await client.apply(enabled: true, limitPercentage: 80)

        let failure = BatteryControlClient.InstallFailure.configureRejected(
            reason: client.status.detailReason, detail: client.status.detail)
        guard case .configureRejected(let reason, let detail) = failure else {
            Issue.record("expected .configureRejected")
            return
        }
        #expect(reason?.kind == .applyFailed)
        #expect(detail == "이 Mac에서 충전 제어를 적용하지 못했습니다")

        #expect(BatteryStatusText.installFailureMessage(reason: reason, detail: detail,
                                                        locale: Locale(identifier: "en"))
                == "Helper installed, but the charge limit could not be applied: Could not apply charge control on this Mac")
    }

    @MainActor @Test func installRejectsEnabledAcknowledgementWithoutActualGate() async {
        let requested = BatteryControlConfiguration(enabled: true, limitPercentage: 85)
        let incomplete = BatteryControlServiceStatus(
            mode: .charging, currentPercentage: 80, isPowerAdapterConnected: true,
            detail: "gate unavailable", updatedAt: 1, desiredConfiguration: requested,
            lastMaintenance: .init(
                trigger: .clientConfiguration, result: .applied, occurredAt: 1, reason: nil))
        let client = BatteryControlClient(requestHandler: { _ in
            (try? BatteryControlCodec.encode(incomplete), nil)
        }, installHandler: { _, _, postInstall in
            await postInstall()
            return nil
        })

        let failure = await client.installAndApply(
            enabled: true, limitPercentage: 85, window: nil)
        guard case .configureRejected = failure else {
            Issue.record("Expected configure rejection")
            return
        }
    }
}
