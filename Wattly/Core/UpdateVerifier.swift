import CryptoKit
import Foundation

/// 업데이트 파이프라인이 통과시켜야 하는 세 가지 사실. 전부 순수 — 네트워크·프로세스·앱 교체는
/// `AutoUpdater`의 몫이고, 여기는 "이 바이트·이 경로·이 URL이 믿을 만한가"만 답한다.
enum UpdateVerifier {
    enum Failure: Error, Equatable {
        case insecureScheme
        case disallowedHost(String)
        case invalidSignature
        case missingInfoPlist
        case bundleIdentifierMismatch(String?)
        case versionNotNewer(String?)
    }

    /// GitHub 릴리스 자산이 실제로 내려오는 호스트. 리다이렉트 후 최종 호스트도 이 안에 있어야 한다.
    static let allowedDownloadHosts: Set<String> = [
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    static func validateDownloadURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https" else { throw Failure.insecureScheme }
        let host = url.host?.lowercased() ?? ""
        guard allowedDownloadHosts.contains(host) else { throw Failure.disallowedHost(host) }
    }

    /// `.sig` 자산은 base64 한 줄. 공백·개행은 무시한다.
    static func verify(
        archive: Data,
        signatureBase64: String,
        publicKey: Curve25519.Signing.PublicKey
    ) throws {
        let trimmed = signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signature = Data(base64Encoded: trimmed),
              publicKey.isValidSignature(signature, for: archive) else {
            throw Failure.invalidSignature
        }
    }

    /// 압축을 푼 `.app`이 우리 앱이고 지금보다 새 버전인지. 둘 다 아니면 교체하지 않는다 —
    /// 서명이 맞아도 잘못 올린 자산(다른 앱, 구버전)을 그대로 설치하는 사고를 막는다.
    static func validateStagedApp(
        at appURL: URL,
        expectedBundleIdentifier: String,
        currentVersion: String
    ) throws {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw Failure.missingInfoPlist }
        let bundleID = plist["CFBundleIdentifier"] as? String
        guard bundleID == expectedBundleIdentifier else { throw Failure.bundleIdentifierMismatch(bundleID) }
        let version = plist["CFBundleShortVersionString"] as? String
        guard let version, UpdateChecker.isNewer(latest: version, than: currentVersion) else {
            throw Failure.versionNotNewer(version)
        }
    }
}
