import Testing
import Foundation
import CryptoKit
@testable import Wattly

@Suite struct UpdateVerifierTests {
    @Test func acceptsOnlyHttpsOnAllowedHosts() throws {
        try UpdateVerifier.validateDownloadURL(URL(string: "https://github.com/jjundev/project_wattly/releases/download/v1.2.0/Wattly.zip")!)
        try UpdateVerifier.validateDownloadURL(URL(string: "https://objects.githubusercontent.com/x/y")!)

        #expect(throws: UpdateVerifier.Failure.insecureScheme) {
            try UpdateVerifier.validateDownloadURL(URL(string: "http://github.com/a.zip")!)
        }
        #expect(throws: UpdateVerifier.Failure.disallowedHost("evil.example")) {
            try UpdateVerifier.validateDownloadURL(URL(string: "https://evil.example/Wattly.zip")!)
        }
        #expect(throws: UpdateVerifier.Failure.disallowedHost("github.com.evil.example")) {
            try UpdateVerifier.validateDownloadURL(URL(string: "https://github.com.evil.example/Wattly.zip")!)
        }
    }

    @Test func verifiesEd25519SignatureOverArchiveBytes() throws {
        let key = Curve25519.Signing.PrivateKey()
        let archive = Data("zip bytes".utf8)
        let signature = try key.signature(for: archive).base64EncodedString()

        try UpdateVerifier.verify(archive: archive, signatureBase64: signature + "\n", publicKey: key.publicKey)

        #expect(throws: UpdateVerifier.Failure.invalidSignature) {
            try UpdateVerifier.verify(archive: Data("tampered".utf8), signatureBase64: signature, publicKey: key.publicKey)
        }
        #expect(throws: UpdateVerifier.Failure.invalidSignature) {
            try UpdateVerifier.verify(archive: archive, signatureBase64: "not base64!!", publicKey: key.publicKey)
        }
        #expect(throws: UpdateVerifier.Failure.invalidSignature) {
            let other = Curve25519.Signing.PrivateKey()
            try UpdateVerifier.verify(archive: archive, signatureBase64: signature, publicKey: other.publicKey)
        }
    }

    @Test func validatesStagedAppIdentityAndVersion() throws {
        let app = try Self.makeFakeApp(bundleID: "dev.jjundev.Wattly", version: "9.9.9")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        try UpdateVerifier.validateStagedApp(at: app, expectedBundleIdentifier: "dev.jjundev.Wattly", currentVersion: "1.1.0")

        #expect(throws: UpdateVerifier.Failure.bundleIdentifierMismatch("dev.jjundev.Wattly")) {
            try UpdateVerifier.validateStagedApp(at: app, expectedBundleIdentifier: "dev.other.App", currentVersion: "1.1.0")
        }
        #expect(throws: UpdateVerifier.Failure.versionNotNewer("9.9.9")) {
            try UpdateVerifier.validateStagedApp(at: app, expectedBundleIdentifier: "dev.jjundev.Wattly", currentVersion: "9.9.9")
        }
        #expect(throws: UpdateVerifier.Failure.missingInfoPlist) {
            try UpdateVerifier.validateStagedApp(
                at: app.deletingLastPathComponent().appendingPathComponent("Nothing.app"),
                expectedBundleIdentifier: "dev.jjundev.Wattly", currentVersion: "1.1.0")
        }
    }

    /// `<tmp>/<uuid>/Wattly.app/Contents/Info.plist`만 있는 최소 번들. Task 6의 AutoUpdater 테스트도 재사용한다.
    static func makeFakeApp(bundleID: String, version: String, name: String = "Wattly.app") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let contents = root.appendingPathComponent(name).appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return root.appendingPathComponent(name)
    }
}
