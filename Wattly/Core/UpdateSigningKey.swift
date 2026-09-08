// Wattly/Core/UpdateSigningKey.swift
import CryptoKit
import Foundation

/// 릴리스 zip 서명을 검증하는 Ed25519 공개키. 짝이 되는 개인키는 `~/.wattly/update-signing.key`에만 있다
/// (`scripts/generate-update-key.swift`). 키를 바꾸면 그 키로 서명된 릴리스만 설치된다 — 이전 릴리스 사용자는
/// 마지막 구키 릴리스까지는 자동 업데이트되고, 그다음은 수동 설치가 필요하다.
enum UpdateSigningKey {
    /// `scripts/generate-update-key.swift` 출력의 마지막 줄을 그대로 붙여 넣는다.
    static let publicKeyBase64 = "XdA462Amt6rjX++uNQSehdKam8pi9O5UJBwlKAYz15M="

    static var publicKey: Curve25519.Signing.PublicKey? {
        guard let raw = Data(base64Encoded: publicKeyBase64), raw.count == 32 else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }
}
