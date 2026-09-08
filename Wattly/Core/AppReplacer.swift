import Foundation
import AppKit

/// 다운로드·검증이 끝난 새 번들을 현재 번들 자리에 놓고 다시 연다. 경로는 argv로만 넘긴다 —
/// 스크립트 본문에 보간하면 경로의 `"`·`$(`가 그대로 셸에 들어간다.
public enum AppReplacer: Sendable {
    /// 교체만. `mv` 백업 → `ditto` → 실패 시 복원. 어느 단계가 실패해도 실행 가능한 앱 하나는 남는다.
    /// quarantine 제거는 6단계(Developer ID + 공증)에서 사라진다; 지금은 `UpdateVerifier`의 서명 검증이 근거다.
    nonisolated public static let replaceScript = """
    set -eu
    current="$1"; new="$2"; pid="$3"
    while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    backup="$current.wattly-previous"
    rm -rf "$backup"
    mv "$current" "$backup"
    if ditto "$new" "$current"; then
      rm -rf "$backup"
    else
      rm -rf "$current"
      mv "$backup" "$current"
      exit 1
    fi
    xattr -dr com.apple.quarantine "$current" 2>/dev/null || true

    """

    nonisolated public static let relaunchScript = replaceScript + "open -n \"$current\"\n"

    /// `/bin/sh -c <script> <argv0> <current> <new> <pid>` — `$0`은 이름표, `$1…$3`이 경로와 pid다.
    nonisolated public static func arguments(
        script: String, currentAppURL: URL, newAppURL: URL, currentPID: Int32
    ) -> [String] {
        ["-c", script, "wattly-relaunch", currentAppURL.path, newAppURL.path, String(currentPID)]
    }

    @MainActor
    public static func replaceAndRelaunch(currentAppURL: URL = Bundle.main.bundleURL, newAppURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments(
            script: relaunchScript,
            currentAppURL: currentAppURL,
            newAppURL: newAppURL,
            currentPID: ProcessInfo.processInfo.processIdentifier)
        try process.run()
        NSApplication.shared.terminate(nil)
    }
}

