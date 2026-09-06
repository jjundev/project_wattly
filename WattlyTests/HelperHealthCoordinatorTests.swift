import Testing
import Foundation
@testable import Wattly

@Suite("HelperHealthCoordinatorTests")
struct HelperHealthCoordinatorTests {
    @Test @MainActor func checkHealthUpdatesStateAndDiagnostics() async {
        let batteryClient = BatteryControlClient(requestHandler: { _ in
            let status = BatteryControlServiceStatus(
                mode: .charging,
                currentPercentage: 80,
                isPowerAdapterConnected: true,
                detail: "정상",
                updatedAt: Date().timeIntervalSince1970,
                capabilities: HelperHealthStatus.requiredCapabilities
            )
            let data = try? BatteryControlCodec.encode(status)
            return (data, nil)
        })
        let fanClient = FanControlClient(requestHandler: { _ in
            .success(FanControlServiceStatus(
                mode: .controlling,
                detail: "정상",
                updatedAt: Date().timeIntervalSince1970
            ))
        })

        let coordinator = HelperHealthCoordinator(
            batteryControl: batteryClient,
            fanControl: fanClient,
            installedOwnershipProvider: { .owner(UInt32(getuid())) },
            binaryInspectionProvider: { (bundledExists: true, installedExists: true, match: true) },
            installRunner: { _, _, _ in nil }
        )

        let resolved = await coordinator.checkHealth()
        #expect(resolved == .running)
        #expect(coordinator.state == .running)
        #expect(coordinator.diagnostics.installedBinaryExists == true)
        #expect(coordinator.diagnostics.batteryMode == .charging)
        #expect(coordinator.diagnostics.fanMode == .controlling)
    }

    @Test @MainActor func reinstallCallsRunnerAndReappliesSettings() async {
        var didReapply = false
        var didRunInstall = false

        let coordinator = HelperHealthCoordinator(
            batteryControl: BatteryControlClient(requestHandler: { _ in (nil, nil) }),
            fanControl: FanControlClient(requestHandler: { _ in .failure(.init(detail: "err")) }),
            installedOwnershipProvider: { .owner(UInt32(getuid())) },
            binaryInspectionProvider: { (true, true, true) },
            installRunner: { _, transferring, postInstall in
                didRunInstall = true
                await postInstall()
                return nil
            }
        )

        try? await coordinator.reinstall(transferringOwnership: false, window: nil) {
            didReapply = true
        }

        #expect(didRunInstall == true)
        #expect(didReapply == true)
    }

    @Test @MainActor func reinstallPropagatesFailureAndRefreshesHealth() async {
        struct MockError: LocalizedError {
            var errorDescription: String? { "Authorization failed" }
        }
        var healthCheckCount = 0
        let coordinator = HelperHealthCoordinator(
            batteryControl: BatteryControlClient(requestHandler: { _ in (nil, nil) }),
            fanControl: FanControlClient(requestHandler: { _ in .failure(.init(detail: "err")) }),
            installedOwnershipProvider: {
                healthCheckCount += 1
                return .notInstalled
            },
            binaryInspectionProvider: { (true, false, nil) },
            installRunner: { _, _, _ in MockError() }
        )

        do {
            try await coordinator.reinstall(transferringOwnership: false, window: nil) {}
            #expect(Bool(false), "Expected reinstall to throw")
        } catch {
            #expect(error.localizedDescription == "Authorization failed")
        }

        #expect(healthCheckCount > 0)
        #expect(coordinator.state == .notInstalled)
    }

    @Test @MainActor func reinstallIgnoresConcurrentCallsWhenAlreadyInstalling() async {
        var runCount = 0
        let coordinator = HelperHealthCoordinator(
            batteryControl: BatteryControlClient(requestHandler: { _ in (nil, nil) }),
            fanControl: FanControlClient(requestHandler: { _ in .failure(.init(detail: "err")) }),
            installedOwnershipProvider: { .notInstalled },
            binaryInspectionProvider: { (true, false, nil) },
            installRunner: { _, _, _ in
                runCount += 1
                try? await Task.sleep(for: .milliseconds(50))
                return nil
            }
        )

        // Launch first reinstall
        async let first: Void = coordinator.reinstall(transferringOwnership: false, window: nil) {}
        // Allow state to switch to .installing
        try? await Task.sleep(for: .milliseconds(10))
        #expect(coordinator.state == .installing)

        // Second reinstall while .installing should be ignored by the guard
        try? await coordinator.reinstall(transferringOwnership: false, window: nil) {}

        _ = try? await first
        #expect(runCount == 1)
    }

    @Test func installErrorCancellationDetection() {
        let directCancel = FanHelperInstaller.InstallError.userCancelled
        #expect(directCancel.isCancellation == true)

        let appleScriptCancel = FanHelperInstaller.InstallError.authFailedOrCancelled("0:17: execution error: 사용자가 취소함. (-128)")
        #expect(appleScriptCancel.isCancellation == true)

        let englishCancel = FanHelperInstaller.InstallError.authFailedOrCancelled("execution error: User canceled. (-128)")
        #expect(englishCancel.isCancellation == true)

        let realError = FanHelperInstaller.InstallError.authFailedOrCancelled("Helper ownership changed; rerun with an explicit transfer.")
        #expect(realError.isCancellation == false)

        let missing = FanHelperInstaller.InstallError.daemonMissing
        #expect(missing.isCancellation == false)
    }
}
