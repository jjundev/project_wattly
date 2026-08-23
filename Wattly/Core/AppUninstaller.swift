import Foundation
import AppKit

/// Core engine for full application uninstallation ("Wattly 완전 삭제").
/// Handles cleanup of user data, preferences, caches, login items, privileged helper daemon,
/// and spawns a background shell script to delete the app bundle after termination.
enum AppUninstaller: Sendable {
    enum UninstallError: LocalizedError, Equatable {
        case helperUnavailable
        case persistenceRejected
        case releaseUnverified
        case helperRemovalFailed(String)

        var errorDescription: String? {
            switch self {
            case .helperUnavailable:
                "도우미에 연결할 수 없어 충전 허용 상태를 확인하지 못했습니다."
            case .persistenceRejected:
                "충전 제한 비활성화 설정을 저장하지 못했습니다."
            case .releaseUnverified:
                "충전 허용 상태를 확인하지 못해 Wattly 삭제를 중단했습니다."
            case .helperRemovalFailed(let detail):
                "도우미를 제거하지 못했습니다: \(detail)"
            }
        }
    }

    /// Returns the list of standard user directories and files associated with Wattly.
    static func targetCleanupPaths(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleID: String = Bundle.main.bundleIdentifier ?? "dev.jjundev.Wattly"
    ) -> [URL] {
        [
            homeDirectory.appendingPathComponent("Library/Application Support").appendingPathComponent(bundleID),
            homeDirectory.appendingPathComponent("Library/Application Support/Wattly"),
            homeDirectory.appendingPathComponent("Library/Caches").appendingPathComponent(bundleID),
            homeDirectory.appendingPathComponent("Library/Caches/Wattly"),
            homeDirectory.appendingPathComponent("Library/Preferences").appendingPathComponent("\(bundleID).plist"),
            homeDirectory.appendingPathComponent("Library/Saved Application State").appendingPathComponent("\(bundleID).savedState"),
            homeDirectory.appendingPathComponent("Library/HTTPStorages").appendingPathComponent(bundleID)
        ]
    }

    /// Generates the shell script executed in the background to wait for app exit and delete bundle + files.
    static func generateUninstallScript(
        currentAppURL: URL,
        currentPID: Int32,
        pathsToDelete: [URL]
    ) -> String {
        var lines = [
            "while kill -0 \(currentPID) 2>/dev/null; do",
            "    sleep 0.2",
            "done",
            "rm -rf \"\(currentAppURL.path)\""
        ]
        for path in pathsToDelete {
            lines.append("rm -rf \"\(path.path)\"")
        }
        return lines.joined(separator: "\n")
    }

    /// Cleans in-app data, unregisters login items, releases the battery charge limit, removes helper daemon if present, and deletes user library files.
    @MainActor
    static func cleanUserData(
        userDefaults: UserDefaults = .standard,
        loginItem: LoginItemControlling = LoginItem(),
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleID: String = Bundle.main.bundleIdentifier ?? "dev.jjundev.Wattly",
        releaseBatteryLimit: @MainActor () async throws -> Void = {
            let client = BatteryControlClient()
            switch await client.prepareForRemoval(window: NSApp.keyWindow) {
            case nil:
                return
            case .helperUnavailable?:
                throw UninstallError.helperUnavailable
            case .persistenceRejected?:
                throw UninstallError.persistenceRejected
            case .releaseUnverified?:
                throw UninstallError.releaseUnverified
            }
        },
        /// Injected because the default checks real `/Library` paths and, when the helper is
        /// installed, shells out through `osascript … with administrator privileges` — a test
        /// that let the default run would block the suite on a credential dialog on any machine
        /// with the helper installed.
        removeHelper: @MainActor () async throws -> Void = {
            let daemonPath = "/Library/PrivilegedHelperTools/\(FanHelperInstaller.label)"
            let plistPath = "/Library/LaunchDaemons/\(FanHelperInstaller.label).plist"
            if FileManager.default.fileExists(atPath: daemonPath) || FileManager.default.fileExists(atPath: plistPath) {
                do {
                    try await FanHelperInstaller.uninstall()
                } catch {
                    throw UninstallError.helperRemovalFailed(error.localizedDescription)
                }
            }
        }
    ) async throws {
        // 1. Unregister login item
        try? loginItem.setEnabled(false)

        // 2. Hand the battery back before the helper goes away. `bootout` below SIGTERMs the
        // daemon, which releases on its own — but a helper that was SIGKILLed earlier would leave
        // the SMC charge-inhibit latched with nothing left on disk to ever clear it.
        try await releaseBatteryLimit()

        // 3. Remove privileged helper daemon if installed
        try await removeHelper()

        // 4. Clear user defaults
        userDefaults.removePersistentDomain(forName: bundleID)
        userDefaults.synchronize()

        // 5. Delete user files in Library
        let cleanupPaths = targetCleanupPaths(homeDirectory: homeDirectory, bundleID: bundleID)
        for path in cleanupPaths {
            try? fileManager.removeItem(at: path)
        }
    }

    /// Executes full cleanup, launches the self-delete background script, and terminates the application.
    @MainActor
    static func uninstall(
        currentAppURL: URL = Bundle.main.bundleURL,
        userDefaults: UserDefaults = .standard,
        loginItem: LoginItemControlling = LoginItem(),
        fileManager: FileManager = .default
    ) async throws {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let cleanupPaths = targetCleanupPaths()

        try await cleanUserData(
            userDefaults: userDefaults,
            loginItem: loginItem,
            fileManager: fileManager
        )

        let script = generateUninstallScript(
            currentAppURL: currentAppURL,
            currentPID: currentPID,
            pathsToDelete: cleanupPaths
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()

        NSApplication.shared.terminate(nil)
    }
}
