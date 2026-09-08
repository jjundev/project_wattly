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
        let install = index(of: "install -o root -g wheel -m 755 \"$staged_daemon\"")
        let plist = index(of: "<<'WATTLY_PLIST'")
        let policyDir = index(of: "/Library/Application Support/Wattly")
        let bootstrap = script.range(of: "launchctl bootstrap system \"$installed_plist\"", options: .backwards)?.lowerBound
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
}
