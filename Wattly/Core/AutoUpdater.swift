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
    public var progress: Double {
        if case .downloading(let p) = state {
            return p
        }
        return 0.0
    }

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

    public func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        state = .idle
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
                // Only set failure if we were still in a downloading state
                if case .downloading = self.state {
                    self.state = .failed(reason: "다운로드 실패: \(error.localizedDescription)")
                }
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

                // Locate .app bundle inside staging directory
                let contents = try FileManager.default.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: nil)
                var foundAppURL = contents.first(where: { $0.pathExtension == "app" })

                if foundAppURL == nil {
                    for item in contents {
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                            if let subContents = try? FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil),
                               let subApp = subContents.first(where: { $0.pathExtension == "app" }) {
                                foundAppURL = subApp
                                break
                            }
                        }
                    }
                }

                guard let appURL = foundAppURL else {
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
