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
