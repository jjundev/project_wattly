import Foundation

/// Installs (or removes) the privileged fan-control helper using a single macOS
/// administrator-authentication prompt. The daemon binary ships inside the app bundle at
/// `Contents/Helpers/` (the "Embed Fan Helper" copy-files phase); the LaunchDaemon plist is
/// written from an embedded template with the current uid substituted. Every privileged step
/// runs as root through one `osascript … with administrator privileges` call, so the user
/// authenticates in the system's own secure dialog and the app never sees the password.
///
/// This is the in-app path that replaces `scripts/install-fan-helper.sh` for end users: when the
/// user enables fan control while the helper is missing, `SettingsView` calls `install()`.
enum FanHelperInstaller {
    static let label = "dev.jjundev.WattlyFanDaemon"

    enum InstallError: LocalizedError {
        case daemonMissing
        case scriptWriteFailed
        case authFailedOrCancelled(String)

        var errorDescription: String? {
            switch self {
            case .daemonMissing: "앱 번들에서 도우미 실행 파일을 찾을 수 없습니다."
            case .scriptWriteFailed: "설치 스크립트를 임시 폴더에 쓰지 못했습니다."
            case .authFailedOrCancelled(let detail): detail
            }
        }
    }

    /// Installs the daemon + LaunchDaemon and kickstarts it. Runs off the main actor (the auth
    /// prompt blocks). Throws on a missing bundled daemon, a temp-write failure, or a
    /// cancelled/failed authorization.
    static func install() async throws {
        let daemon = bundledDaemonURL
        guard FileManager.default.isExecutableFile(atPath: daemon.path) else {
            throw InstallError.daemonMissing
        }
        let plist = plistTemplate.replacingOccurrences(of: "__WATTLY_ALLOWED_UID__", with: "\(getuid())")
        let plistPath = FileManager.default.temporaryDirectory.appendingPathComponent("\(label).plist")
        do {
            try plist.write(to: plistPath, atomically: true, encoding: .utf8)
        } catch {
            throw InstallError.scriptWriteFailed
        }
        try await runPrivileged("""
        launchctl bootout system/\(label) 2>/dev/null || true
        install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools /Library/LaunchDaemons
        install -o root -g wheel -m 755 '\(daemon.path)' '/Library/PrivilegedHelperTools/\(label)'
        install -o root -g wheel -m 644 '\(plistPath.path)' '/Library/LaunchDaemons/\(label).plist'
        launchctl bootstrap system '/Library/LaunchDaemons/\(label).plist'
        launchctl kickstart -k system/\(label)
        """)
    }

    /// Boots out and removes the daemon + LaunchDaemon (one auth prompt).
    static func uninstall() async throws {
        try await runPrivileged("""
        launchctl bootout system/\(label) 2>/dev/null || true
        rm -f '/Library/PrivilegedHelperTools/\(label)' '/Library/LaunchDaemons/\(label).plist'
        """)
    }

    // MARK: - Internals

    /// The embedded daemon is named after the build product (`WattlyFanDaemon`), NOT the launchd
    /// label — the install destination below is what carries the `dev.jjundev.` label.
    private static var bundledDaemonURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/WattlyFanDaemon")
    }

    /// Writes `script` to a temp file and executes it as root via one `osascript` auth prompt.
    /// The AppleScript command is just `/bin/sh <path>` (no spaces in the temp path), so the
    /// multi-line script needs no AppleScript-level escaping.
    private static func runPrivileged(_ script: String) async throws {
        let scriptPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("wattly-helper-\(UUID().uuidString).sh")
        do {
            try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        } catch {
            throw InstallError.scriptWriteFailed
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                defer { try? FileManager.default.removeItem(at: scriptPath) }
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                proc.arguments = [
                    "-e",
                    "do shell script \"/bin/sh \(scriptPath.path)\" with administrator privileges",
                ]
                let errPipe = Pipe()
                proc.standardError = errPipe
                do {
                    try proc.run()
                } catch {
                    cont.resume(throwing: InstallError.authFailedOrCancelled(error.localizedDescription))
                    return
                }
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    cont.resume(returning: ())
                } else {
                    // osascript exits non-zero on a cancelled prompt (-128) or a failed script.
                    let msg = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    cont.resume(throwing: InstallError.authFailedOrCancelled(
                        msg.isEmpty ? "관리자 인증이 취소되었거나 실패했습니다." : msg))
                }
            }
        }
    }

    /// The LaunchDaemon plist, embedded so no second bundled file is needed. Mirrors
    /// `Resources/com.dev.jjundev.WattlyFanDaemon.plist`; `__WATTLY_ALLOWED_UID__` is filled in
    /// with the current uid at install time.
    private static let plistTemplate = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>Label</key><string>dev.jjundev.WattlyFanDaemon</string>
    <key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/dev.jjundev.WattlyFanDaemon</string></array>
    <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
    <key>MachServices</key><dict><key>dev.jjundev.WattlyFanDaemon</key><true/></dict>
    <key>EnvironmentVariables</key><dict><key>WATTLY_ALLOWED_UID</key><string>__WATTLY_ALLOWED_UID__</string></dict>
    </dict></plist>
    """
}
