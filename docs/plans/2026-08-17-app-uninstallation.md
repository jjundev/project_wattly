# App Uninstallation (완전 삭제) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a complete app uninstallation feature ("Wattly 완전 삭제") to the "일반" (General) settings tab that unregisters the login item, removes the privileged fan daemon (if installed), wipes user defaults and cache directories, removes the app bundle, and terminates the application.

**Architecture:** A dedicated `AppUninstaller` engine in `Wattly/Core/AppUninstaller.swift` handles orchestration with injected seams for testability (`LoginItemControlling`, `UserDefaults`, `FileManager`). A background self-deletion shell script is spawned prior to calling `NSApplication.shared.terminate(nil)` to cleanly remove the application bundle and remaining traces after the process exits. `SettingsView.swift` integrates the destructive action button in the "일반" card with a confirmation alert dialog.

**Tech Stack:** Swift 6.0, SwiftUI, AppKit, ServiceManagement (`SMAppService`), Swift Testing (`@Suite`, `@Test`).

## Global Constraints

- Swift 6 language mode with strict concurrency.
- macOS 14.0+ deployment target.
- Pure/injectable design for all system-altering logic so unit tests run hermetically without deleting real user files or terminating the test host.
- UI styling must strictly align with Wattly's design tokens and font typography (`WattlyFont`, `Tokens`, destructive `.red` foreground for dangerous actions).

---

### Task 1: Core Engine - `AppUninstaller`

**Files:**
- Create: `Wattly/Core/AppUninstaller.swift`
- Test: `WattlyTests/AppUninstallerTests.swift`

**Interfaces:**
- Consumes: `LoginItemControlling` (`Wattly/Core/LoginItem.swift`), `FanHelperInstaller` (`Wattly/Control/FanHelperInstaller.swift`)
- Produces: `AppUninstaller.targetCleanupPaths(homeDirectory:bundleID:) -> [URL]`, `AppUninstaller.generateUninstallScript(currentAppURL:currentPID:pathsToDelete:) -> String`, `AppUninstaller.cleanUserData(userDefaults:loginItem:fileManager:homeDirectory:bundleID:) async`, `AppUninstaller.uninstall(currentAppURL:userDefaults:loginItem:fileManager:homeDirectory:bundleID:) async throws`

- [ ] **Step 1: Write failing unit tests in `WattlyTests/AppUninstallerTests.swift`**

```swift
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

    @Test func testCleanUserDataDisablesLoginItemAndWipesDefaults() async {
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
}
```

- [ ] **Step 2: Implement `Wattly/Core/AppUninstaller.swift`**

```swift
import Foundation
import AppKit

public enum AppUninstaller: Sendable {
    /// Returns the list of standard user directories and files associated with Wattly.
    public static func targetCleanupPaths(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleID: String = Bundle.main.bundleIdentifier ?? "dev.jjundev.Wattly"
    ) -> [URL] {
        [
            homeDirectory.appendingPathComponent("Library/Application Support").appendingPathComponent(bundleID),
            homeDirectory.appendingPathComponent("Library/Application Support/Wattly"),
            homeDirectory.appendingPathComponent("Library/Caches").appendingPathComponent(bundleID),
            homeDirectory.appendingPathComponent("Library/Caches/Wattly"),
            homeDirectory.appendingPathComponent("Library/Preferences").appendingPathComponent("\(bundleID).plist"),
            homeDirectory.appendingPathComponent("Library/Saved Application State").appendingPathComponent("\(bundleID).savedState"),
            homeDirectory.appendingPathComponent("Library/HTTPStorages").appendingPathComponent(bundleID)
        ]
    }

    /// Generates the shell script executed in the background to wait for app exit and delete bundle + files.
    public static func generateUninstallScript(
        currentAppURL: URL,
        currentPID: Int32,
        pathsToDelete: [URL]
    ) -> String {
        var lines = [
            "while kill -0 \(currentPID) 2>/dev/null; do",
            "    sleep 0.2",
            "done",
            "rm -rf \"\(currentAppURL.path)\""
        ]
        for path in pathsToDelete {
            lines.append("rm -rf \"\(path.path)\"")
        }
        return lines.joined(separator: "\n")
    }

    /// Cleans in-app data, unregisters login items, removes helper daemon if present, and deletes user library files.
    public static func cleanUserData(
        userDefaults: UserDefaults = .standard,
        loginItem: LoginItemControlling = LoginItem(),
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleID: String = Bundle.main.bundleIdentifier ?? "dev.jjundev.Wattly"
    ) async {
        // 1. Unregister login item
        try? loginItem.setEnabled(false)

        // 2. Remove privileged helper daemon if installed
        let daemonPath = "/Library/PrivilegedHelperTools/\(FanHelperInstaller.label)"
        let plistPath = "/Library/LaunchDaemons/\(FanHelperInstaller.label).plist"
        if fileManager.fileExists(atPath: daemonPath) || fileManager.fileExists(atPath: plistPath) {
            try? await FanHelperInstaller.uninstall()
        }

        // 3. Clear user defaults
        userDefaults.removePersistentDomain(forName: bundleID)
        userDefaults.synchronize()

        // 4. Delete user files in Library
        let cleanupPaths = targetCleanupPaths(homeDirectory: homeDirectory, bundleID: bundleID)
        for path in cleanupPaths {
            try? fileManager.removeItem(at: path)
        }
    }

    /// Executes full cleanup, launches the self-delete background script, and terminates the application.
    @MainActor
    public static func uninstall(
        currentAppURL: URL = Bundle.main.bundleURL,
        userDefaults: UserDefaults = .standard,
        loginItem: LoginItemControlling = LoginItem(),
        fileManager: FileManager = .default
    ) async throws {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let cleanupPaths = targetCleanupPaths()

        await cleanUserData(
            userDefaults: userDefaults,
            loginItem: loginItem,
            fileManager: fileManager
        )

        let script = generateUninstallScript(
            currentAppURL: currentAppURL,
            currentPID: currentPID,
            pathsToDelete: cleanupPaths
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()

        NSApplication.shared.terminate(nil)
    }
}
```

- [ ] **Step 3: Run unit tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/AppUninstallerTests`
Expected: `AppUninstallerTests` passes (3/3 tests pass).

- [ ] **Step 4: Commit**

```bash
git add Wattly/Core/AppUninstaller.swift WattlyTests/AppUninstallerTests.swift
git commit -m "feat: add AppUninstaller core logic and tests"
```

---

### Task 2: Settings UI Integration - "일반" 탭에 완전 삭제 버튼 및 확인 다이얼로그 추가

**Files:**
- Modify: `Wattly/Views/SettingsView.swift:144-165`

**Interfaces:**
- Consumes: `AppUninstaller.uninstall()`
- Produces: UI with destructive "Wattly 완전 삭제..." button, confirmation alert with destructive confirmation action.

- [ ] **Step 1: Update `SettingsView.swift` with the Uninstall action button and confirmation alert**

In `Wattly/Views/SettingsView.swift`:
1. Add state variable `@State private var isUninstallConfirmationPresented = false`
2. Add the `.alert` modifier for uninstallation confirmation:
```swift
        .alert("Wattly 및 모든 데이터를 완전히 삭제할까요?",
               isPresented: $isUninstallConfirmationPresented) {
            Button("완전 삭제 및 앱 종료", role: .destructive) {
                Task {
                    try? await AppUninstaller.uninstall()
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("모든 설정값, 캐시, 백그라운드 팬 제어 도우미 및 앱이 시스템에서 완전히 제거되고 앱이 종료됩니다.")
        }
```
3. In `generalGroup`, below the "기본값으로 되돌리기" button, add a separator and the "Wattly 완전 삭제..." button:
```swift
                Rectangle().fill(t.line).frame(height: 1)

                Button {
                    isUninstallConfirmationPresented = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Wattly 완전 삭제...")
                            .font(WattlyFont.at(12.5, weight: .semibold))
                    }
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
```

- [ ] **Step 2: Verify SettingsView compiles and all existing tests pass**

Run: `xcodegen generate && xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test`
Expected: Entire test suite passes without compilation or regression errors.

- [ ] **Step 3: Commit**

```bash
git add Wattly/Views/SettingsView.swift
git commit -m "feat: add complete app uninstall button to General settings tab"
```
