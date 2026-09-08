import AppKit
import CryptoKit
import Foundation

/// 업데이트 상태 기계. 순서: 서명 자산(작음) → zip(진행률) → 서명 검증 → 압축 해제 → 번들 검사 → 교체.
/// 검증 규칙은 전부 `UpdateVerifier`에 있고, 여기는 네트워크·파일·프로세스와 `runID`로 추적하는 취소만 다룬다.
@MainActor
@Observable
public final class AutoUpdater: NSObject, Sendable, URLSessionDownloadDelegate {
    public enum State: Equatable, Sendable {
        case idle
        case downloading(progress: Double)
        case verifying
        case extracting
        case readyToRelaunch
        case failed(reason: String)
    }

    public typealias Replacer = @MainActor (URL) throws -> Void

    public private(set) var state: State = .idle
    public var progress: Double {
        if case .downloading(let p) = state { return p }
        return 0.0
    }

    private let sessionConfiguration: URLSessionConfiguration
    private let publicKey: Curve25519.Signing.PublicKey?
    private let expectedBundleIdentifier: String
    private let currentVersion: String
    private let replacer: Replacer

    private var urlSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var signatureBase64: String?
    /// 진행 중인 업데이트의 신원. `cancel()`이 nil로 만들면 이후 모든 단계가 조용히 멈춘다.
    private var runID: UUID?

    public init(
        sessionConfiguration: URLSessionConfiguration = .default,
        publicKey: Curve25519.Signing.PublicKey? = UpdateSigningKey.publicKey,
        expectedBundleIdentifier: String = Bundle.main.bundleIdentifier ?? "dev.jjundev.Wattly",
        currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
        replacer: @escaping Replacer = { try AppReplacer.replaceAndRelaunch(newAppURL: $0) }
    ) {
        self.sessionConfiguration = sessionConfiguration
        self.publicKey = publicKey
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.currentVersion = currentVersion
        self.replacer = replacer
        super.init()
    }

    public func startUpdate(release: GitHubRelease) {
        guard let publicKey else {
            state = .failed(reason: String(localized: "업데이트 서명 키가 구성되지 않았습니다."))
            return
        }
        guard let zip = release.zipAsset, let sig = release.signatureAsset else {
            state = .failed(reason: String(localized: "이 릴리스에는 서명 파일이 없습니다. 릴리스 페이지에서 직접 받아 주세요."))
            return
        }
        do {
            try UpdateVerifier.validateDownloadURL(zip.browserDownloadURL)
            try UpdateVerifier.validateDownloadURL(sig.browserDownloadURL)
        } catch {
            state = .failed(reason: String(localized: "허용되지 않은 다운로드 주소입니다."))
            return
        }

        let id = UUID()
        runID = id
        signatureBase64 = nil
        state = .downloading(progress: 0.0)
        let session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: nil)
        urlSession = session

        Task { [weak self] in
            do {
                let (data, response) = try await session.data(for: Self.request(sig.browserDownloadURL))
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw UpdateVerifier.Failure.invalidSignature
                }
                guard let self, self.runID == id else { return }
                self.signatureBase64 = String(decoding: data, as: UTF8.self)
                let task = session.downloadTask(with: Self.request(zip.browserDownloadURL))
                self.downloadTask = task
                task.resume()
            } catch {
                guard let self, self.runID == id else { return }
                self.state = .failed(reason: String(localized: "서명 파일을 받지 못했습니다."))
            }
            _ = publicKey
        }
    }

    /// SettingsView 호환용 임시 유지 메서드 (Task 7에서 startUpdate(release:)로 교체 후 제거 가능).
    @available(*, deprecated, message: "Use startUpdate(release:) instead")
    public func startUpdate(asset: GitHubReleaseAsset) {}

    public func cancel() {
        runID = nil
        downloadTask?.cancel()
        downloadTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        signatureBase64 = nil
        state = .idle
    }

    nonisolated private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Wattly-App", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        return request
    }

    // MARK: - URLSessionDownloadDelegate

    public nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            if case .downloading = self.state { self.state = .downloading(progress: fraction) }
        }
    }

    public nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        // 델리게이트가 돌아가면 location이 삭제되므로 동기적으로 옮긴다.
        let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stagedZip = stagingDir.appendingPathComponent("update.zip")
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: stagedZip)
        } catch {
            Task { @MainActor in
                self.state = .failed(reason: String(format: String(localized: "임시 파일 저장 실패: %@"), error.localizedDescription))
            }
            return
        }
        Task { @MainActor in
            guard let id = self.runID, let signature = self.signatureBase64 else { return }
            self.state = .verifying
            self.processStagedArchive(id: id, stagedZip: stagedZip, stagingDir: stagingDir, signatureBase64: signature)
        }
    }

    public nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else { return }
        Task { @MainActor in
            if case .downloading = self.state {
                self.state = .failed(reason: String(format: String(localized: "다운로드 실패: %@"), error.localizedDescription))
            }
        }
    }

    // MARK: - 검증 → 압축 해제 → 검사 → 교체

    private func processStagedArchive(id: UUID, stagedZip: URL, stagingDir: URL, signatureBase64: String) {
        let publicKey = self.publicKey
        let expectedBundleIdentifier = self.expectedBundleIdentifier
        let currentVersion = self.currentVersion
        Task.detached(priority: .userInitiated) { [weak self] in
            func fail(_ reason: String) async {
                await MainActor.run { [weak self] in
                    guard let self, self.runID == id else { return }
                    self.state = .failed(reason: reason)
                }
            }
            do {
                guard let publicKey else { await fail(String(localized: "업데이트 서명 키가 구성되지 않았습니다.")); return }
                let archive = try Data(contentsOf: stagedZip)
                do {
                    try UpdateVerifier.verify(archive: archive, signatureBase64: signatureBase64, publicKey: publicKey)
                } catch {
                    await fail(String(localized: "업데이트 서명이 맞지 않습니다. 설치를 중단했습니다."))
                    return
                }

                let proceed = await MainActor.run { [weak self] in
                    guard let self, self.runID == id else { return false }
                    self.state = .extracting
                    return true
                }
                guard proceed else { return }

                let ditto = Process()
                ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                ditto.arguments = ["-xk", stagedZip.path, stagingDir.path]
                try ditto.run()
                ditto.waitUntilExit()
                guard ditto.terminationStatus == 0 else {
                    await fail(String(localized: "압축 해제에 실패했습니다."))
                    return
                }

                guard let appURL = Self.locateApp(in: stagingDir) else {
                    await fail(String(localized: "업데이트 앱 번들을 찾을 수 없습니다."))
                    return
                }
                do {
                    try UpdateVerifier.validateStagedApp(
                        at: appURL, expectedBundleIdentifier: expectedBundleIdentifier, currentVersion: currentVersion)
                } catch {
                    await fail(String(localized: "받은 번들이 Wattly의 새 버전이 아닙니다. 설치를 중단했습니다."))
                    return
                }

                await MainActor.run { [weak self] in
                    guard let self, self.runID == id else { return }
                    self.state = .readyToRelaunch
                    do {
                        try self.replacer(appURL)
                    } catch {
                        self.state = .failed(reason: String(format: String(localized: "앱 교체 실행 실패: %@"), error.localizedDescription))
                    }
                }
            } catch {
                await fail(String(format: String(localized: "업데이트 처리 중 오류: %@"), error.localizedDescription))
            }
        }
    }

    nonisolated private static func locateApp(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        if let direct = contents.first(where: { $0.pathExtension == "app" }) { return direct }
        for item in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue,
                  let sub = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil),
                  let app = sub.first(where: { $0.pathExtension == "app" }) else { continue }
            return app
        }
        return nil
    }
}
