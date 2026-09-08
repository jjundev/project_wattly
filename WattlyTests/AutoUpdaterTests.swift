// WattlyTests/AutoUpdaterTests.swift
import Testing
import Foundation
import CryptoKit
@testable import Wattly

@Suite(.serialized) struct AutoUpdaterTests {
    private static let zipURL = URL(string: "https://github.com/jjundev/project_wattly/releases/download/v99.0.0/Wattly.zip")!
    private static let sigURL = URL(string: "https://github.com/jjundev/project_wattly/releases/download/v99.0.0/Wattly.zip.sig")!

    private static func release(zip: URL = zipURL, sig: URL? = sigURL) -> GitHubRelease {
        var assets = [GitHubReleaseAsset(name: "Wattly.zip", browserDownloadURL: zip, size: 1)]
        if let sig { assets.append(GitHubReleaseAsset(name: "Wattly.zip.sig", browserDownloadURL: sig, size: 1)) }
        return GitHubRelease(tagName: "v99.0.0", htmlURL: URL(string: "https://github.com/x")!, assets: assets)
    }

    /// 가짜 Wattly.app을 ditto로 zip에 담아 서명까지 만든다.
    private static func makeSignedArchive(bundleID: String = "dev.jjundev.Wattly", version: String = "99.0.0")
        throws -> (zip: Data, signature: String, key: Curve25519.Signing.PrivateKey) {
        let app = try UpdateVerifierTests.makeFakeApp(bundleID: bundleID, version: version)
        let zipPath = app.deletingLastPathComponent().appendingPathComponent("Wattly.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-ck", "--keepParent", app.path, zipPath.path]
        try ditto.run(); ditto.waitUntilExit()
        let zip = try Data(contentsOf: zipPath)
        let key = Curve25519.Signing.PrivateKey()
        return (zip, try key.signature(for: zip).base64EncodedString(), key)
    }

    private static func route(zip: Data, signature: String) {
        MockURLProtocol.requestHandler = { request in
            let body: Data
            switch request.url {
            case sigURL: body = Data((signature + "\n").utf8)
            case zipURL: body = zip
            default: throw URLError(.badURL)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 {
            if await MainActor.run(body: condition) { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test @MainActor func verifiedArchiveReachesTheReplacer() async throws {
        let (zip, sig, key) = try Self.makeSignedArchive()
        Self.route(zip: zip, signature: sig)
        final class Box: @unchecked Sendable { var replaced: URL? }
        let box = Box()
        let updater = AutoUpdater(sessionConfiguration: MockURLProtocol.makeConfiguration(),
                                  publicKey: key.publicKey, expectedBundleIdentifier: "dev.jjundev.Wattly",
                                  currentVersion: "1.1.0", replacer: { box.replaced = $0 })
        updater.startUpdate(release: Self.release())
        await Self.waitUntil { box.replaced != nil || { if case .failed = updater.state { return true }; return false }() }
        #expect(updater.state == .readyToRelaunch)
        #expect(box.replaced?.lastPathComponent == "Wattly.app")
    }

    @Test @MainActor func badSignatureNeverReachesTheReplacer() async throws {
        let (zip, _, _) = try Self.makeSignedArchive()
        let wrongKey = Curve25519.Signing.PrivateKey()
        Self.route(zip: zip, signature: try wrongKey.signature(for: Data("other".utf8)).base64EncodedString())
        final class Box: @unchecked Sendable { var replaced = false }
        let box = Box()
        let updater = AutoUpdater(sessionConfiguration: MockURLProtocol.makeConfiguration(),
                                  publicKey: wrongKey.publicKey, expectedBundleIdentifier: "dev.jjundev.Wattly",
                                  currentVersion: "1.1.0", replacer: { _ in box.replaced = true })
        updater.startUpdate(release: Self.release())
        await Self.waitUntil { if case .failed = updater.state { return true }; return false }
        guard case .failed(let reason) = updater.state else { Issue.record("expected .failed"); return }
        #expect(reason.contains("서명"))
        #expect(box.replaced == false)
    }

    @Test @MainActor func wrongBundleIdentifierIsRejectedAfterExtraction() async throws {
        let (zip, sig, key) = try Self.makeSignedArchive(bundleID: "dev.other.App")
        Self.route(zip: zip, signature: sig)
        final class Box: @unchecked Sendable { var replaced = false }
        let box = Box()
        let updater = AutoUpdater(sessionConfiguration: MockURLProtocol.makeConfiguration(),
                                  publicKey: key.publicKey, expectedBundleIdentifier: "dev.jjundev.Wattly",
                                  currentVersion: "1.1.0", replacer: { _ in box.replaced = true })
        updater.startUpdate(release: Self.release())
        await Self.waitUntil { if case .failed = updater.state { return true }; return false }
        #expect(box.replaced == false)
    }

    @Test @MainActor func disallowedHostFailsBeforeAnyRequest() async throws {
        MockURLProtocol.requestHandler = { _ in Issue.record("no request expected"); throw URLError(.badURL) }
        let updater = AutoUpdater(sessionConfiguration: MockURLProtocol.makeConfiguration(),
                                  publicKey: Curve25519.Signing.PrivateKey().publicKey,
                                  expectedBundleIdentifier: "dev.jjundev.Wattly", currentVersion: "1.1.0",
                                  replacer: { _ in })
        updater.startUpdate(release: Self.release(zip: URL(string: "https://evil.example/Wattly.zip")!))
        guard case .failed = updater.state else { Issue.record("expected immediate .failed"); return }
    }

    @Test @MainActor func missingSignatureAssetFailsImmediately() {
        let updater = AutoUpdater(sessionConfiguration: MockURLProtocol.makeConfiguration(),
                                  publicKey: Curve25519.Signing.PrivateKey().publicKey,
                                  expectedBundleIdentifier: "dev.jjundev.Wattly", currentVersion: "1.1.0",
                                  replacer: { _ in })
        updater.startUpdate(release: Self.release(sig: nil))
        guard case .failed = updater.state else { Issue.record("expected .failed"); return }
    }

    @Test @MainActor func cancelAfterDownloadStopsTheReplacement() async throws {
        let (zip, sig, key) = try Self.makeSignedArchive()
        Self.route(zip: zip, signature: sig)
        final class Box: @unchecked Sendable { var replaced = false }
        let box = Box()
        // 교체 직전에 취소가 들어온 상황을 흉내 낸다: replacer가 불리면 실패다.
        let updater = AutoUpdater(sessionConfiguration: MockURLProtocol.makeConfiguration(),
                                  publicKey: key.publicKey, expectedBundleIdentifier: "dev.jjundev.Wattly",
                                  currentVersion: "1.1.0", replacer: { _ in box.replaced = true })
        updater.startUpdate(release: Self.release())
        await Self.waitUntil { if case .verifying = updater.state { return true }; if case .extracting = updater.state { return true }; return false }
        updater.cancel()
        try? await Task.sleep(for: .milliseconds(500))
        #expect(updater.state == .idle)
        #expect(box.replaced == false)
    }

    @Test @MainActor func initialStateIsIdle() {
        #expect(AutoUpdater().state == .idle)
        #expect(AutoUpdater().progress == 0.0)
    }
}
