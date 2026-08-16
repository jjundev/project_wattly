import Foundation
import AppKit

public enum AppReplacer: Sendable {
    nonisolated public static func generateRelaunchScript(currentAppURL: URL, newAppURL: URL, currentPID: Int32) -> String {
        """
        while kill -0 \(currentPID) 2>/dev/null; do
            sleep 0.2
        done
        rm -rf "\(currentAppURL.path)"
        ditto "\(newAppURL.path)" "\(currentAppURL.path)"
        xattr -dr com.apple.quarantine "\(currentAppURL.path)" 2>/dev/null || true
        open -n "\(currentAppURL.path)"
        """
    }

    @MainActor
    public static func replaceAndRelaunch(currentAppURL: URL = Bundle.main.bundleURL, newAppURL: URL) throws {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let script = generateRelaunchScript(currentAppURL: currentAppURL, newAppURL: newAppURL, currentPID: currentPID)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()

        NSApplication.shared.terminate(nil)
    }
}
