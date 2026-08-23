import Testing
import Foundation
@testable import Wattly

@Suite struct AppUninstallerTests {
    final class MockLoginItem: LoginItemControlling, @unchecked Sendable {
        var isEnabled: Bool = true
        var disabledCallCount = 0

        func setEnabled(_ enabled: Bool) throws {
            isEnabled = enabled
            if !enabled {
                disabledCallCount += 1
            }
        }
    }

    final class ReleaseSpy: @unchecked Sendable {
        var callCount = 0
    }

    final class RemoveHelperSpy: @unchecked Sendable {
        var callCount = 0
    }

    actor EventRecorder {
        private(set) var values: [String] = []

        func record(_ value: String) {
            values.append(value)
        }
    }

    @Test func testTargetCleanupPathsIncludeExpectedLocations() {
        let home = URL(fileURLWithPath: "/Users/testuser")
        let bundleID = "dev.jjundev.Wattly"
        let paths = AppUninstaller.targetCleanupPaths(homeDirectory: home, bundleID: bundleID)
        let pathStrings = paths.map(\.path)

        #expect(pathStrings.contains("/Users/testuser/Library/Application Support/dev.jjundev.Wattly"))
        #expect(pathStrings.contains("/Users/testuser/Library/Application Support/Wattly"))
        #expect(pathStrings.contains("/Users/testuser/Library/Caches/dev.jjundev.Wattly"))
        #expect(pathStrings.contains("/Users/testuser/Library/Caches/Wattly"))
        #expect(pathStrings.contains("/Users/testuser/Library/Preferences/dev.jjundev.Wattly.plist"))
        #expect(pathStrings.contains("/Users/testuser/Library/Saved Application State/dev.jjundev.Wattly.savedState"))
        #expect(pathStrings.contains("/Users/testuser/Library/HTTPStorages/dev.jjundev.Wattly"))
    }

    @Test func testGenerateUninstallScriptContainsKillLoopAndPaths() {
        let appURL = URL(fileURLWithPath: "/Applications/Wattly.app")
        let cleanupPaths = [
            URL(fileURLWithPath: "/Users/testuser/Library/Preferences/dev.jjundev.Wattly.plist"),
            URL(fileURLWithPath: "/Users/testuser/Library/Caches/dev.jjundev.Wattly")
        ]
        let script = AppUninstaller.generateUninstallScript(currentAppURL: appURL, currentPID: 54321, pathsToDelete: cleanupPaths)

        #expect(script.contains("while kill -0 54321"))
        #expect(script.contains("rm -rf \"/Applications/Wattly.app\""))
        #expect(script.contains("rm -rf \"/Users/testuser/Library/Preferences/dev.jjundev.Wattly.plist\""))
        #expect(script.contains("rm -rf \"/Users/testuser/Library/Caches/dev.jjundev.Wattly\""))
    }

    @Test @MainActor func testCleanUserDataDisablesLoginItemAndWipesDefaults() async throws {
        let mockLogin = MockLoginItem()
        let suiteName = "test.uninstall.suite.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        testDefaults.set("customValue", forKey: "someTestKey")
        #expect(testDefaults.string(forKey: "someTestKey") == "customValue")

        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        try await AppUninstaller.cleanUserData(
            userDefaults: testDefaults,
            loginItem: mockLogin,
            fileManager: .default,
            homeDirectory: tempHome,
            bundleID: suiteName,
            releaseBatteryLimit: { },
            removeHelper: { }
        )

        #expect(mockLogin.isEnabled == false)
        #expect(mockLogin.disabledCallCount == 1)
        #expect(testDefaults.string(forKey: "someTestKey") == nil)
    }

    @Test @MainActor func testCleanUserDataReleasesTheChargeLimit() async throws {
        let mockLogin = MockLoginItem()
        let spy = ReleaseSpy()
        let suiteName = "test.uninstall.battery.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        try await AppUninstaller.cleanUserData(
            userDefaults: testDefaults,
            loginItem: mockLogin,
            fileManager: .default,
            homeDirectory: tempHome,
            bundleID: suiteName,
            releaseBatteryLimit: { spy.callCount += 1 },
            removeHelper: { }
        )

        #expect(spy.callCount == 1)
        #expect(mockLogin.disabledCallCount == 1)
    }

    @Test @MainActor func testCleanUserDataInvokesRemoveHelper() async throws {
        let mockLogin = MockLoginItem()
        let spy = RemoveHelperSpy()
        let suiteName = "test.uninstall.helper.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        // Proves the injection point itself is reached — this must never fall through to the
        // default, which would touch the real /Library paths and the real helper.
        try await AppUninstaller.cleanUserData(
            userDefaults: testDefaults,
            loginItem: mockLogin,
            fileManager: .default,
            homeDirectory: tempHome,
            bundleID: suiteName,
            releaseBatteryLimit: { },
            removeHelper: { spy.callCount += 1 }
        )

        #expect(spy.callCount == 1)
    }

    @Test @MainActor func releaseFailureStopsBeforeHelperOrUserDataRemoval() async {
        let events = EventRecorder()
        let suiteName = "test.uninstall.blocked.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: "stillHere")

        await #expect(throws: AppUninstaller.UninstallError.releaseUnverified) {
            try await AppUninstaller.cleanUserData(
                userDefaults: defaults,
                loginItem: MockLoginItem(),
                homeDirectory: FileManager.default.temporaryDirectory,
                bundleID: suiteName,
                releaseBatteryLimit: {
                    await events.record("release")
                    throw AppUninstaller.UninstallError.releaseUnverified
                },
                removeHelper: {
                    await events.record("remove")
                })
        }

        #expect(await events.values == ["release"])
        #expect(defaults.bool(forKey: "stillHere"))
    }

    @Test @MainActor func successfulCleanupOrdersReleaseBeforeHelperRemoval() async throws {
        let events = EventRecorder()
        try await AppUninstaller.cleanUserData(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            loginItem: MockLoginItem(),
            homeDirectory: FileManager.default.temporaryDirectory,
            bundleID: UUID().uuidString,
            releaseBatteryLimit: { await events.record("release") },
            removeHelper: { await events.record("remove") })

        #expect(await events.values.prefix(2).elementsEqual(["release", "remove"]))
    }
}
