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
        // 정책 디렉터리는 데몬이 아니라 설치 스크립트가 root:wheel 0755로 만든다(5단계 Task 4의 전제).
        let policyDirCreate = index(of: "install -d -o root -g wheel -m 755 \"$policy_dir\"")
        let install = index(of: "install -o root -g wheel -m 755 \"$staged_daemon\"")
        let plist = index(of: "<<'WATTLY_PLIST'")
        // kickstart는 스크립트에 한 번만 나오므로 .backwards 없이 끝을 고정할 수 있다.
        let kickstart = index(of: "launchctl kickstart -k system/dev.jjundev.WattlyFanDaemon")
        #expect(stage != nil && hash != nil && firstVerify != nil && policyDirCreate != nil && install != nil && plist != nil && kickstart != nil)
        #expect(stage! < hash! && hash! < firstVerify! && firstVerify! < policyDirCreate!
                && policyDirCreate! < install! && install! < plist! && plist! < kickstart!)
        // 마지막 bootstrap도 plist 히어독 뒤다. 같은 문자열이 롤백에도 있으므로 .backwards 대신
        // 뒤따르는 kickstart까지 붙여 유일한 바늘로 만든다.
        let finalBootstrap = index(of: """
        launchctl bootstrap system "$installed_plist"
        launchctl kickstart -k system/dev.jjundev.WattlyFanDaemon
        """)
        #expect(finalBootstrap != nil && plist! < finalBootstrap!)
        // 심볼릭 링크가 심어져 있으면 치우고 만든다.
        #expect(script.contains("if [ -L \"$policy_dir\" ]; then rm -f \"$policy_dir\"; fi"))
        #expect(script.contains("policy_dir='/Library/Application Support/Wattly'"))

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

    @Test func uninstallScriptPrefersTheInstalledRootOwnedHelperAsVerifier() {
        let script = FanHelperInstaller.makeUninstallScript(fallbackVerifierPath: "/Apps/It's.app/Contents/Helpers/WattlyFanDaemon")
        #expect(script.contains("verifier='/Library/PrivilegedHelperTools/dev.jjundev.WattlyFanDaemon'"))
        #expect(script.contains("fallback_verifier='/Apps/It'\\''s.app/Contents/Helpers/WattlyFanDaemon'"))
        #expect(script.contains("if [ ! -x \"$verifier\" ]; then verifier=\"$fallback_verifier\"; fi"))
        #expect(!script.contains("'/Apps/It's"))
        #expect(script.contains("rm -f '/Library/PrivilegedHelperTools/dev.jjundev.WattlyFanDaemon'"))
    }

    /// 두 스크립트 모두 `set -eu` 직후에 PATH를 시스템 경로로 고정한다 — `do shell script`가
    /// 호출자의 환경을 물려받아도 bare 명령이 오염된 PATH에서 해석되지 않도록.
    @Test func bothScriptsPinPathImmediatelyAfterSetEU() {
        let pinned = "set -eu\n"
        let assignment = "PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH\n"
        for script in [
            FanHelperInstaller.makeInstallScript(
                daemonPath: "/x/WattlyFanDaemon",
                expectedSHA256: String(repeating: "ab", count: 32),
                currentUID: 501),
            FanHelperInstaller.makeUninstallScript(fallbackVerifierPath: "/x/WattlyFanDaemon")
        ] {
            #expect(script.hasPrefix(pinned))
            let path = script.range(of: assignment)
            #expect(path != nil)
            // PATH 고정 앞에는 주석 말고 실행되는 줄이 없어야 한다.
            let preamble = script[script.startIndex..<(path?.lowerBound ?? script.startIndex)]
            for line in preamble.split(separator: "\n", omittingEmptySubsequences: false) {
                #expect(line.isEmpty || line == "set -eu" || line.hasPrefix("#"))
            }
        }
    }

    /// FIFO나 심볼릭 링크가 번들 경로에 심어져 있으면 cp 전에 끊는다. FIFO면 cp가 락을 쥔 채 영구히 멈춘다.
    @Test func installScriptRefusesNonRegularBundledHelperBeforeCopying() {
        let script = FanHelperInstaller.makeInstallScript(
            daemonPath: "/x/WattlyFanDaemon",
            expectedSHA256: String(repeating: "ab", count: 32),
            currentUID: 501)
        let guardIndex = script.range(of: "if [ ! -f \"$daemon_src\" ] || [ -L \"$daemon_src\" ]; then")?.lowerBound
        let copyIndex = script.range(of: "cp \"$daemon_src\" \"$staged_daemon\"")?.lowerBound
        #expect(guardIndex != nil && copyIndex != nil)
        #expect(guardIndex! < copyIndex!)
        #expect(script.contains("Bundled helper is not a regular file; aborting."))
    }

    /// 롤백(이전 데몬 재기동) 실패가 `set -e`로 의도한 74를 덮어쓰지 않는다.
    @Test func rollbackBootstrapFailureDoesNotMaskExit74() {
        let install = FanHelperInstaller.makeInstallScript(
            daemonPath: "/x/WattlyFanDaemon",
            expectedSHA256: String(repeating: "ab", count: 32),
            currentUID: 501)
        #expect(install.contains("launchctl bootstrap system \"$installed_plist\" || true"))
        let uninstall = FanHelperInstaller.makeUninstallScript(fallbackVerifierPath: "/x/WattlyFanDaemon")
        #expect(uninstall.contains(
            "launchctl bootstrap system '/Library/LaunchDaemons/dev.jjundev.WattlyFanDaemon.plist' || true"))
    }

    /// 텍스트 단언만으로는 못 잡는 것들(들여쓴 히어독 종결자, 문법 오류)을 막는다.
    /// `/bin/sh -n`은 파싱만 하고 아무것도 실행하지 않는다.
    @Test func bothGeneratedScriptsParseUnderBinSh() throws {
        let scripts = [
            "install": FanHelperInstaller.makeInstallScript(
                daemonPath: "/Applications/It's Wattly.app/Contents/Helpers/WattlyFanDaemon",
                expectedSHA256: String(repeating: "ab", count: 32),
                currentUID: 501,
                transferringOwnership: true),
            "uninstall": FanHelperInstaller.makeUninstallScript(
                fallbackVerifierPath: "/Apps/It's.app/Contents/Helpers/WattlyFanDaemon")
        ]
        for (name, script) in scripts {
            let sh = Process()
            sh.executableURL = URL(fileURLWithPath: "/bin/sh")
            sh.arguments = ["-n"]          // 문법 검사만. 실행하지 않는다.
            let stdin = Pipe(), stderr = Pipe()
            sh.standardInput = stdin
            sh.standardError = stderr
            sh.standardOutput = Pipe()
            try sh.run()
            stdin.fileHandleForWriting.write(Data(script.utf8))
            try stdin.fileHandleForWriting.close()
            let errText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            sh.waitUntilExit()
            #expect(sh.terminationStatus == 0, "\(name) 스크립트가 /bin/sh -n을 통과하지 못했다: \(errText)")
            #expect(errText.isEmpty, "\(name) 스크립트가 stderr를 남겼다: \(errText)")
        }
    }

    /// 번들에서 도우미가 빠진 앱으로도 설치된 root 데몬을 지울 수 있어야 한다.
    @Test func uninstallProceedsWhenOnlyTheInstalledHelperIsPresent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missingBundle = root.appendingPathComponent("Contents/Helpers/WattlyFanDaemon")
        let installed = root.appendingPathComponent("dev.jjundev.WattlyFanDaemon")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: installed)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.path)

        let captured = ScriptBox()
        try await FanHelperInstaller.uninstall(
            bundledVerifierURL: missingBundle,
            installedHelperURL: installed,
            privilegedRunner: { await captured.store($0) })
        let script = await captured.value
        #expect(script?.contains("verifier='/Library/PrivilegedHelperTools/dev.jjundev.WattlyFanDaemon'") == true)
        #expect(script?.contains("fallback_verifier='\(missingBundle.path)'") == true)
    }

    @Test func uninstallStillRefusesWhenNeitherVerifierExists() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let captured = ScriptBox()
        await #expect(throws: FanHelperInstaller.InstallError.daemonMissing) {
            try await FanHelperInstaller.uninstall(
                bundledVerifierURL: root.appendingPathComponent("bundle"),
                installedHelperURL: root.appendingPathComponent("installed"),
                privilegedRunner: { await captured.store($0) })
        }
        let stored = await captured.value
        #expect(stored == nil)
    }
}

private actor ScriptBox {
    private(set) var value: String?
    func store(_ script: String) { value = script }
}
