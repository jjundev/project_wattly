# 도우미 설치 스크립트 강화 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** root로 실행되는 설치 스크립트가 사용자 쓰기 가능 경로의 파일(스크립트 파일, 임시 plist, 번들 안 데몬)을 **인증 대화상자가 떠 있는 동안** 다시 읽지 않게 만들고, 앱 경로의 `'`로 인한 셸 인젝션을 없앤다.

**Architecture:** 스크립트 본문은 임시 파일 대신 `osascript -e` 인자 안의 AppleScript 문자열 리터럴로 전달한다(순수 `appleScriptLiteral`). plist는 스크립트 안 heredoc으로 root가 직접 `/Library/LaunchDaemons`에 쓴다. 데몬 바이너리는 root 소유 스테이징 디렉터리(`/var/run/Wattly/staging`, 0700)로 먼저 복사한 뒤, 앱이 `install()` 호출 시점에 계산한 SHA-256과 대조하고 나서야 실행·설치한다. 경로는 순수 `shellQuoted`로 인용한다. 정책 디렉터리 `/Library/Application Support/Wattly`도 같은 스크립트에서 root:wheel 755로 만든다.

**Tech Stack:** Swift 6, CryptoKit(SHA256), `/usr/bin/osascript`, POSIX sh, `/usr/bin/shasum`, Swift Testing.

**Spec:** 감사 보고서 §1 High("root 설치 스크립트가 사용자 쓰기 가능 경로의 바이너리·plist·스크립트를 실행한다"), Medium("설치 스크립트에 앱 경로가 작은따옴표 보간으로 들어간다"), Low("정책 디렉터리를 데몬이 lazy 생성") — https://claude.ai/code/artifact/20a3c5b7-ad33-4ec3-ae78-288a0259454d

## Global Constraints

- 남는 한계를 문서에 명시한다: 사용자가 설치 버튼을 누르기 **전에** 번들 안 데몬이 바뀐 경우는 해시가 바뀐 바이너리를 기준으로 계산되므로 막지 못한다. 그 창은 6단계(Developer ID + `codesign --verify`)만 닫는다.
- CLI 스크립트 `scripts/install-fan-helper.sh`는 이미 위치 인자·root 트랜잭션 방식이라 이 계획의 대상이 아니다. 단, Task 3의 정책 디렉터리 생성 줄은 CLI에도 같이 넣는다.
- 기존 테스트 `WattlyTests/BatteryControlClientTests.swift:206-290`이 `makeInstallScript(daemonPath:plistPath:…)`를 호출한다. 시그니처가 바뀌므로 Task 3에서 함께 갱신한다.
- Swift 6 strict concurrency, macOS 14.0.

---

## 파일 구조

| 파일 | 책임 |
|------|------|
| `Wattly/Control/FanHelperInstaller.swift` (수정) | `shellQuoted`, `appleScriptLiteral`, `sha256Hex(ofFileAt:)` 순수 함수 추가; `makeInstallScript` 재작성(스테이징+해시+heredoc plist+정책 디렉터리); `makeUninstallScript` 인용 수정; `install()`은 임시 plist를 쓰지 않음; `runPrivileged`는 임시 스크립트 파일을 쓰지 않음. |
| `WattlyTests/FanHelperInstallerScriptTests.swift` (신규) | 순수 함수 3개 + 스크립트 순서 검증. |
| `WattlyTests/BatteryControlClientTests.swift:206-290` (수정) | 새 시그니처로 호출. |
| `scripts/install-fan-helper.sh` (수정) | 정책 디렉터리 root 생성 1줄. |
| `docs/fan-control-local-install.md` (수정) | 남는 한계 명시. |

---

### Task 1: 순수 인용·해시 헬퍼

**Files:**
- Modify: `Wattly/Control/FanHelperInstaller.swift` (enum 안에 static 함수 3개 추가)
- Create: `WattlyTests/FanHelperInstallerScriptTests.swift`

**Interfaces:**
- Produces:
  - `static func shellQuoted(_ value: String) -> String` — POSIX sh 단일 인용. `'` → `'\''`.
  - `static func appleScriptLiteral(_ value: String) -> String` — `\` → `\\`, `"` → `\"`, 개행 → `\n`, 양끝 `"`.
  - `static func sha256Hex(ofFileAt url: URL) throws -> String` — 64자 소문자 hex.

- [ ] **Step 1: 실패하는 테스트**

```swift
// WattlyTests/FanHelperInstallerScriptTests.swift
import Testing
import Foundation
@testable import Wattly

@Suite struct FanHelperInstallerScriptTests {
    @Test func shellQuotingSurvivesSingleQuotesAndDollars() throws {
        let path = "/Users/me/it's \"stuff\"/$(rm -rf ~)/Wattly.app"
        let quoted = FanHelperInstaller.shellQuoted(path)
        #expect(quoted == "'/Users/me/it'\\''s \"stuff\"/$(rm -rf ~)/Wattly.app'")

        // /bin/sh가 실제로 같은 문자열로 되돌리는지 확인한다.
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "printf '%s' \(quoted)"]
        let pipe = Pipe(); sh.standardOutput = pipe
        try sh.run(); sh.waitUntilExit()
        #expect(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == path)
    }

    @Test func appleScriptLiteralRoundTripsThroughOsascript() throws {
        let script = "set -eu\necho \"a\\b\" 'c'\nexit 0\n"
        let literal = FanHelperInstaller.appleScriptLiteral(script)
        #expect(literal.hasPrefix("\"") && literal.hasSuffix("\""))
        #expect(!literal.contains("\n"))

        let osa = Process()
        osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osa.arguments = ["-e", "return \(literal)"]
        let pipe = Pipe(); osa.standardOutput = pipe
        try osa.run(); osa.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // osascript는 결과 끝에 개행을 하나 붙인다.
        #expect(out == script.replacingOccurrences(of: "\n", with: "\r") + "\n" || out == script + "\n")
    }

    @Test func sha256HexMatchesShasum() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("wattly".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let hex = try FanHelperInstaller.sha256Hex(ofFileAt: url)
        #expect(hex.count == 64)

        let shasum = Process()
        shasum.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        shasum.arguments = ["-a", "256", url.path]
        let pipe = Pipe(); shasum.standardOutput = pipe
        try shasum.run(); shasum.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(out.hasPrefix(hex))
    }
}
```

- [ ] **Step 2: 실패 확인** — Run: `… -only-testing:WattlyTests/FanHelperInstallerScriptTests` — Expected: 컴파일 실패.

- [ ] **Step 3: 구현** — `FanHelperInstaller` enum 안, `// MARK: - Internals` 위에 추가 (`import CryptoKit` 파일 상단에 추가):

```swift
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
```

- [ ] **Step 4: 통과 확인** — Expected: 3개 PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Control/FanHelperInstaller.swift WattlyTests/FanHelperInstallerScriptTests.swift
git commit -m "feat(helper): add shell/AppleScript quoting and SHA-256 helpers for the installer"
```

---

### Task 2: 설치 스크립트 재작성 — 스테이징 + 해시 + heredoc plist + 정책 디렉터리

**Files:**
- Modify: `Wattly/Control/FanHelperInstaller.swift:92-189` (`install`, `makeInstallScript`)
- Modify: `WattlyTests/BatteryControlClientTests.swift:206-290`
- Test: `WattlyTests/FanHelperInstallerScriptTests.swift` (테스트 2개 추가)

**Interfaces:**
- Produces: `static func makeInstallScript(daemonPath: String, expectedSHA256: String, currentUID: UInt32 = UInt32(getuid()), transferringOwnership: Bool = false) -> String` (`plistPath` 인자 **삭제**).
- `install(...)`은 `plistPath`를 더 이상 만들지 않는다. `InstallError.scriptWriteFailed`는 남겨 둔다(`runPrivileged`가 Task 4에서 바뀌면 사용처가 없어지므로 그때 삭제).

- [ ] **Step 1: 실패하는 테스트** — `FanHelperInstallerScriptTests`에 추가:

```swift
    @Test func installScriptStagesHashesThenVerifiesBeforeInstalling() {
        let script = FanHelperInstaller.makeInstallScript(
            daemonPath: "/Applications/It's Wattly.app/Contents/Helpers/WattlyFanDaemon",
            expectedSHA256: String(repeating: "ab", count: 32),
            currentUID: 501,
            transferringOwnership: false)

        // 경로는 인용된 형태로만 등장한다.
        #expect(script.contains("daemon_src='/Applications/It'\\''s Wattly.app/Contents/Helpers/WattlyFanDaemon'"))
        #expect(!script.contains("'/Applications/It's"))

        func index(of needle: String) -> String.Index? { script.range(of: needle)?.lowerBound }
        let stage = index(of: "cp \"$daemon_src\" \"$staged_daemon\"")
        let hash = index(of: "shasum -a 256 \"$staged_daemon\"")
        let firstVerify = index(of: "\"$staged_daemon\" --verify-battery-release")
        let install = index(of: "install -o root -g wheel -m 755 \"$staged_daemon\"")
        let plist = index(of: "<<'WATTLY_PLIST'")
        let policyDir = index(of: "/Library/Application Support/Wattly")
        let bootstrap = index(of: "launchctl bootstrap system \"$installed_plist\"")
        #expect(stage != nil && hash != nil && firstVerify != nil && install != nil && plist != nil && policyDir != nil && bootstrap != nil)
        #expect(stage! < hash! && hash! < firstVerify! && firstVerify! < install! && install! < plist! && plist! < bootstrap!)

        // 번들 경로의 바이너리는 복사 이후 다시는 실행되지 않는다.
        #expect(!script.contains("\"$daemon_src\" --verify"))
        // plist에는 uid가 들어가고 스테이징 파일 경로가 아닌 최종 설치 경로가 적힌다.
        #expect(script.contains("<string>501</string>"))
        #expect(script.contains("<string>/Library/PrivilegedHelperTools/dev.jjundev.WattlyFanDaemon</string>"))
        #expect(script.contains("staging_dir='/var/run/Wattly/staging'"))
        #expect(script.contains("expected_sha256='\(String(repeating: "ab", count: 32))'"))
    }

    @Test func installScriptRejectsHashMismatchBeforeRunningAnything() {
        let script = FanHelperInstaller.makeInstallScript(
            daemonPath: "/x/WattlyFanDaemon", expectedSHA256: "00", currentUID: 501)
        let mismatch = script.range(of: "exit 76")!.lowerBound
        let verify = script.range(of: "--verify-battery-release")!.lowerBound
        #expect(mismatch < verify)
    }
```

- [ ] **Step 2: 실패 확인** — Expected: 컴파일 실패(인자 라벨 불일치).

- [ ] **Step 3: `makeInstallScript` 재작성**

```swift
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
```

> heredoc 안의 plist는 Swift 다중행 문자열 들여쓰기 규칙 때문에 `plist` 변수의 각 줄 앞 공백이 그대로 들어간다. plist 파서는 선행 공백을 무시하므로 문제없지만, 테스트의 `<string>501</string>` 검색은 공백과 무관하다.

- [ ] **Step 4: `install()`에서 임시 plist 제거, 해시 계산 추가**

`install(...)`의 본문을 다음으로 교체 (시그니처의 `installedPlistURL`, `privilegedRunner` 인자는 유지):

```swift
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
```

- [ ] **Step 5: 기존 테스트 호출부 갱신** — `WattlyTests/BatteryControlClientTests.swift`에서 `makeInstallScript(` 호출 3곳(228-280행 근처)의 `plistPath: "…"` 인자를 삭제하고 `expectedSHA256: String(repeating: "a", count: 64)`로 바꾼다:

```bash
grep -n "plistPath:" WattlyTests/BatteryControlClientTests.swift
```

각 줄을 `expectedSHA256: String(repeating: "a", count: 64),`로 교체. `injectedRunnerReceivesTheCompleteInstallScript`(206행)가 `'\(daemonPath)'` 형태를 단정한다면 `daemon_src='…'`로 고친다. 그 테스트가 `plist.write` 결과 파일을 단정한다면 그 단정은 삭제한다(더 이상 임시 plist가 없다).

- [ ] **Step 6: 통과 확인** — Run: `… -only-testing:WattlyTests/FanHelperInstallerScriptTests` 와 `… -only-testing:WattlyTests/BatteryControlClientTests` — Expected: 전부 PASS.

- [ ] **Step 7: Commit**

```bash
git add Wattly/Control/FanHelperInstaller.swift WattlyTests/FanHelperInstallerScriptTests.swift WattlyTests/BatteryControlClientTests.swift
git commit -m "fix(helper): stage the daemon under root and verify its hash before running it as root"
```

---

### Task 3: 제거 스크립트 — 설치된 도우미로 검증, 인용 수정

**Files:**
- Modify: `Wattly/Control/FanHelperInstaller.swift` (`uninstall`, `makeUninstallScript`)
- Modify: `scripts/install-fan-helper.sh` (정책 디렉터리 1줄)
- Test: `WattlyTests/FanHelperInstallerScriptTests.swift`

**Interfaces:**
- Produces: `static func makeUninstallScript(fallbackVerifierPath: String) -> String` — 설치된 `/Library/PrivilegedHelperTools/<label>`가 있으면 그것으로 검증하고, 없을 때만 번들 사본(인용됨)을 쓴다.

- [ ] **Step 1: 실패하는 테스트**

```swift
    @Test func uninstallScriptPrefersTheInstalledRootOwnedHelperAsVerifier() {
        let script = FanHelperInstaller.makeUninstallScript(fallbackVerifierPath: "/Apps/It's.app/Contents/Helpers/WattlyFanDaemon")
        #expect(script.contains("verifier='/Library/PrivilegedHelperTools/dev.jjundev.WattlyFanDaemon'"))
        #expect(script.contains("fallback_verifier='/Apps/It'\\''s.app/Contents/Helpers/WattlyFanDaemon'"))
        #expect(script.contains("if [ ! -x \"$verifier\" ]; then verifier=\"$fallback_verifier\"; fi"))
        #expect(!script.contains("'/Apps/It's"))
        #expect(script.contains("rm -f '/Library/PrivilegedHelperTools/dev.jjundev.WattlyFanDaemon'"))
    }
```

기존 `uninstallScriptVerifiesReleaseBeforeRemovingTheHelper`(BatteryControlClientTests:279)는 `makeUninstallScript(verifierPath:)`를 부른다 → `fallbackVerifierPath:`로 라벨만 바꾼다.

- [ ] **Step 2: 실패 확인** — Expected: 컴파일 실패.

- [ ] **Step 3: 구현**

```swift
    static func uninstall() async throws {
        let verifier = bundledDaemonURL
        guard FileManager.default.isExecutableFile(atPath: verifier.path) else {
            throw InstallError.daemonMissing
        }
        try await runPrivileged(makeUninstallScript(fallbackVerifierPath: verifier.path))
    }

    /// 검증기는 root 소유의 설치본을 우선한다. 번들 사본은 설치본이 없을 때(설치가 반쯤 지워진 경우)만 쓴다.
    static func makeUninstallScript(fallbackVerifierPath: String) -> String {
        """
        set -eu
        verifier='/Library/PrivilegedHelperTools/\(label)'
        fallback_verifier=\(shellQuoted(fallbackVerifierPath))
        if [ ! -x "$verifier" ]; then verifier="$fallback_verifier"; fi
        "$verifier" --verify-battery-release
        was_running=false
        if launchctl print system/\(label) >/dev/null 2>&1; then
          was_running=true
          launchctl bootout system/\(label)
        fi
        if ! "$verifier" --verify-battery-release; then
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
```

- [ ] **Step 4: CLI 스크립트에 정책 디렉터리 생성 추가** — `scripts/install-fan-helper.sh`의 `install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools /Library/LaunchDaemons` 바로 아래에:

```sh
install -d -o root -g wheel -m 755 '/Library/Application Support/Wattly'
```

- [ ] **Step 5: 통과 확인** — Run: 두 스위트 — Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Wattly/Control/FanHelperInstaller.swift WattlyTests/FanHelperInstallerScriptTests.swift WattlyTests/BatteryControlClientTests.swift scripts/install-fan-helper.sh
git commit -m "fix(helper): verify removal with the root-owned helper and quote the fallback path"
```

---

### Task 4: `runPrivileged` — 임시 스크립트 파일 제거

**Files:**
- Modify: `Wattly/Control/FanHelperInstaller.swift:229-276` (`runPrivileged`), `InstallError.scriptWriteFailed` 삭제 및 `errorDescription`/`isCancellation` 정리

- [ ] **Step 1: 구현**

```swift
    /// 스크립트 전체를 AppleScript 문자열로 넘긴다. 파일이 없으므로 인증 대기 중 바꿔칠 대상이 없다.
    /// `do shell script`는 문자열을 `/bin/sh -c`로 실행한다.
    private static func runPrivileged(_ script: String) async throws {
        let command = "do shell script \(appleScriptLiteral(script)) with administrator privileges"
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                proc.arguments = ["-e", command]
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
```

`InstallError`에서 `case scriptWriteFailed`와 그 `errorDescription` 분기를 삭제한다. `HelperHealthCoordinatorTests.installErrorCancellationDetection`(122행)이 `.scriptWriteFailed`를 참조하면 그 단정 한 줄을 지운다.

- [ ] **Step 2: 빌드 + 관련 스위트**

Run: `… -only-testing:WattlyTests/HelperHealthCoordinatorTests`, `… -only-testing:WattlyTests/BatteryControlClientTests`
Expected: PASS.

- [ ] **Step 3: 실기 확인(1회)** — 설정 › 배터리에서 도우미 재설치를 눌러 인증 → 설치 → `launchctl print system/dev.jjundev.WattlyFanDaemon`이 성공하는지 확인. `/var/run/Wattly/staging`이 종료 후 남지 않는지 확인. `ls -la "/Library/Application Support/Wattly"`가 `root wheel drwxr-xr-x`인지 확인.

- [ ] **Step 4: Commit**

```bash
git add Wattly/Control/FanHelperInstaller.swift WattlyTests/HelperHealthCoordinatorTests.swift
git commit -m "fix(helper): pass the privileged script inline instead of through a user-writable temp file"
```

---

### Task 5: 남는 한계 문서화

**Files:**
- Modify: `docs/fan-control-local-install.md` ("Authorization limitation" 절 아래)

- [ ] **Step 1: 절 추가**

```markdown
### Install-time integrity (what the in-app installer does and does not close)

The privileged script copies the bundled daemon to a root-owned staging directory, compares its
SHA-256 against the value the app computed when the user pressed Install, and only then runs or
installs it. The script itself and the LaunchDaemon plist are passed inline, never through files in
`$TMPDIR`. This closes the window between "user authenticates" and "root executes".

It does NOT close the window before the user presses Install: a same-user process that replaces
`Contents/Helpers/WattlyFanDaemon` earlier will have its hash computed and installed. Only a real
code-signing identity (`codesign --verify` against a Developer ID requirement) closes that — see
plan 06.
```

- [ ] **Step 2: Commit**

```bash
git add docs/fan-control-local-install.md
git commit -m "docs(helper): state what install-time hashing does and does not protect"
```

---

## Self-Review

- **Spec coverage:** High(TOCTOU: 스크립트 파일 → Task 4, plist → Task 2 heredoc, 바이너리 → Task 2 스테이징+해시) ✔. Medium(작은따옴표) → Task 1·2·3 `shellQuoted` ✔. Low(정책 디렉터리) → Task 2·3 ✔. 남는 창 → Task 5 문서 ✔.
- **Placeholder scan:** 없음. `expectedSHA256` 테스트 값은 형식만 맞춘 더미이며 스크립트 문자열 검증에 쓰인다.
- **Type consistency:** `makeInstallScript(daemonPath:expectedSHA256:currentUID:transferringOwnership:)` Task 2 정의·Task 2 Step 4 호출·테스트 동일. `makeUninstallScript(fallbackVerifierPath:)` Task 3 정의·호출·테스트 동일 ✔.
