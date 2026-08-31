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

    @Test func changedInstalledOwnerAfterPreflightIsRejectedInsideReplacementTransaction() throws {
        // The app-level preflight can become stale before administrator authorization completes.
        try FanHelperInstaller.validateOwnership(
            installedOwnership: .owner(501), currentUID: 501, transferringOwnership: false)

        let script = FanHelperInstaller.makeInstallScript(
            daemonPath: "/tmp/WattlyFanDaemon",
            plistPath: "/tmp/Wattly.plist",
            currentUID: 501,
            transferringOwnership: false)
        let elevatedRecheck = try #require(script.range(of: "installed_uid=$("))
        let rejectChangedOwner = try #require(script.range(of: "Helper ownership changed; rerun with an explicit transfer."))
        let bootout = try #require(script.range(of: "launchctl bootout system/\(FanHelperInstaller.label)"))

        #expect(elevatedRecheck.lowerBound < bootout.lowerBound)
        #expect(rejectChangedOwner.lowerBound < bootout.lowerBound)
        #expect(script.contains("allow_ownership_transfer=false"))
        #expect(script.contains("[ \"$installed_uid\" -ne \"$expected_owner_uid\" ]"))
        #expect(script.contains("validate_installed_owner\n'/tmp/WattlyFanDaemon' --verify-battery-release"))
        #expect(script.contains("'/tmp/WattlyFanDaemon' --verify-battery-release\nvalidate_installed_owner\nwas_running=false"))
    }

    @Test func replacementTransactionLocksOwnershipAfterTheFinalValidation() throws {
        // A second installer can otherwise replace the plist between the last owner check and
        // bootout. The lock must begin before the final check and remain through kickstart.
        let script = FanHelperInstaller.makeInstallScript(
            daemonPath: "/tmp/WattlyFanDaemon", plistPath: "/tmp/Wattly.plist", currentUID: 501)
        let acquire = try #require(script.range(of: "/usr/bin/shlock -f \"$ownership_lock\" -p \"$$\""))
        let finalCheck = try #require(script.range(of: "validate_installed_owner\n'/tmp/WattlyFanDaemon' --verify-battery-release"))
        let bootout = try #require(script.range(of: "launchctl bootout system/\(FanHelperInstaller.label)"))
        let kickstart = try #require(script.range(of: "launchctl kickstart -k system/\(FanHelperInstaller.label)"))
        let releaseTrap = try #require(script.range(of: "trap cleanup_ownership_lock EXIT"))

        #expect(acquire.lowerBound < finalCheck.lowerBound)
        #expect(finalCheck.lowerBound < bootout.lowerBound)
        #expect(bootout.lowerBound < kickstart.lowerBound)
        #expect(releaseTrap.lowerBound < finalCheck.lowerBound)
        #expect(script.contains("Ownership replacement is already in progress."))
    }

    @Test func elevatedReplacementAcceptsChangedOwnerOnlyWithExplicitTransfer() {
        let script = FanHelperInstaller.makeInstallScript(
            daemonPath: "/tmp/WattlyFanDaemon",
            plistPath: "/tmp/Wattly.plist",
            currentUID: 501,
            transferringOwnership: true)

        #expect(script.contains("allow_ownership_transfer=true"))
        #expect(script.contains("[ \"$allow_ownership_transfer\" != true ]"))
    }

    @Test func uninstallScriptVerifiesReleaseBeforeRemovingTheHelper() {
        let script = FanHelperInstaller.makeUninstallScript(verifierPath: "/tmp/WattlyFanDaemon")
        let preflight = try! #require(script.range(of: "'/tmp/WattlyFanDaemon' --verify-battery-release"))
        let bootout = try! #require(script.range(of: "launchctl bootout system/\(FanHelperInstaller.label)"))
        let postflight = try! #require(script.range(of: "if ! '/tmp/WattlyFanDaemon' --verify-battery-release"))
        let removal = try! #require(script.range(of: "rm -f '/Library/PrivilegedHelperTools/\(FanHelperInstaller.label)'"))

        #expect(script.contains("set -eu"))
        #expect(preflight.lowerBound < bootout.lowerBound)
        #expect(bootout.lowerBound < postflight.lowerBound)
        #expect(postflight.lowerBound < removal.lowerBound)
        #expect(script.contains("launchctl bootstrap system '/Library/LaunchDaemons/\(FanHelperInstaller.label).plist'"))
    }

    @MainActor @Test func legacyHelperIsPreparedForVerifiedRemoval() async throws {
        let legacy = BatteryControlServiceStatus(
            mode: .charging, currentPercentage: 70, isPowerAdapterConnected: true,
            detail: "legacy", updatedAt: 1)
        let released = BatteryControlServiceStatus(
            mode: .charging, currentPercentage: 70, isPowerAdapterConnected: true,
            detail: "released", updatedAt: 2,
            desiredConfiguration: .init(enabled: false, limitPercentage: 100),
            actualGate: .unreadable, releaseVerdict: .notControllable,
            releaseVerification: .init(
                verdict: .notControllable,
                proof: .noDrivableRegisterAtRuntime),
            lastMaintenance: .init(
                trigger: .clientConfiguration, result: .released,
                occurredAt: 2, reason: nil))
        let recorder = RequestRecorder()
        let client = BatteryControlClient(requestHandler: { request in
            await recorder.record(request)
            switch request {
            case .status:
                return (try? BatteryControlCodec.encode(legacy), nil)
            case .configure:
                return (try? BatteryControlCodec.encode(released), nil)
            }
        }, installHandler: { _, transferringOwnership, postInstall in
            #expect(transferringOwnership == false)
            await postInstall()
            return nil
        })

        #expect(await client.prepareForRemoval(window: nil) == nil)
        // 두 번째 "status"는 installAndApply 내부의 apply(...) 호출이 만든 것이다.
        // apply의 캘리브레이션 가드는 쓰기 전에 데몬을 한 번 읽는다 — desiredConfiguration이
        // 비어 있는 건 "확인 안 됨"이지 "캘리브레이션 없음"이 아니기 때문이다. 레거시
        // 도우미는 애초에 desiredConfiguration을 절대 채우지 않으므로(persisted-policy 이전
        // 버전) 이 읽기는 여기서 그냥 공짜 왕복 하나일 뿐 — revive 분기는 절대 타지 않는다.
        #expect(await recorder.kinds == ["status", "status", "configure", "configure"])
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

    // MARK: - Fix 3: 재설치가 진행 중인 캘리브레이션을 거짓 실패로 보고하지 않는다

    @MainActor @Test func installAndApplySucceedsWhenTheDaemonIsCalibrating() async {
        // 재설치 도중에도 데몬은 이미 캘리브레이션을 들고 있다. `apply(...)`의 되살리기
        // 규칙(캘리브레이션 chokepoint)이 topUpActive/calibrationActive/enabled를 데몬 값으로
        // 되살려서 내보내는데, 수락 확인이 그 되살린 모양이 아니라 raw 인자로 지은 설정과
        // 비교하면 실제로는 두 절반(설치·설정 push) 모두 성공했는데도 `.configureRejected`로
        // 보고된다.
        let calibrating = BatteryControlServiceStatus(
            mode: .charging, currentPercentage: 65, isPowerAdapterConnected: true,
            detail: "calibration active", updatedAt: 1,
            desiredConfiguration: .init(
                enabled: true,
                limitPercentage: 85,
                topUpActive: true,
                calibrationActive: true,
                calibrationTargetPercentage: 20),
            actualGate: .allowed,
            lastMaintenance: .init(
                trigger: .clientConfiguration, result: .applied, occurredAt: 1, reason: nil))
        let client = BatteryControlClient(requestHandler: { _ in
            (try? BatteryControlCodec.encode(calibrating), nil)
        }, installHandler: { _, _, postInstall in
            await postInstall()
            return nil
        })

        let failure = await client.installAndApply(
            enabled: true,
            limitPercentage: 85,
            lowerHysteresisDelta: 2,
            heatProtectionEnabled: false,
            heatProtectionThresholdCelsius: 35,
            autoDischargeEnabled: false,
            manualDischargeActive: false,
            manualDischargeTarget: 80,
            window: nil)

        #expect(failure == nil)
    }

    @MainActor @Test func clientSendsHeatProtectionParametersToDaemon() async throws {
        let receiver = RequestReceiver()
        let client = BatteryControlClient(requestHandler: { request in
            await receiver.set(request)
            let status = BatteryControlServiceStatus(mode: .charging, currentPercentage: 80, isPowerAdapterConnected: true, detail: "OK", updatedAt: Date().timeIntervalSince1970)
            let data = try? BatteryControlCodec.encode(status)
            return (data, nil)
        })

        await client.apply(
            enabled: false,
            limitPercentage: 80,
            lowerHysteresisDelta: 2,
            heatProtectionEnabled: true,
            heatProtectionThresholdCelsius: 38
        )
        let receivedRequest = await receiver.request
        if case .configure(let data) = receivedRequest {
            let req = try BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
            #expect(req.configuration.enabled == false)
            #expect(req.configuration.heatProtectionEnabled == true)
            #expect(req.configuration.heatProtectionThresholdCelsius == 38)
        } else {
            Issue.record("Expected configure request")
        }
    }

    @MainActor @Test func clientApplyUsesDefaultThreshold35() async {
        let receiver = RequestReceiver()
        let client = BatteryControlClient(requestHandler: { request in
            await receiver.set(request)
            let status = BatteryControlServiceStatus(
                mode: .charging, currentPercentage: 50, isPowerAdapterConnected: true,
                detail: "ok", updatedAt: 100
            )
            return (try? BatteryControlCodec.encode(status), nil)
        })
        await client.apply(enabled: true, limitPercentage: 80, lowerHysteresisDelta: 5, heatProtectionEnabled: true)
        let recordedRequest = await receiver.request
        if case .configure(let data) = recordedRequest,
           let decoded = try? BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data) {
            #expect(decoded.configuration.heatProtectionThresholdCelsius == 35)
        } else {
            Issue.record("Expected configure request with decoded config")
        }
    }

    @MainActor @Test func startTopUpAppliesTopUpActiveTrue() async {
        let receiver = RequestReceiver()
        let client = BatteryControlClient(requestHandler: { req in
            await receiver.set(req)
            if case .configure = req {
                let status = BatteryControlServiceStatus(
                    mode: .charging,
                    currentPercentage: 70,
                    isPowerAdapterConnected: true,
                    detail: "Top Up 중 (100%까지 충전)",
                    updatedAt: 1.0,
                    activity: .topUp
                )
                let replyData = try? BatteryControlCodec.encode(status)
                return (replyData, nil)
            }
            return (nil, nil)
        })

        await client.startTopUp(
            limitPercentage: 80,
            lowerHysteresisDelta: 2,
            heatProtectionEnabled: false,
            heatProtectionThresholdCelsius: 35
        )

        let receivedRequest = await receiver.request
        var recordedRequest: BatteryControlConfigurationRequest?
        if case .configure(let data) = receivedRequest {
            recordedRequest = try? BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
        }
        #expect(recordedRequest?.configuration.topUpActive == true)
        #expect(recordedRequest?.configuration.limitPercentage == 80)
    }

    @MainActor @Test func cancelTopUpAppliesTopUpActiveFalse() async {
        let receiver = RequestReceiver()
        let client = BatteryControlClient(requestHandler: { req in
            await receiver.set(req)
            if case .configure = req {
                let status = BatteryControlServiceStatus(
                    mode: .inhibited,
                    currentPercentage: 85,
                    isPowerAdapterConnected: true,
                    detail: "충전 제한 80% 도달",
                    updatedAt: 1.0,
                    activity: .holdingAtLimit
                )
                let replyData = try? BatteryControlCodec.encode(status)
                return (replyData, nil)
            }
            return (nil, nil)
        })

        await client.cancelTopUp(
            limitPercentage: 80,
            lowerHysteresisDelta: 2,
            heatProtectionEnabled: false,
            heatProtectionThresholdCelsius: 35
        )

        let receivedRequest = await receiver.request
        var recordedRequest: BatteryControlConfigurationRequest?
        if case .configure(let data) = receivedRequest {
            recordedRequest = try? BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
        }
        #expect(recordedRequest?.configuration.topUpActive == false)
        #expect(recordedRequest?.configuration.limitPercentage == 80)
    }

    @MainActor @Test func startManualDischargeAppliesManualDischargeActiveTrueAndTarget() async {
        let receiver = RequestReceiver()
        let client = BatteryControlClient(requestHandler: { req in
            await receiver.set(req)
            if case .configure = req {
                let status = BatteryControlServiceStatus(
                    mode: .charging,
                    currentPercentage: 85,
                    isPowerAdapterConnected: true,
                    detail: "수동 방전 중 (70%까지 방전)",
                    updatedAt: 1.0,
                    activity: .discharging,
                    desiredConfiguration: .init(manualDischargeActive: true, manualDischargeTarget: 70)
                )
                let replyData = try? BatteryControlCodec.encode(status)
                return (replyData, nil)
            }
            return (nil, nil)
        })

        let status = await client.startManualDischarge(target: 70)
        #expect(status?.desiredConfiguration?.manualDischargeTarget == 70)
        #expect(status?.desiredConfiguration?.manualDischargeActive == true)

        let receivedRequest = await receiver.request
        var recordedRequest: BatteryControlConfigurationRequest?
        if case .configure(let data) = receivedRequest {
            recordedRequest = try? BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
        }
        #expect(recordedRequest?.configuration.manualDischargeActive == true)
        #expect(recordedRequest?.configuration.manualDischargeTarget == 70)
        #expect(recordedRequest?.configuration.topUpActive == false)
        #expect(recordedRequest?.configuration.enabled == true)
    }

    /// The funnel test: `apply` is the sole builder of the outgoing `.configure` payload, and every
    /// other public entry point (`applyCalibration`, `startTopUp`, `startManualDischarge`,
    /// `setAutoDischarge`, `disableAndConfirm`, `reconcile`, `installAndApply`, the four
    /// `BatteryIntentBridge` paths, `BatteryScheduleCoordinator`) forwards its `manualDischargeTarget`
    /// through it. A stored 100 can never satisfy `currentSoC > target`, permanently disabling the
    /// discharge button — the clamp has to land here so no caller can bypass it, not just the four
    /// view files that already clamp for display.
    @MainActor @Test func applyClampsOutOfRangeManualDischargeTargetBeforeSend() async {
        let receiver = RequestReceiver()
        let client = BatteryControlClient(requestHandler: { req in
            await receiver.set(req)
            if case .configure = req {
                let status = BatteryControlServiceStatus(
                    mode: .charging,
                    currentPercentage: 85,
                    isPowerAdapterConnected: true,
                    detail: "OK",
                    updatedAt: 1.0
                )
                let replyData = try? BatteryControlCodec.encode(status)
                return (replyData, nil)
            }
            return (nil, nil)
        })

        await client.apply(enabled: true, limitPercentage: 80, manualDischargeTarget: 100)

        let receivedRequest = await receiver.request
        var recordedRequest: BatteryControlConfigurationRequest?
        if case .configure(let data) = receivedRequest {
            recordedRequest = try? BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
        } else {
            Issue.record("Expected configure request")
        }
        // BatterySectionPresentation.dischargeTargetRange caps at 95, so the out-of-range stored
        // value of 100 must reach the daemon clamped — never raw.
        #expect(recordedRequest?.configuration.manualDischargeTarget == 95)
    }

    /// Counterpart to the clamp test above: an already in-range target must pass through untouched,
    /// proving this isn't a blanket override that always forces 95.
    @MainActor @Test func applyLeavesInRangeManualDischargeTargetUntouched() async {
        let receiver = RequestReceiver()
        let client = BatteryControlClient(requestHandler: { req in
            await receiver.set(req)
            if case .configure = req {
                let status = BatteryControlServiceStatus(
                    mode: .charging,
                    currentPercentage: 85,
                    isPowerAdapterConnected: true,
                    detail: "OK",
                    updatedAt: 1.0
                )
                let replyData = try? BatteryControlCodec.encode(status)
                return (replyData, nil)
            }
            return (nil, nil)
        })

        await client.apply(enabled: true, limitPercentage: 80, manualDischargeTarget: 70)

        let receivedRequest = await receiver.request
        var recordedRequest: BatteryControlConfigurationRequest?
        if case .configure(let data) = receivedRequest {
            recordedRequest = try? BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
        } else {
            Issue.record("Expected configure request")
        }
        #expect(recordedRequest?.configuration.manualDischargeTarget == 70)
    }

    @MainActor @Test func stopManualDischargeAppliesManualDischargeActiveFalse() async {
        let receiver = RequestReceiver()
        let client = BatteryControlClient(requestHandler: { req in
            await receiver.set(req)
            if case .configure = req {
                let status = BatteryControlServiceStatus(
                    mode: .inhibited,
                    currentPercentage: 70,
                    isPowerAdapterConnected: true,
                    detail: "충전 제한 80% 도달",
                    updatedAt: 1.0,
                    activity: .holdingAtLimit,
                    desiredConfiguration: .init(manualDischargeActive: false, manualDischargeTarget: 80)
                )
                let replyData = try? BatteryControlCodec.encode(status)
                return (replyData, nil)
            }
            return (nil, nil)
        })

        await client.stopManualDischarge(limitPercentage: 80)

        let receivedRequest = await receiver.request
        var recordedRequest: BatteryControlConfigurationRequest?
        if case .configure(let data) = receivedRequest {
            recordedRequest = try? BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
        }
        #expect(recordedRequest?.configuration.manualDischargeActive == false)
        #expect(recordedRequest?.configuration.topUpActive == false)
    }

    @MainActor @Test func setAutoDischargeAppliesAutoDischargeEnabled() async {
        let receiver = RequestReceiver()
        let client = BatteryControlClient(requestHandler: { req in
            await receiver.set(req)
            if case .configure = req {
                let status = BatteryControlServiceStatus(
                    mode: .inhibited,
                    currentPercentage: 80,
                    isPowerAdapterConnected: true,
                    detail: "충전 제한 80% 도달",
                    updatedAt: 1.0
                )
                let replyData = try? BatteryControlCodec.encode(status)
                return (replyData, nil)
            }
            return (nil, nil)
        })

        await client.setAutoDischarge(enabled: false, limitPercentage: 80)
        var receivedRequest = await receiver.request
        if case .configure(let data) = receivedRequest {
            let recorded = try? BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
            #expect(recorded?.configuration.autoDischargeEnabled == false)
        } else {
            Issue.record("Expected configure request")
        }

        await client.setAutoDischarge(enabled: true, limitPercentage: 80)
        receivedRequest = await receiver.request
        if case .configure(let data) = receivedRequest {
            let recorded = try? BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
            #expect(recorded?.configuration.autoDischargeEnabled == true)
        } else {
            Issue.record("Expected configure request")
        }
    }

    @MainActor @Test func startTopUpClearsManualDischargeActive() async {
        let receiver = RequestReceiver()
        let client = BatteryControlClient(requestHandler: { req in
            await receiver.set(req)
            if case .configure = req {
                let status = BatteryControlServiceStatus(
                    mode: .charging,
                    currentPercentage: 70,
                    isPowerAdapterConnected: true,
                    detail: "한 번만 완충 중",
                    updatedAt: 1.0,
                    activity: .topUp
                )
                let replyData = try? BatteryControlCodec.encode(status)
                return (replyData, nil)
            }
            return (nil, nil)
        })

        await client.startTopUp(limitPercentage: 80)
        let receivedRequest = await receiver.request
        if case .configure(let data) = receivedRequest {
            let recorded = try? BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
            #expect(recorded?.configuration.topUpActive == true)
            #expect(recorded?.configuration.manualDischargeActive == false)
        } else {
            Issue.record("Expected configure request")
        }
    }

    @MainActor @Test func reconcileWhenLimitDisabledButManualDischargeActiveMaintainsEnabledTrue() async {
        let receiver = RequestReceiver()
        let activeDischargeStatus = BatteryControlServiceStatus(
            mode: .charging,
            currentPercentage: 85,
            isPowerAdapterConnected: true,
            detail: "수동 방전 중",
            updatedAt: 1.0,
            activity: .discharging,
            desiredConfiguration: .init(
                enabled: true,
                limitPercentage: 80,
                autoDischargeEnabled: false,
                manualDischargeActive: true,
                manualDischargeTarget: 70
            )
        )
        let client = BatteryControlClient(requestHandler: { req in
            await receiver.set(req)
            if case .status = req {
                let replyData = try? BatteryControlCodec.encode(activeDischargeStatus)
                return (replyData, nil)
            }
            if case .configure = req {
                let replyData = try? BatteryControlCodec.encode(activeDischargeStatus)
                return (replyData, nil)
            }
            return (nil, nil)
        })

        // Reconcile with limit disabled (enabled: false)
        await client.reconcile(
            enabled: false,
            limitPercentage: 80,
            manualDischargeActive: true,
            manualDischargeTarget: 70
        )
        // Since status already has same desiredConfiguration, shouldReapply is false, no redundant write
        #expect(client.status.desiredConfiguration?.manualDischargeActive == true)
    }

    @MainActor @Test func anOrdinaryApplyCannotCancelARunningCalibration() async throws {
        let daemon = BatteryControlConfiguration(
            enabled: true, limitPercentage: 80, topUpActive: true,
            calibrationActive: true, calibrationTargetPercentage: 20)
        let running = BatteryControlServiceStatus(
            mode: .inhibited, currentPercentage: 100, isPowerAdapterConnected: true,
            detail: "", updatedAt: 1, desiredConfiguration: daemon)
        let recorder = ScriptRecorder()
        let client = BatteryControlClient { request in
            if case .configure(let data) = request,
               let decoded = try? BatteryControlCodec.decode(
                   BatteryControlConfigurationRequest.self, from: data) {
                await recorder.record(
                    "\(decoded.configuration.calibrationActive)-\(decoded.configuration.topUpActive)")
            }
            return (try? BatteryControlCodec.encode(running), nil)
        }
        await client.refreshStatus()

        // 설정창이 한도만 바꾸려고 부른 평범한 write.
        _ = await client.apply(enabled: true, limitPercentage: 85)
        #expect(await recorder.value == "true-true")
    }

    /// 위 두 가드 테스트는 모두 `await client.refreshStatus()`를 먼저 호출해 캐시를 채워
    /// 둔다 — 그게 바로 깨진 경로가 만족시키지 못하는 전제다. Shortcuts/App Intents
    /// (`BatteryIntentBridge`)는 호출마다 새 `BatteryControlClient`를 만들고, 쓰기 전에
    /// status를 읽지 않는다. 여기서는 그 모양을 그대로 재현한다: `refreshStatus()`를
    /// 단 한 번도 부르지 않은 신선한 클라이언트가 평범한 `apply(enabled:limitPercentage:)`를
    /// 받는다. 데몬이 캘리브레이션 중이라고 답하더라도, 데몬에 실제로 나간 설정에는
    /// calibrationActive/topUpActive가 살아 있어야 한다.
    @MainActor @Test func anApplyFromAClientThatHasNeverReadStatusStillPreservesARunningCalibration() async throws {
        let daemon = BatteryControlConfiguration(
            enabled: true, limitPercentage: 80, topUpActive: true,
            calibrationActive: true, calibrationTargetPercentage: 20)
        let running = BatteryControlServiceStatus(
            mode: .inhibited, currentPercentage: 100, isPowerAdapterConnected: true,
            detail: "", updatedAt: 1, desiredConfiguration: daemon)
        let recorder = ScriptRecorder()
        let client = BatteryControlClient { request in
            if case .configure(let data) = request,
               let decoded = try? BatteryControlCodec.decode(
                   BatteryControlConfigurationRequest.self, from: data) {
                await recorder.record(
                    "\(decoded.configuration.calibrationActive)-\(decoded.configuration.topUpActive)")
            }
            return (try? BatteryControlCodec.encode(running), nil)
        }
        // 의도적으로 refreshStatus()를 부르지 않는다 — 신선한 client.status는 기본값(nil
        // desiredConfiguration)이다.

        // Shortcuts가 보낼 법한 평범한 write.
        _ = await client.apply(enabled: true, limitPercentage: 85)
        #expect(await recorder.value == "true-true")
    }

    @MainActor @Test func theCoordinatorsOwnWriteCanTurnCalibrationOff() async throws {
        let daemon = BatteryControlConfiguration(
            enabled: true, limitPercentage: 80, calibrationActive: true)
        let running = BatteryControlServiceStatus(
            mode: .inhibited, currentPercentage: 20, isPowerAdapterConnected: true,
            detail: "", updatedAt: 1, desiredConfiguration: daemon)
        let recorder = ScriptRecorder()
        let client = BatteryControlClient { request in
            if case .configure(let data) = request,
               let decoded = try? BatteryControlCodec.decode(
                   BatteryControlConfigurationRequest.self, from: data) {
                await recorder.record("\(decoded.configuration.calibrationActive)")
            }
            return (try? BatteryControlCodec.encode(running), nil)
        }
        await client.refreshStatus()

        _ = await client.applyCalibration(
            primitive: .restore,
            snapshot: CalibrationSnapshot(
                limitEnabled: true, limitPercentage: 80,
                sailingEnabled: false, sailingDelta: 5,
                heatProtectionEnabled: true, heatProtectionThresholdCelsius: 35,
                autoDischargeEnabled: true, manualDischargeTarget: 80))
        #expect(await recorder.value == "false")
    }

    @MainActor @Test func calibrationPrimitivesMapToDaemonCommands() async throws {
        let recorder = ScriptRecorder()
        let idle = BatteryControlServiceStatus(
            mode: .charging, currentPercentage: 50, isPowerAdapterConnected: true,
            detail: "", updatedAt: 1)
        let client = BatteryControlClient { request in
            if case .configure(let data) = request,
               let decoded = try? BatteryControlCodec.decode(
                   BatteryControlConfigurationRequest.self, from: data) {
                let c = decoded.configuration
                await recorder.record(
                    "cal=\(c.calibrationActive) top=\(c.topUpActive) auto=\(c.autoDischargeEnabled) target=\(c.calibrationTargetPercentage)")
            }
            return (try? BatteryControlCodec.encode(idle), nil)
        }
        let snapshot = CalibrationSnapshot(
            limitEnabled: true, limitPercentage: 80,
            sailingEnabled: false, sailingDelta: 5,
            heatProtectionEnabled: true, heatProtectionThresholdCelsius: 35,
            autoDischargeEnabled: true, manualDischargeTarget: 80)

        _ = await client.applyCalibration(primitive: .chargeToFull, snapshot: snapshot)
        #expect(await recorder.value == "cal=true top=true auto=false target=20")

        _ = await client.applyCalibration(primitive: .dischargeToFloor, snapshot: snapshot)
        #expect(await recorder.value == "cal=true top=false auto=false target=20")

        _ = await client.applyCalibration(primitive: .holdAtFull, snapshot: snapshot)
        #expect(await recorder.value == "cal=true top=true auto=false target=20")

        // holdAtFloor는 방전 쪽 단계다 — isChargingStep이 false라 topUpActive가 켜지면
        // 바닥에서 정착 중인 절차가 100%까지 충전하는 걸로 뒤집힌다.
        _ = await client.applyCalibration(primitive: .holdAtFloor, snapshot: snapshot)
        #expect(await recorder.value == "cal=true top=false auto=false target=20")

        // 원복은 스냅샷의 자동 방전 원값을 되살린다.
        _ = await client.applyCalibration(primitive: .restore, snapshot: snapshot)
        #expect(await recorder.value == "cal=false top=false auto=true target=20")

        // idle은 절차가 아예 꺼진 상태 — restore와 마찬가지로 스냅샷의 실제 선호값을 되살린다.
        _ = await client.applyCalibration(primitive: .idle, snapshot: snapshot)
        #expect(await recorder.value == "cal=false top=false auto=true target=20")
    }
}

