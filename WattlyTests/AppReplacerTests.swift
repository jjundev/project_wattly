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
        #expect(script.contains("rm -rf \"/Applications/Wattly.app\""))
        #expect(script.contains("ditto \"/var/folders/temp/Wattly.app\" \"/Applications/Wattly.app\""))
        #expect(script.contains("xattr -dr com.apple.quarantine \"/Applications/Wattly.app\" 2>/dev/null || true"))
        #expect(script.contains("open -n \"/Applications/Wattly.app\""))
    }

    @Test func scriptHandlesPathsWithSpaces() {
        let current = URL(fileURLWithPath: "/Applications/My Cool App.app")
        let newApp = URL(fileURLWithPath: "/tmp/staging dir/My Cool App.app")
        let pid: Int32 = 999

        let script = AppReplacer.generateRelaunchScript(currentAppURL: current, newAppURL: newApp, currentPID: pid)
        
        #expect(script.contains("while kill -0 999"))
        #expect(script.contains("rm -rf \"/Applications/My Cool App.app\""))
        #expect(script.contains("ditto \"/tmp/staging dir/My Cool App.app\" \"/Applications/My Cool App.app\""))
        #expect(script.contains("open -n \"/Applications/My Cool App.app\""))
    }

    @Test @MainActor func autoUpdaterInitialStateIsIdle() {
        let updater = AutoUpdater()
        #expect(updater.state == .idle)
        #expect(updater.progress == 0.0)
    }

    @Test @MainActor func autoUpdaterCancelResetsToIdle() {
        let updater = AutoUpdater()
        let asset = GitHubReleaseAsset(
            name: "Wattly.zip",
            browserDownloadURL: URL(string: "https://example.com/Wattly.zip")!,
            size: 1000
        )
        updater.startUpdate(asset: asset)
        #expect(updater.state == .downloading(progress: 0.0))

        updater.cancel()
        #expect(updater.state == .idle)
        #expect(updater.progress == 0.0)
    }

    @Test @MainActor func autoUpdaterProgressUpdatesOnDidWriteData() async {
        let updater = AutoUpdater()
        let asset = GitHubReleaseAsset(
            name: "Wattly.zip",
            browserDownloadURL: URL(string: "https://example.com/Wattly.zip")!,
            size: 1000
        )
        updater.startUpdate(asset: asset)
        #expect(updater.progress == 0.0)

        let session = URLSession(configuration: .default)
        let dummyTask = session.downloadTask(with: URL(string: "https://example.com")!)
        
        updater.urlSession(session, downloadTask: dummyTask, didWriteData: 500, totalBytesWritten: 500, totalBytesExpectedToWrite: 1000)
        
        // Yield so MainActor Task scheduled in didWriteData can execute
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(updater.progress == 0.5)
        #expect(updater.state == .downloading(progress: 0.5))
        
        dummyTask.cancel()
        session.invalidateAndCancel()
    }

    @Test @MainActor func autoUpdaterHandlesNetworkError() async {
        let updater = AutoUpdater()
        let asset = GitHubReleaseAsset(
            name: "Wattly.zip",
            browserDownloadURL: URL(string: "https://example.com/Wattly.zip")!,
            size: 1000
        )
        updater.startUpdate(asset: asset)

        let session = URLSession(configuration: .default)
        let dummyTask = session.downloadTask(with: URL(string: "https://example.com")!)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: "The request timed out."])

        updater.urlSession(session, task: dummyTask, didCompleteWithError: error)

        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        if case .failed(let reason) = updater.state {
            #expect(reason.contains("다운로드 실패"))
            #expect(reason.contains("The request timed out."))
        } else {
            Issue.record("Expected state to be .failed, but got \(updater.state)")
        }

        dummyTask.cancel()
        session.invalidateAndCancel()
    }

    @Test @MainActor func autoUpdaterHandlesStagingAndInvalidArchiveGracefully() async throws {
        let updater = AutoUpdater()
        let tempSrc = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tmp")
        try "corrupted zip data".data(using: .utf8)!.write(to: tempSrc)

        let session = URLSession(configuration: .default)
        let dummyTask = session.downloadTask(with: URL(string: "https://example.com")!)

        // Calling didFinishDownloadingTo triggers synchronous move and async ditto extraction
        updater.urlSession(session, downloadTask: dummyTask, didFinishDownloadingTo: tempSrc)

        // Wait for extraction to attempt and fail gracefully
        for _ in 0..<20 {
            if case .failed = updater.state {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        if case .failed(let reason) = updater.state {
            #expect(!reason.isEmpty)
        } else {
            Issue.record("Expected state to transition to .failed due to corrupt zip, but got \(updater.state)")
        }

        dummyTask.cancel()
        session.invalidateAndCancel()
    }
}
