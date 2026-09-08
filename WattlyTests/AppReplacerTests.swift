import Testing
import Foundation
@testable import Wattly

@Suite struct AppReplacerTests {
    /// 경로는 argv로만 전달된다. 스크립트 본문에 경로 문자열이 섞여 들어가면 `"`·`$(`가 셸 인젝션이 된다.
    @Test func pathsTravelAsArgumentsNotAsScriptText() {
        let current = URL(fileURLWithPath: "/Applications/It's \"Wattly\" $(rm -rf ~).app")
        let newApp = URL(fileURLWithPath: "/tmp/staging dir/Wattly.app")
        let argv = AppReplacer.arguments(script: AppReplacer.relaunchScript,
                                         currentAppURL: current, newAppURL: newApp, currentPID: 4242)
        #expect(argv[0] == "-c")
        #expect(argv[1] == AppReplacer.relaunchScript)
        #expect(argv[3] == current.path)
        #expect(argv[4] == newApp.path)
        #expect(argv[5] == "4242")
        #expect(!AppReplacer.relaunchScript.contains(current.path))
        #expect(AppReplacer.relaunchScript.hasSuffix("open -n \"$current\"\n"))
    }

    /// 실제 /bin/sh로 교체 스크립트를 돌린다. 성공하면 백업이 사라지고, ditto가 실패하면 원본이 복원된다.
    @Test func replaceScriptSwapsBundleAndRollsBackOnFailure() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let current = root.appendingPathComponent("Wattly.app", isDirectory: true)
        let newApp = root.appendingPathComponent("New.app", isDirectory: true)
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        try "old".write(to: current.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: newApp, withIntermediateDirectories: true)
        try "new".write(to: newApp.appendingPathComponent("marker"), atomically: true, encoding: .utf8)

        // 이미 종료된 pid — `kill -0`이 즉시 실패해 대기 루프를 빠져나온다.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try probe.run(); probe.waitUntilExit()
        let deadPID = probe.processIdentifier

        // 성공 경로
        try Self.runSh(AppReplacer.arguments(script: AppReplacer.replaceScript,
                                             currentAppURL: current, newAppURL: newApp, currentPID: deadPID))
        #expect(try String(contentsOf: current.appendingPathComponent("marker"), encoding: .utf8) == "new")
        #expect(!fm.fileExists(atPath: current.path + ".wattly-previous"))

        // 실패 경로: 새 앱 경로가 없으면 ditto가 실패하고 원본(지금은 "new")이 그대로 남는다.
        let missing = root.appendingPathComponent("Missing.app")
        _ = try? Self.runSh(AppReplacer.arguments(script: AppReplacer.replaceScript,
                                                  currentAppURL: current, newAppURL: missing, currentPID: deadPID))
        #expect(try String(contentsOf: current.appendingPathComponent("marker"), encoding: .utf8) == "new")
        #expect(!fm.fileExists(atPath: current.path + ".wattly-previous"))
    }

    /// 경로 끝에 슬래시가 붙어 있어도(URL path or argv) 백업 디렉토리가 앱 내부가 아닌 옆에 생긴다.
    @Test func replaceScriptHandlesTrailingSlashes() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let current = root.appendingPathComponent("Wattly.app", isDirectory: true)
        let newApp = root.appendingPathComponent("New.app", isDirectory: true)
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        try "old".write(to: current.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: newApp, withIntermediateDirectories: true)
        try "new".write(to: newApp.appendingPathComponent("marker"), atomically: true, encoding: .utf8)

        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try probe.run(); probe.waitUntilExit()
        let deadPID = probe.processIdentifier

        // 끝에 슬래시가 붙은 경로로 전달
        let currentWithSlash = current.path + "/"
        let newWithSlash = newApp.path + "/"
        let args = ["-c", AppReplacer.replaceScript, "wattly-relaunch", currentWithSlash, newWithSlash, String(deadPID)]
        try Self.runSh(args)
        #expect(try String(contentsOf: current.appendingPathComponent("marker"), encoding: .utf8) == "new")
        #expect(!fm.fileExists(atPath: current.path + ".wattly-previous"))
        #expect(!fm.fileExists(atPath: current.appendingPathComponent(".wattly-previous").path))
    }

    private static func runSh(_ arguments: [String]) throws {
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = arguments
        try sh.run(); sh.waitUntilExit()
        if sh.terminationStatus != 0 { throw NSError(domain: "sh", code: Int(sh.terminationStatus)) }
    }
}

