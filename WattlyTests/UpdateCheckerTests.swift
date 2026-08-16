import Testing
import Foundation
@testable import Wattly

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite struct UpdateCheckerTests {
    private func createMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test func versionComparisonHandlesSemVer() {
        #expect(UpdateChecker.isNewer(latest: "1.0.1", than: "1.0.0") == true)
        #expect(UpdateChecker.isNewer(latest: "1.1.0", than: "1.0.9") == true)
        #expect(UpdateChecker.isNewer(latest: "2.0.0", than: "1.99.99") == true)
        #expect(UpdateChecker.isNewer(latest: "1.0.0", than: "1.0.0") == false)
        #expect(UpdateChecker.isNewer(latest: "0.9.9", than: "1.0.0") == false)
        #expect(UpdateChecker.isNewer(latest: "v1.2.0", than: "1.1.0") == true)
        #expect(UpdateChecker.isNewer(latest: "1.0", than: "1.0.0") == false)
        #expect(UpdateChecker.isNewer(latest: "1.0.1", than: "1.0") == true)
        #expect(UpdateChecker.isNewer(latest: "V2.1.0", than: "v2.0.9") == true)
        #expect(UpdateChecker.isNewer(latest: "1.0.0", than: "1.0.1") == false)
        #expect(UpdateChecker.isNewer(latest: "1.0.0.1", than: "1.0.0") == true)
        #expect(UpdateChecker.isNewer(latest: "1.0.0", than: "1.0.0.1") == false)
    }

    @Test func cleanVersionStripsPrefixesAndWhitespace() {
        #expect(UpdateChecker.cleanVersion("v1.2.3") == "1.2.3")
        #expect(UpdateChecker.cleanVersion("V2.0.0 ") == "2.0.0")
        #expect(UpdateChecker.cleanVersion(" 1.0 ") == "1.0")
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
        #expect(release.body == "Release notes here")
        #expect(release.assets.count == 2)
        #expect(release.zipAsset?.browserDownloadURL.absoluteString == "https://github.com/jjundev/Wattly/releases/download/v1.2.0/Wattly.zip")
        #expect(release.zipAsset?.size == 654321)
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

    @Test func handlesNullBodyInReleaseJson() throws {
        let sampleJson = """
        {
            "tag_name": "v1.0.6",
            "html_url": "https://github.com/jjundev/Wattly/releases/tag/v1.0.6",
            "body": null,
            "assets": []
        }
        """.data(using: .utf8)!

        let release = try UpdateChecker.decodeRelease(from: sampleJson)
        #expect(release.version == "1.0.6")
        #expect(release.body == nil)
        #expect(release.zipAsset == nil)
    }

    @Test func decodeInvalidJsonThrows() {
        let invalidJson = "{ invalid json }".data(using: .utf8)!
        #expect(throws: (any Error).self) {
            try UpdateChecker.decodeRelease(from: invalidJson)
        }
    }

    @Test @MainActor func checkForUpdatesAvailableWhenNewerVersionPublished() async {
        let session = createMockSession()
        let releaseJson = """
        {
            "tag_name": "v99.0.0",
            "html_url": "https://github.com/jjundev/Wattly/releases/tag/v99.0.0",
            "body": "Major update",
            "assets": [
                {
                    "name": "Wattly.zip",
                    "browser_download_url": "https://github.com/jjundev/Wattly/releases/download/v99.0.0/Wattly.zip",
                    "size": 5000000
                }
            ]
        }
        """.data(using: .utf8)!

        var interceptedHeaders: [String: String]?
        MockURLProtocol.requestHandler = { request in
            interceptedHeaders = request.allHTTPHeaderFields
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, releaseJson)
        }

        let checker = UpdateChecker(repo: "jjundev/Wattly")
        #expect(checker.status == .idle)

        await checker.checkForUpdates(session: session)

        #expect(interceptedHeaders?["User-Agent"] == "Wattly-App")
        #expect(interceptedHeaders?["Accept"] == "application/vnd.github.v3+json")

        if case .available(let release) = checker.status {
            #expect(release.version == "99.0.0")
            #expect(release.zipAsset?.name == "Wattly.zip")
        } else {
            Issue.record("Expected .available status, got \(checker.status)")
        }
    }

    @Test @MainActor func checkForUpdatesUpToDateWhenCurrentIsSameOrNewer() async {
        let session = createMockSession()
        let releaseJson = """
        {
            "tag_name": "v0.1.0",
            "html_url": "https://github.com/jjundev/Wattly/releases/tag/v0.1.0",
            "body": "Old release",
            "assets": []
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, releaseJson)
        }

        let checker = UpdateChecker(repo: "jjundev/Wattly")
        await checker.checkForUpdates(session: session)

        #expect(checker.status == .upToDate)
    }

    @Test @MainActor func checkForUpdates404YieldsUpToDate() async {
        let session = createMockSession()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let checker = UpdateChecker(repo: "jjundev/Wattly")
        await checker.checkForUpdates(session: session)

        #expect(checker.status == .upToDate)
    }

    @Test @MainActor func checkForUpdatesHttpErrorYieldsFailed() async {
        let session = createMockSession()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 403,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let checker = UpdateChecker(repo: "jjundev/Wattly")
        await checker.checkForUpdates(session: session)

        if case .failed(let reason) = checker.status {
            #expect(reason.contains("403"))
        } else {
            Issue.record("Expected .failed status, got \(checker.status)")
        }
    }

    @Test @MainActor func checkForUpdatesNetworkFailureYieldsFailed() async {
        let session = createMockSession()
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }

        let checker = UpdateChecker(repo: "jjundev/Wattly")
        await checker.checkForUpdates(session: session)

        if case .failed(let reason) = checker.status {
            #expect(reason == "업데이트 확인 중 오류 발생")
        } else {
            Issue.record("Expected .failed status, got \(checker.status)")
        }
    }
}
