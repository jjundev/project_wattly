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

    @Test @MainActor func testCleanUserDataDisablesLoginItemAndWipesDefaults() async {
        let mockLogin = MockLoginItem()
        let suiteName = "test.uninstall.suite.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        testDefaults.set("customValue", forKey: "someTestKey")
        #expect(testDefaults.string(forKey: "someTestKey") == "customValue")

        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        await AppUninstaller.cleanUserData(
            userDefaults: testDefaults,
            loginItem: mockLogin,
            fileManager: .default,
            homeDirectory: tempHome,
            bundleID: suiteName
        )

        #expect(mockLogin.isEnabled == false)
        #expect(mockLogin.disabledCallCount == 1)
        #expect(testDefaults.string(forKey: "someTestKey") == nil)
    }

    @Test @MainActor func testCleanUserDataReleasesTheChargeLimitBeforeRemovingTheHelper() async {
        let mockLogin = MockLoginItem()
        let spy = ReleaseSpy()
        let suiteName = "test.uninstall.battery.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        await AppUninstaller.cleanUserData(
            userDefaults: testDefaults,
            loginItem: mockLogin,
            fileManager: .default,
            homeDirectory: tempHome,
            bundleID: suiteName,
            releaseBatteryLimit: { spy.callCount += 1 }
        )

        #expect(spy.callCount == 1)
        #expect(mockLogin.disabledCallCount == 1)
    }
}
