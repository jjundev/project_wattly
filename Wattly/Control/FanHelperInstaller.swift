import Foundation
import CryptoKit

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

    typealias PrivilegedRunner = @Sendable (String) async throws -> Void

    enum InstalledOwnership: Equatable, Sendable {
        case notInstalled
        case owner(UInt32)
        case invalidMetadata
    }

    enum OwnershipError: LocalizedError, Equatable {
        case ownedByDifferentUser(UInt32)
        case invalidInstalledMetadata

        var errorDescription: String? {
            switch self {
            case .ownedByDifferentUser:
                String(localized: "다른 사용자가 이 Mac의 충전 정책을 관리하고 있습니다.")
            case .invalidInstalledMetadata:
                String(localized: "설치된 도우미의 소유자 정보를 확인할 수 없습니다.")
            }
        }
    }

    enum InstallError: LocalizedError, Equatable {
        case daemonMissing
        case scriptWriteFailed
        case authFailedOrCancelled(String)
        case userCancelled

        var isCancellation: Bool {
            switch self {
            case .userCancelled:
                return true
            case .authFailedOrCancelled(let detail):
                return detail.contains("-128") || detail.localizedCaseInsensitiveContains("canceled") || detail.localizedCaseInsensitiveContains("cancelled")
            default:
                return false
            }
        }

        var errorDescription: String? {
            switch self {
            case .daemonMissing: String(localized: "앱 번들에서 도우미 실행 파일을 찾을 수 없습니다.")
            case .scriptWriteFailed: String(localized: "설치 스크립트를 임시 폴더에 쓰지 못했습니다.")
            case .userCancelled: String(localized: "관리자 인증이 취소되었거나 실패했습니다.")
            case .authFailedOrCancelled(let detail): detail
            }
        }
    }

    /// Installs the daemon + LaunchDaemon and kickstarts it. Runs off the main actor (the auth
    /// prompt blocks). Throws on a missing bundled daemon, a temp-write failure, or a
    /// cancelled/failed authorization.
    static func installedOwnership(
        plistURL: URL = URL(fileURLWithPath: "/Library/LaunchDaemons/\(label).plist")
    ) -> InstalledOwnership {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return .notInstalled }
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: Any],
              let environment = plist["EnvironmentVariables"] as? [String: String],
              let raw = environment["WATTLY_ALLOWED_UID"],
              let uid = UInt32(raw), uid > 0 else { return .invalidMetadata }
        return .owner(uid)
    }

    static func validateOwnership(
        installedOwnership: InstalledOwnership,
        currentUID: UInt32,
        transferringOwnership: Bool
    ) throws {
        switch installedOwnership {
        case .notInstalled, .owner(currentUID):
            return
        case .owner(let uid):
            guard transferringOwnership else { throw OwnershipError.ownedByDifferentUser(uid) }
        case .invalidMetadata:
            guard transferringOwnership else { throw OwnershipError.invalidInstalledMetadata }
        }
    }

    static func install(
        transferringOwnership: Bool = false,
        daemonURL: URL = bundledDaemonURL,
        installedPlistURL: URL = URL(fileURLWithPath: "/Library/LaunchDaemons/\(label).plist"),
        currentUID: UInt32 = UInt32(getuid()),
        privilegedRunner: PrivilegedRunner? = nil
    ) async throws {
        try validateOwnership(
            installedOwnership: installedOwnership(plistURL: installedPlistURL),
            currentUID: currentUID,
            transferringOwnership: transferringOwnership)
        let daemon = daemonURL
        guard FileManager.default.isExecutableFile(atPath: daemon.path) else {
            throw InstallError.daemonMissing
        }
        // 이 시점의 바이트가 root가 설치할 바이트다. 이후 번들이 바뀌면 스크립트가 76으로 거부한다.
        let expectedSHA256: String
        do {
            expectedSHA256 = try sha256Hex(ofFileAt: daemon)
        } catch {
            throw InstallError.daemonMissing
        }
        try await (privilegedRunner ?? runPrivileged)(makeInstallScript(
            daemonPath: daemon.path,
            expectedSHA256: expectedSHA256,
            currentUID: currentUID,
            transferringOwnership: transferringOwnership))
    }

    static func makeInstallScript(
        daemonPath: String,
        expectedSHA256: String,
        currentUID: UInt32 = UInt32(getuid()),
        transferringOwnership: Bool = false
    ) -> String {
        let transferAuthorization = transferringOwnership ? "true" : "false"
        let plist = plistTemplate.replacingOccurrences(of: "__WATTLY_ALLOWED_UID__", with: "\(currentUID)")
        return """
        set -eu
        daemon_src=\(shellQuoted(daemonPath))
        expected_sha256=\(shellQuoted(expectedSHA256))
        allow_ownership_transfer=\(transferAuthorization)
        expected_owner_uid=\(currentUID)
        installed_plist='/Library/LaunchDaemons/\(label).plist'
        helper_path='/Library/PrivilegedHelperTools/\(label)'
        policy_dir='/Library/Application Support/Wattly'
        staging_dir='/var/run/Wattly/staging'
        staged_daemon="$staging_dir/WattlyFanDaemon"
        ownership_lock='/var/run/Wattly/wattly-helper-install.lock'
        install -d -o root -g wheel -m 755 /var/run/Wattly
        if ! /usr/bin/shlock -f "$ownership_lock" -p "$$"; then
          echo 'Ownership replacement is already in progress.' >&2
          exit 75
        fi
        chmod 644 "$ownership_lock"
        cleanup() { rm -f "$ownership_lock"; rm -rf "$staging_dir"; }
        trap cleanup EXIT
        trap 'exit 75' HUP INT TERM
        # 번들 안의 바이너리는 사용자 소유다. root 전용 스테이징에 복사한 뒤 그 사본만 검사하고 실행한다 —
        # 인증 대화상자가 떠 있는 동안 번들이 바뀌어도 사본은 앱이 계산한 해시와 대조된다.
        rm -rf "$staging_dir"
        install -d -o root -g wheel -m 700 "$staging_dir"
        cp "$daemon_src" "$staged_daemon"
        chown root:wheel "$staged_daemon"
        chmod 755 "$staged_daemon"
        actual_sha256=$(/usr/bin/shasum -a 256 "$staged_daemon" | /usr/bin/cut -d ' ' -f 1)
        if [ "$actual_sha256" != "$expected_sha256" ]; then
          echo 'Bundled helper changed after the install started; aborting.' >&2
          exit 76
        fi
        # The app's preflight can become stale while the authentication panel is open. Re-read the
        # installed LaunchDaemon as root before the safety preflight, then again immediately before
        # bootout. Only the explicit transfer flag may authorize changed or invalid metadata.
        validate_installed_owner() {
          if [ -e "$installed_plist" ]; then
            installed_uid=$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:WATTLY_ALLOWED_UID' "$installed_plist" 2>/dev/null) || installed_uid=""
            case "$installed_uid" in
              ''|*[!0-9]*) ownership_changed=true ;;
              *)
                if [ "$installed_uid" -le 0 ] || [ "$installed_uid" -ne "$expected_owner_uid" ]; then
                  ownership_changed=true
                else
                  ownership_changed=false
                fi
                ;;
            esac
            if [ "$ownership_changed" = true ] && [ "$allow_ownership_transfer" != true ]; then
              echo 'Helper ownership changed; rerun with an explicit transfer.' >&2
              exit 65
            fi
          fi
        }
        validate_installed_owner
        "$staged_daemon" --verify-battery-release
        validate_installed_owner
        was_running=false
        if launchctl print system/\(label) >/dev/null 2>&1; then
          was_running=true
          launchctl bootout system/\(label)
        fi
        if ! "$staged_daemon" --verify-battery-release; then
          if $was_running; then
            launchctl bootstrap system "$installed_plist"
          fi
          exit 74
        fi
        install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools /Library/LaunchDaemons
        # 정책 파일 디렉터리는 데몬이 아니라 여기서, root 소유로 만든다. 심볼릭 링크나 남이 만든
        # 디렉터리가 있으면 치우고 다시 만든다 — 데몬은 root 소유가 아닌 경로를 신뢰하지 않는다(5단계).
        if [ -L "$policy_dir" ]; then rm -f "$policy_dir"; fi
        install -d -o root -g wheel -m 755 "$policy_dir"
        chown root:wheel "$policy_dir"
        chmod 755 "$policy_dir"
        install -o root -g wheel -m 755 "$staged_daemon" "$helper_path"
        umask 022
        cat > "$installed_plist" <<'WATTLY_PLIST'
        \(plist)
        WATTLY_PLIST
        chown root:wheel "$installed_plist"
        chmod 644 "$installed_plist"
        launchctl bootstrap system "$installed_plist"
        launchctl kickstart -k system/\(label)
        """
    }

    /// Boots out and removes the daemon + LaunchDaemon (one auth prompt).
    static func uninstall() async throws {
        let verifier = bundledDaemonURL
        guard FileManager.default.isExecutableFile(atPath: verifier.path) else {
            throw InstallError.daemonMissing
        }
        try await runPrivileged(makeUninstallScript(verifierPath: verifier.path))
    }

    static func makeUninstallScript(verifierPath: String) -> String {
        """
        set -eu
        '\(verifierPath)' --verify-battery-release
        was_running=false
        if launchctl print system/\(label) >/dev/null 2>&1; then
          was_running=true
          launchctl bootout system/\(label)
        fi
        if ! '\(verifierPath)' --verify-battery-release; then
          if $was_running; then
            launchctl bootstrap system '/Library/LaunchDaemons/\(label).plist'
          fi
          exit 74
        fi
        rm -f '/Library/PrivilegedHelperTools/\(label)' \\
          '/Library/LaunchDaemons/\(label).plist' \\
          '/Library/Application Support/Wattly/battery-control-v1.json'
        rmdir '/Library/Application Support/Wattly' 2>/dev/null || true
        """
    }

    // MARK: - 인용·해시 (순수)

    /// POSIX sh 단일 인용. 안에 든 `'`는 `'\''`(닫고, 이스케이프한 따옴표, 다시 열기)로 바꾼다.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript 문자열 리터럴. `do shell script`에 여러 줄 스크립트를 파일 없이 넘기기 위한 것 —
    /// 파일로 넘기면 인증 대화상자가 떠 있는 동안 같은 UID의 프로세스가 내용을 바꿔칠 수 있다.
    static func appleScriptLiteral(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
                    if msg.contains("-128") || msg.localizedCaseInsensitiveContains("canceled") || msg.localizedCaseInsensitiveContains("cancelled") {
                        cont.resume(throwing: InstallError.userCancelled)
                    } else {
                        cont.resume(throwing: InstallError.authFailedOrCancelled(
                            msg.isEmpty ? String(localized: "관리자 인증이 취소되었거나 실패했습니다.") : msg))
                    }
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
