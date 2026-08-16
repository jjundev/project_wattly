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

    public init(name: String, browserDownloadURL: URL, size: Int) {
        self.name = name
        self.browserDownloadURL = browserDownloadURL
        self.size = size
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

    public init(tagName: String, htmlURL: URL, body: String? = nil, assets: [GitHubReleaseAsset] = []) {
        self.tagName = tagName
        self.htmlURL = htmlURL
        self.body = body
        self.assets = assets
    }

    public var version: String {
        UpdateChecker.cleanVersion(tagName)
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

    public init(repo: String = "jjundev/project_wattly") {
        self.repo = repo
    }

    public var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    nonisolated public static func cleanVersion(_ v: String) -> String {
        v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ").union(.whitespacesAndNewlines))
    }

    nonisolated public static func isNewer(latest: String, than current: String) -> Bool {
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

    nonisolated public static func decodeRelease(from data: Data) throws -> GitHubRelease {
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
