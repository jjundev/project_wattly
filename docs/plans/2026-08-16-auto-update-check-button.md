# In-App Auto Update & Check Button Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a software update checker and in-app auto updater to the "General" tab of the Settings view, checking GitHub Releases for new versions, tracking download progress, extracting the archive, and safely replacing and relaunching the app.

**Architecture:** A standalone `UpdateChecker` handles GitHub Releases API querying, version parsing, and SemVer comparison. An `AutoUpdater` conforms to `URLSessionDownloadDelegate` to stream real-time download progress and synchronously stages downloaded payloads. An `AppReplacer` executes a robust background shell script to wait for app exit, overwrite the current `.app` bundle, strip quarantine attributes, and relaunch. The UI in `SettingsView` binds reactively to the state and presents clean feedback (idle, checking, download progress, up-to-date, failed).

**Tech Stack:** Swift 6, SwiftUI, Swift Testing framework (`@Test`, `#expect`), AppKit (`NSApplication`, `NSWorkspace`, `Process`), URLSession (`URLSessionDownloadDelegate`), XcodeGen (`xcodegen generate`).

## Global Constraints

- **Pure logic separation:** Version comparison and payload decoding must be isolated and unit-tested without network dependencies.
- **Defensive handling:** Missing release assets, invalid JSON, network timeouts, or rate limits must cleanly transition to error states without crashing.
- **Project generation:** Whenever new Swift files or tests are created, execute `xcodegen generate` before running `xcodebuild`.
- **GitHub API compliance:** Include `User-Agent: Wattly-App` and `Accept: application/vnd.github.v3+json` in all GitHub API requests.
- **Design System alignment:** UI elements in `SettingsView` must use `WattlyFont`, `Tokens`, `SettingsCard`, and existing component styles.
- **Swift 6 Strict Concurrency:** All `@Observable` UI-facing models must be `@MainActor` or Sendable compliant. Use `Task.detached` instead of GCD queues.
- **Test execution command:** `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData`

---

### Task 1: Semantic Versioning & GitHub Release Parser (`UpdateChecker`)

**Files:**
- Create: `Wattly/Core/UpdateChecker.swift`
- Create: `WattlyTests/UpdateCheckerTests.swift`

**Interfaces:**
- Consumes: `Bundle.main.infoDictionary` for `CFBundleShortVersionString`
- Produces: 
  - `struct GitHubReleaseAsset: Decodable, Sendable, Equatable`
  - `struct GitHubRelease: Decodable, Sendable, Equatable`
  - `final class UpdateChecker: @Observable, @MainActor` with `func isNewer(latest:than:) -> Bool`, `func decodeRelease(from:) throws -> GitHubRelease`, and `func checkForUpdates(session:) async`

- [ ] **Step 1: Write the failing test**

Create `WattlyTests/UpdateCheckerTests.swift`:
```swift
import Testing
import Foundation
@testable import Wattly

@Suite struct UpdateCheckerTests {
    @Test func versionComparisonHandlesSemVer() {
        #expect(UpdateChecker.isNewer(latest: "1.0.1", than: "1.0.0") == true)
        #expect(UpdateChecker.isNewer(latest: "1.1.0", than: "1.0.9") == true)
        #expect(UpdateChecker.isNewer(latest: "2.0.0", than: "1.99.99") == true)
        #expect(UpdateChecker.isNewer(latest: "1.0.0", than: "1.0.0") == false)
        #expect(UpdateChecker.isNewer(latest: "0.9.9", than: "1.0.0") == false)
        #expect(UpdateChecker.isNewer(latest: "v1.2.0", than: "1.1.0") == true)
        #expect(UpdateChecker.isNewer(latest: "1.0", than: "1.0.0") == false)
        #expect(UpdateChecker.isNewer(latest: "1.0.1", than: "1.0") == true)
    }

    @Test func parsesGitHubReleaseJsonAndFindsZipAsset() throws {
        let sampleJson = """
        {
            "tag_name": "v1.2.0",
            "html_url": "https://github.com/jjundev/Wattly/releases/tag/v1.2.0",
            "body": "Release notes here",
            "assets": [
                {
                    "name": "Wattly.dmg",
                    "browser_download_url": "https://github.com/jjundev/Wattly/releases/download/v1.2.0/Wattly.dmg",
                    "size": 123456
                },
                {
                    "name": "Wattly.zip",
                    "browser_download_url": "https://github.com/jjundev/Wattly/releases/download/v1.2.0/Wattly.zip",
                    "size": 654321
                }
            ]
        }
        """.data(using: .utf8)!

        let release = try UpdateChecker.decodeRelease(from: sampleJson)
        #expect(release.version == "1.2.0")
        #expect(release.zipAsset?.browserDownloadURL.absoluteString == "https://github.com/jjundev/Wattly/releases/download/v1.2.0/Wattly.zip")
        #expect(release.htmlURL.absoluteString == "https://github.com/jjundev/Wattly/releases/tag/v1.2.0")
    }

    @Test func handlesReleaseWithoutZipAsset() throws {
        let sampleJson = """
        {
            "tag_name": "v1.0.5",
            "html_url": "https://github.com/jjundev/Wattly/releases/tag/v1.0.5",
            "body": "No assets",
            "assets": []
        }
        """.data(using: .utf8)!

        let release = try UpdateChecker.decodeRelease(from: sampleJson)
        #expect(release.version == "1.0.5")
        #expect(release.zipAsset == nil)
    }
}
```

- [ ] **Step 2: Regenerate Xcode project & run test to verify it fails**

Run: `xcodegen generate && xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/UpdateCheckerTests`
Expected: FAIL with "cannot find 'UpdateChecker' in scope".

- [ ] **Step 3: Implement `UpdateChecker.swift`**

Create `Wattly/Core/UpdateChecker.swift`:
```swift
import Foundation
import SwiftUI

public struct GitHubReleaseAsset: Decodable, Sendable, Equatable {
    public let name: String
    public let browserDownloadURL: URL
    public let size: Int

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }
}

public struct GitHubRelease: Decodable, Sendable, Equatable {
    public let tagName: String
    public let htmlURL: URL
    public let body: String?
    public let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case assets
    }

    public var version: String {
        tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
    }

    public var zipAsset: GitHubReleaseAsset? {
        assets.first(where: { $0.name.lowercased().hasSuffix(".zip") })
    }
}

@MainActor
@Observable
public final class UpdateChecker {
    public enum Status: Equatable, Sendable {
        case idle
        case checking
        case upToDate
        case available(release: GitHubRelease)
        case failed(reason: String)
    }

    public private(set) var status: Status = .idle
    public let repo: String

    public init(repo: String = "jjundev/Wattly") {
        self.repo = repo
    }

    public var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    public static func cleanVersion(_ v: String) -> String {
        v.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
    }

    public static func isNewer(latest: String, than current: String) -> Bool {
        let lParts = cleanVersion(latest).split(separator: ".").compactMap { Int($0) }
        let cParts = cleanVersion(current).split(separator: ".").compactMap { Int($0) }

        let count = max(lParts.count, cParts.count)
        for i in 0..<count {
            let l = i < lParts.count ? lParts[i] : 0
            let c = i < cParts.count ? cParts[i] : 0
            if l > c { return true }
            if l < c { return false }
        }
        return false
    }

    public static func decodeRelease(from data: Data) throws -> GitHubRelease {
        let decoder = JSONDecoder()
        return try decoder.decode(GitHubRelease.self, from: data)
    }

    public func checkForUpdates(session: URLSession = .shared) async {
        status = .checking

        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            status = .failed(reason: "잘못된 저장소 주소입니다.")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("Wattly-App", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                status = .failed(reason: "응답을 받을 수 없습니다.")
                return
            }

            if httpResponse.statusCode == 404 {
                status = .upToDate // No releases published yet
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                status = .failed(reason: "서버 응답 오류 (\(httpResponse.statusCode))")
                return
            }

            let release = try Self.decodeRelease(from: data)
            if Self.isNewer(latest: release.version, than: currentVersion) {
                status = .available(release: release)
            } else {
                status = .upToDate
            }
        } catch {
            status = .failed(reason: "업데이트 확인 중 오류 발생")
        }
    }
}
```

- [ ] **Step 4: Regenerate Xcode project & run test to verify it passes**

Run: `xcodegen generate && xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/UpdateCheckerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/UpdateChecker.swift WattlyTests/UpdateCheckerTests.swift
git commit -m "feat(update): add UpdateChecker model and SemVer test suite"
```

---

### Task 2: In-App Auto Download, Synchronous Staging, Unpack & App Replacement Engine (`AppReplacer` & `AutoUpdater`)

**Files:**
- Create: `Wattly/Core/AppReplacer.swift`
- Create: `Wattly/Core/AutoUpdater.swift`
- Create: `WattlyTests/AppReplacerTests.swift`

**Interfaces:**
- Consumes: `GitHubReleaseAsset`, `Bundle.main.bundleURL`
- Produces:
  - `enum AppReplacer`: `static func generateRelaunchScript(currentAppURL: URL, newAppURL: URL, currentPID: Int32) -> String`, `static func replaceAndRelaunch(currentAppURL: URL, newAppURL: URL) throws`
  - `final class AutoUpdater: NSObject, URLSessionDownloadDelegate, @Observable, @MainActor`: `var progress: Double`, `var state: State`, `func startUpdate(asset: GitHubReleaseAsset)`

- [ ] **Step 1: Write unit test for relaunch script generation**

Create `WattlyTests/AppReplacerTests.swift`:
```swift
import Testing
import Foundation
@testable import Wattly

@Suite struct AppReplacerTests {
    @Test func scriptContainsKillLoopAndDittoReplacement() {
        let current = URL(fileURLWithPath: "/Applications/Wattly.app")
        let newApp = URL(fileURLWithPath: "/var/folders/temp/Wattly.app")
        let pid: Int32 = 12345

        let script = AppReplacer.generateRelaunchScript(currentAppURL: current, newAppURL: newApp, currentPID: pid)
        
        #expect(script.contains("while kill -0 12345"))
        #expect(script.contains("/var/folders/temp/Wattly.app"))
        #expect(script.contains("/Applications/Wattly.app"))
        #expect(script.contains("xattr -dr com.apple.quarantine"))
        #expect(script.contains("open -n"))
    }
}
```

- [ ] **Step 2: Regenerate Xcode project & run test to verify it fails**

Run: `xcodegen generate && xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/AppReplacerTests`
Expected: FAIL with "cannot find 'AppReplacer' in scope".

- [ ] **Step 3: Implement `AppReplacer.swift` & `AutoUpdater.swift`**

Create `Wattly/Core/AppReplacer.swift`:
```swift
import Foundation
import AppKit

public enum AppReplacer {
    public static func generateRelaunchScript(currentAppURL: URL, newAppURL: URL, currentPID: Int32) -> String {
        """
        while kill -0 \(currentPID) 2>/dev/null; do
            sleep 0.2
        done
        rm -rf "\(currentAppURL.path)"
        ditto "\(newAppURL.path)" "\(currentAppURL.path)"
        xattr -dr com.apple.quarantine "\(currentAppURL.path)" 2>/dev/null || true
        open -n "\(currentAppURL.path)"
        """
    }

    public static func replaceAndRelaunch(currentAppURL: URL = Bundle.main.bundleURL, newAppURL: URL) throws {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let script = generateRelaunchScript(currentAppURL: currentAppURL, newAppURL: newAppURL, currentPID: currentPID)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()

        NSApplication.shared.terminate(nil)
    }
}
```

Create `Wattly/Core/AutoUpdater.swift`:
```swift
import Foundation
import AppKit

@MainActor
@Observable
public final class AutoUpdater: NSObject, Sendable, URLSessionDownloadDelegate {
    public enum State: Equatable, Sendable {
        case idle
        case downloading(progress: Double)
        case extracting
        case readyToRelaunch
        case failed(reason: String)
    }

    public private(set) var state: State = .idle
    private var urlSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?

    public override init() {
        super.init()
    }

    public func startUpdate(asset: GitHubReleaseAsset) {
        state = .downloading(progress: 0.0)

        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.urlSession = session

        var request = URLRequest(url: asset.browserDownloadURL)
        request.setValue("Wattly-App", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        let task = session.downloadTask(with: request)
        self.downloadTask = task
        task.resume()
    }

    // MARK: - URLSessionDownloadDelegate

    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            if case .downloading = self.state {
                self.state = .downloading(progress: fraction)
            }
        }
    }

    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Synchronously stage the downloaded file to prevent deletion on delegate return
        let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stagedZip = stagingDir.appendingPathComponent("update.zip")
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: stagedZip)
        } catch {
            Task { @MainActor in
                self.state = .failed(reason: "임시 파일 저장 실패: \(error.localizedDescription)")
            }
            return
        }

        Task { @MainActor in
            self.state = .extracting
            self.processStagedArchive(stagedZip: stagedZip, stagingDir: stagingDir)
        }
    }

    public nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            Task { @MainActor in
                self.state = .failed(reason: "다운로드 실패: \(error.localizedDescription)")
            }
        }
    }

    private func processStagedArchive(stagedZip: URL, stagingDir: URL) {
        Task.detached(priority: .userInitiated) {
            do {
                // Unzip using /usr/bin/ditto
                let ditto = Process()
                ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                ditto.arguments = ["-xk", stagedZip.path, stagingDir.path]
                try ditto.run()
                ditto.waitUntilExit()

                guard ditto.terminationStatus == 0 else {
                    await MainActor.run {
                        self.state = .failed(reason: "압축 해제에 실패했습니다.")
                    }
                    return
                }

                // Locate .app bundle inside staging directory (shallow search)
                let contents = try FileManager.default.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: nil)
                guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
                    await MainActor.run {
                        self.state = .failed(reason: "업데이트 앱 번들을 찾을 수 없습니다.")
                    }
                    return
                }

                await MainActor.run {
                    self.state = .readyToRelaunch
                    do {
                        try AppReplacer.replaceAndRelaunch(newAppURL: appURL)
                    } catch {
                        self.state = .failed(reason: "앱 교체 실행 실패: \(error.localizedDescription)")
                    }
                }
            } catch {
                await MainActor.run {
                    self.state = .failed(reason: "업데이트 처리 중 오류: \(error.localizedDescription)")
                }
            }
        }
    }
}
```

- [ ] **Step 4: Regenerate Xcode project & run test to verify it passes**

Run: `xcodegen generate && xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/AppReplacerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/AppReplacer.swift Wattly/Core/AutoUpdater.swift WattlyTests/AppReplacerTests.swift
git commit -m "feat(update): add AppReplacer and AutoUpdater with synchronous staging pipeline"
```

---

### Task 3: Settings UI Integration (General Tab) & Localization

**Files:**
- Modify: `Wattly/Views/SettingsView.swift`
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Modify: `WattlyTests/LocalizationTests.swift`

**Interfaces:**
- Consumes: `UpdateChecker`, `AutoUpdater`, `Tokens`, `WattlyFont`
- Produces: Software update row in `generalGroup` with version label, update status, progress indicator, and action button.

- [ ] **Step 1: Verify current SettingsView tests pass before UI modification**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/SettingsResetTests`
Expected: PASS.

- [ ] **Step 2: Add Update row to `SettingsView.swift`**

Modify `Wattly/Views/SettingsView.swift`:
In `SettingsView`, declare properties:
```swift
@State private var updateChecker = UpdateChecker()
@State private var autoUpdater = AutoUpdater()
```

In `generalGroup`:
```swift
                // 소프트웨어 업데이트
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        SettingsRowTitle("소프트웨어 업데이트")
                        HStack(spacing: 6) {
                            Text("현재 버전 v\(updateChecker.currentVersion)")
                                .font(WattlyFont.at(11.5, weight: .regular))
                                .foregroundStyle(t.faint)

                            switch autoUpdater.state {
                            case .downloading(let fraction):
                                ProgressView(value: fraction)
                                    .progressViewStyle(.linear)
                                    .frame(width: 80)
                                Text("\(Int(fraction * 100))%")
                                    .font(WattlyFont.at(11, weight: .medium))
                                    .foregroundStyle(t.text)
                            case .extracting, .readyToRelaunch:
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 10, height: 10)
                                Text("설치 준비 중...")
                                    .font(WattlyFont.at(11, weight: .medium))
                                    .foregroundStyle(t.faint)
                            case .failed(let reason):
                                Text("• \(reason)")
                                    .font(WattlyFont.at(11, weight: .regular))
                                    .foregroundStyle(.red)
                            case .idle:
                                switch updateChecker.status {
                                case .checking:
                                    ProgressView()
                                        .scaleEffect(0.5)
                                        .frame(width: 10, height: 10)
                                case .upToDate:
                                    Text("• 최신 버전입니다")
                                        .font(WattlyFont.at(11.5, weight: .medium))
                                        .foregroundStyle(.green)
                                case .available(let release):
                                    Text("• v\(release.version) 사용 가능")
                                        .font(WattlyFont.at(11.5, weight: .medium))
                                        .foregroundStyle(t.accent)
                                case .failed(let reason):
                                    Text("• \(reason)")
                                        .font(WattlyFont.at(11, weight: .regular))
                                        .foregroundStyle(.red)
                                case .idle:
                                    EmptyView()
                                }
                            }
                        }
                    }

                    Spacer(minLength: 8)

                    updateActionButton
                }
                .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))

                Rectangle().fill(t.line).frame(height: 1)
```

Add helper view `updateActionButton`:
```swift
    @ViewBuilder
    private var updateActionButton: some View {
        if case .available(let release) = updateChecker.status, case .idle = autoUpdater.state {
            if let asset = release.zipAsset {
                Button {
                    autoUpdater.startUpdate(asset: asset)
                } label: {
                    Text("지금 업데이트")
                        .font(WattlyFont.at(12, weight: .medium))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(t.accent)
                        )
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    NSWorkspace.shared.open(release.htmlURL)
                } label: {
                    Text("릴리즈 열기")
                        .font(WattlyFont.at(12, weight: .medium))
                        .foregroundStyle(t.text)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(t.segTrack))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.rowBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        } else {
            Button {
                Task {
                    await updateChecker.checkForUpdates()
                }
            } label: {
                HStack(spacing: 5) {
                    Text(updateChecker.status == .checking ? "확인 중..." : "업데이트 확인")
                        .font(WattlyFont.at(12, weight: .medium))
                        .foregroundStyle(t.text)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(t.segTrack))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.rowBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(updateChecker.status == .checking || autoUpdater.state != .idle)
        }
    }
```

- [ ] **Step 3: Update `Localizable.xcstrings` and `LocalizationTests.swift`**

Add localized string entries for `sourceLanguage: "ko"`:
- `"소프트웨어 업데이트"`
- `"현재 버전 v%@"`
- `"최신 버전입니다"`
- `"v%@ 사용 가능"`
- `"업데이트 확인"`
- `"확인 중..."`
- `"지금 업데이트"`
- `"릴리즈 열기"`
- `"설치 준비 중..."`

Add assertions in `WattlyTests/LocalizationTests.swift` to verify these keys exist.

- [ ] **Step 4: Run full test suite to verify no regressions**

Run: `xcodegen generate && xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Views/SettingsView.swift Wattly/Resources/Localizable.xcstrings WattlyTests/LocalizationTests.swift
git commit -m "feat(settings): add software update row and progress indicator to general tab"
```

---

### Task 4: Release Packaging Automation Script (`scripts/build_release.sh`)

**Files:**
- Create: `scripts/build_release.sh`

**Interfaces:**
- Produces: `Wattly.zip` containing `Wattly.app` in `build/Release`

- [ ] **Step 1: Write `scripts/build_release.sh`**

Create `scripts/build_release.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> Building Wattly in Release configuration..."
xcodebuild -scheme Wattly \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  build

APP_PATH=".build/DerivedData/Build/Products/Release/Wattly.app"

if [ ! -d "$APP_PATH" ]; then
  echo "Error: Wattly.app not found at $APP_PATH" >&2
  exit 1
fi

OUTPUT_DIR="build/Release"
mkdir -p "$OUTPUT_DIR"
ZIP_PATH="$OUTPUT_DIR/Wattly.zip"

echo "==> Creating $ZIP_PATH..."
rm -f "$ZIP_PATH"
(cd "$(dirname "$APP_PATH")" && zip -r -y "$ROOT_DIR/$ZIP_PATH" "$(basename "$APP_PATH")")

echo "==> Success! Release asset created at $ZIP_PATH"
```

- [ ] **Step 2: Grant execution permission and verify script**

Run: `chmod +x scripts/build_release.sh`

- [ ] **Step 3: Commit**

```bash
git add scripts/build_release.sh
git commit -m "chore(build): add release packaging script to build Wattly.zip"
```
