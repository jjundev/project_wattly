import Foundation
import AppKit

/// Core engine for full application uninstallation ("Wattly 완전 삭제").
/// Handles cleanup of user data, preferences, caches, login items, privileged helper daemon,
/// and spawns a background shell script to delete the app bundle after termination.
enum AppUninstaller: Sendable {
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
        releaseBatteryLimit: @MainActor () async -> Void = {
            await BatteryControlClient().apply(enabled: false, limitPercentage: 100)
        }
    ) async {
        // 1. Unregister login item
        try? loginItem.setEnabled(false)

        // 2. Hand the battery back before the helper goes away. `bootout` below SIGTERMs the
        // daemon, which releases on its own — but a helper that was SIGKILLed earlier would leave
        // the SMC charge-inhibit latched with nothing left on disk to ever clear it.
        await releaseBatteryLimit()

        // 3. Remove privileged helper daemon if installed
        let daemonPath = "/Library/PrivilegedHelperTools/\(FanHelperInstaller.label)"
        let plistPath = "/Library/LaunchDaemons/\(FanHelperInstaller.label).plist"
        if fileManager.fileExists(atPath: daemonPath) || fileManager.fileExists(atPath: plistPath) {
            try? await FanHelperInstaller.uninstall()
        }

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

        await cleanUserData(
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
