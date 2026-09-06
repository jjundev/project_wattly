import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class HelperHealthCoordinator {
    typealias OwnershipProvider = @MainActor () -> FanHelperInstaller.InstalledOwnership
    typealias BinaryInspectionProvider = @Sendable () -> (bundledExists: Bool, installedExists: Bool, match: Bool?)
    typealias InstallRunner = @MainActor (NSWindow?, Bool, @escaping @MainActor () async -> Void) async -> Error?

    private(set) var state: HelperHealthState = .checking
    private(set) var diagnostics: HelperDiagnosticDetails = HelperDiagnosticDetails()

    private let batteryControl: BatteryControlClient
    private let fanControl: FanControlClient
    private let ownershipProvider: OwnershipProvider
    private let binaryInspectionProvider: BinaryInspectionProvider
    private let installRunner: InstallRunner

    init(
        batteryControl: BatteryControlClient,
        fanControl: FanControlClient,
        installedOwnershipProvider: OwnershipProvider? = nil,
        ownershipProvider: OwnershipProvider? = nil,
        binaryInspectionProvider: BinaryInspectionProvider? = nil,
        installRunner: InstallRunner? = nil
    ) {
        self.batteryControl = batteryControl
        self.fanControl = fanControl
        self.ownershipProvider = installedOwnershipProvider ?? ownershipProvider ?? { FanHelperInstaller.installedOwnership() }
        self.binaryInspectionProvider = binaryInspectionProvider ?? Self.defaultBinaryInspection
        self.installRunner = installRunner ?? { window, transferringOwnership, postInstall in
            await PrivilegedHelperInstallSession.run(
                window: window,
                transferringOwnership: transferringOwnership,
                postInstall: postInstall
            )
        }
    }

    @discardableResult
    func checkHealth() async -> HelperHealthState {
        state = .checking
        let currentUID = UInt32(getuid())
        let ownership = ownershipProvider()
        let binaryInfo = binaryInspectionProvider()

        // Probe both subsystems concurrently
        async let batteryStatus = batteryControl.refreshStatus()
        async let fanStatus = fanControl.refreshStatus()
        let (bStatus, fStatus) = await (batteryStatus, fanStatus)

        let batteryMode = bStatus?.mode ?? batteryControl.status.mode
        let fanMode = fStatus?.mode ?? fanControl.status.mode
        let capabilities = bStatus?.capabilities ?? batteryControl.status.capabilities

        let missing = HelperHealthStatus.requiredCapabilities.filter { cap in
            capabilities?.contains(cap) != true
        }

        let resolved = HelperHealthStatus.resolve(
            ownership: ownership,
            currentUID: currentUID,
            batteryMode: batteryMode,
            fanMode: fanMode,
            bundledBinaryExists: binaryInfo.bundledExists,
            installedBinaryExists: binaryInfo.installedExists,
            binaryMatch: binaryInfo.match,
            capabilities: capabilities
        )

        diagnostics = HelperDiagnosticDetails(
            installedOwnership: ownership,
            currentUID: currentUID,
            batteryMode: batteryMode,
            fanMode: fanMode,
            installedBinaryExists: binaryInfo.installedExists,
            bundledBinaryExists: binaryInfo.bundledExists,
            binaryMatch: binaryInfo.match,
            capabilities: capabilities,
            missingCapabilities: missing,
            checkedAt: Date()
        )
        state = resolved
        return resolved
    }

    func reinstall(
        transferringOwnership: Bool = false,
        window: NSWindow?,
        reapplySettings: @escaping @MainActor () async -> Void
    ) async throws {
        guard state != .installing else { return }
        state = .installing
        let failure = await installRunner(window, transferringOwnership) {
            await reapplySettings()
        }
        if let failure {
            await checkHealth()
            throw failure
        }
        await checkHealth()
    }

    nonisolated private static func defaultBinaryInspection() -> (bundledExists: Bool, installedExists: Bool, match: Bool?) {
        let fm = FileManager.default
        let bundledURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/WattlyFanDaemon")
        let installedURL = URL(fileURLWithPath: FanControlXPC.daemonPath)

        let bundledExists = fm.fileExists(atPath: bundledURL.path)
        let installedExists = fm.fileExists(atPath: installedURL.path)

        guard bundledExists, installedExists else {
            return (bundledExists, installedExists, nil)
        }

        // Compare file sizes first
        guard let bAttr = try? fm.attributesOfItem(atPath: bundledURL.path),
              let iAttr = try? fm.attributesOfItem(atPath: installedURL.path),
              let bSize = bAttr[.size] as? NSNumber,
              let iSize = iAttr[.size] as? NSNumber else {
            return (bundledExists, installedExists, nil)
        }

        if bSize != iSize {
            return (bundledExists, installedExists, false)
        }

        // If sizes match, compare bytes or fast hash
        if let bData = try? Data(contentsOf: bundledURL),
           let iData = try? Data(contentsOf: installedURL) {
            return (bundledExists, installedExists, bData == iData)
        }

        return (bundledExists, installedExists, nil)
    }
}
