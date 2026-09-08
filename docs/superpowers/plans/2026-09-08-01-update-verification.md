# 자동 업데이트 무결성 검증 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** "지금 업데이트"가 서명·호스트·번들 ID·버전을 전부 확인한 zip만 앱 자리에 놓고, 실패하면 이전 앱을 그대로 남기며, 취소하면 교체까지 멈추게 만든다.

**Architecture:** 검증 규칙은 순수 `UpdateVerifier`(호스트 허용 목록, Ed25519 서명 검증, 스테이징된 `.app`의 Info.plist 검사)에 모으고, `AutoUpdater`는 그 규칙을 부르는 상태 기계로만 남긴다. 릴리스 zip 옆에 `Wattly.zip.sig`(base64 Ed25519 서명)를 GitHub 자산으로 함께 올리고, 앱에는 공개키만 내장한다. 앱 교체 스크립트는 경로를 보간하지 않고 위치 인자로 받으며, `mv` 백업 → `ditto` → 실패 시 복원 순서로 바꾼다.

**Tech Stack:** Swift 6, CryptoKit(`Curve25519.Signing`), Swift Testing, `MockURLProtocol`(기존 테스트 헬퍼를 공유로 승격), `/bin/sh` + `ditto`.

**Spec:** 감사 보고서 §1 Critical("자동 업데이트가 무결성 검증 없이 앱을 교체하고 Gatekeeper를 우회한다") + Medium("`AutoUpdater.cancel()`이 다운로드만 취소하고 교체는 막지 못한다") — https://claude.ai/code/artifact/20a3c5b7-ad33-4ec3-ae78-288a0259454d

## Global Constraints

- Swift 6 strict concurrency, macOS 14.0, arm64.
- 개인키는 절대 리포에 들어가지 않는다. 기본 위치는 `~/.wattly/update-signing.key`(0600). `.gitignore`에 `*.key`를 추가한다.
- 릴리스 자산 이름 규칙: zip은 `Wattly.zip`, 서명은 `Wattly.zip.sig`(zip 이름 + `.sig`).
- 허용 다운로드 호스트: `github.com`, `objects.githubusercontent.com`, `release-assets.githubusercontent.com`. 스킴은 `https`만.
- quarantine 속성 제거(`xattr -dr`)는 이 단계에서는 유지한다. 서명 검증이 그 근거이며, 6단계(Developer ID + 공증)에서 제거한다.
- 사용자 표시 문자열은 한국어 + `Localizable.xcstrings` 키 추가.

---

## 파일 구조

| 파일 | 책임 |
|------|------|
| `WattlyTests/Support/MockURLProtocol.swift` (신규) | `UpdateCheckerTests`의 private 헬퍼를 공유 헬퍼로 승격. URL별 응답 라우팅. |
| `Wattly/Core/UpdateVerifier.swift` (신규) | 순수 검증 규칙 3개: 다운로드 URL, 서명, 스테이징 앱. |
| `Wattly/Core/UpdateSigningKey.swift` (신규) | 내장 공개키 상수 + `Curve25519.Signing.PublicKey` 변환. |
| `Wattly/Core/UpdateChecker.swift` (수정) | `GitHubRelease.signatureAsset` 추가. |
| `Wattly/Core/AppReplacer.swift` (재작성) | 위치 인자 스크립트, 백업/복원. |
| `Wattly/Core/AutoUpdater.swift` (재작성) | 서명 먼저 받고 → zip 받고 → 검증 → 압축 해제 → 앱 검사 → 교체. `runID`로 취소 추적. 교체·세션 구성 주입 가능. |
| `Wattly/Views/SettingsView.swift:270-275` (수정) | `startUpdate(release:)` 호출, 서명 자산 없으면 "릴리즈 열기"로 폴백. |
| `scripts/generate-update-key.swift`, `scripts/sign-release.swift` (신규), `scripts/build_release.sh` (수정) | 키 생성, 서명, 릴리스 빌드에 서명 포함. |
| `WattlyTests/UpdateVerifierTests.swift` (신규), `WattlyTests/AppReplacerTests.swift` (재작성), `WattlyTests/AutoUpdaterTests.swift` (신규) | |

---

### Task 1: `MockURLProtocol`을 공유 테스트 헬퍼로 승격

**Files:**
- Create: `WattlyTests/Support/MockURLProtocol.swift`
- Modify: `WattlyTests/UpdateCheckerTests.swift:1-34` (private 클래스 삭제)

**Interfaces:**
- Produces: `final class MockURLProtocol: URLProtocol` with `nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?` and `static func makeSession() -> URLSession` — Task 6의 `AutoUpdaterTests`가 쓴다.

- [ ] **Step 1: 공유 파일 생성**

```swift
// WattlyTests/Support/MockURLProtocol.swift
import Foundation

/// 테스트 전용 URL 라우터. `requestHandler`는 스위트마다 세팅하고, 세션은 `makeSession()`으로 만든다.
/// 다운로드 태스크에도 쓰인다 — URLSession은 모든 태스크를 protocolClasses로 보낸다.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func makeSession() -> URLSession {
        URLSession(configuration: makeConfiguration())
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return config
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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
```

- [ ] **Step 2: `UpdateCheckerTests.swift`에서 private 클래스와 `createMockSession` 제거**

파일 상단의 `private final class MockURLProtocol … }` 블록(1~34행)을 삭제하고, `private func createMockSession() -> URLSession { … }`를 삭제한 뒤 본문의 `createMockSession()` 호출 6곳을 `MockURLProtocol.makeSession()`으로 바꾼다.

```bash
sed -i '' 's/createMockSession()/MockURLProtocol.makeSession()/g' WattlyTests/UpdateCheckerTests.swift
```

- [ ] **Step 3: 테스트 실행**

Run: `xcodebuild … test -only-testing:WattlyTests/UpdateCheckerTests`
Expected: 기존 11개 테스트 전부 PASS.

- [ ] **Step 4: Commit**

```bash
git add WattlyTests/Support/MockURLProtocol.swift WattlyTests/UpdateCheckerTests.swift
git commit -m "test(update): share MockURLProtocol across suites"
```

---

### Task 2: 순수 `UpdateVerifier` — 호스트·서명·앱 번들 검증

**Files:**
- Create: `Wattly/Core/UpdateVerifier.swift`
- Create: `WattlyTests/UpdateVerifierTests.swift`

**Interfaces:**
- Produces:
  - `enum UpdateVerifier.Failure: Error, Equatable { case insecureScheme, disallowedHost(String), invalidSignature, missingInfoPlist, bundleIdentifierMismatch(String?), versionNotNewer(String?) }`
  - `static func validateDownloadURL(_ url: URL) throws`
  - `static func verify(archive: Data, signatureBase64: String, publicKey: Curve25519.Signing.PublicKey) throws`
  - `static func validateStagedApp(at appURL: URL, expectedBundleIdentifier: String, currentVersion: String) throws`
- Consumes: `UpdateChecker.isNewer(latest:than:)` (기존).

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
// WattlyTests/UpdateVerifierTests.swift
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
```

- [ ] **Step 2: 실패 확인**

Run: `xcodebuild … test -only-testing:WattlyTests/UpdateVerifierTests`
Expected: 컴파일 실패 — `UpdateVerifier` 없음.

- [ ] **Step 3: 구현**

```swift
// Wattly/Core/UpdateVerifier.swift
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
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `xcodebuild … test -only-testing:WattlyTests/UpdateVerifierTests`
Expected: 3개 PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/UpdateVerifier.swift WattlyTests/UpdateVerifierTests.swift
git commit -m "feat(update): add pure UpdateVerifier for host, signature and bundle checks"
```

---

### Task 3: 서명 키 도구와 릴리스 스크립트

**Files:**
- Create: `scripts/generate-update-key.swift`, `scripts/sign-release.swift`
- Create: `Wattly/Core/UpdateSigningKey.swift`
- Modify: `scripts/build_release.sh:33-36`, `.gitignore`
- Test: `WattlyTests/UpdateVerifierTests.swift` (테스트 1개 추가)

**Interfaces:**
- Produces: `enum UpdateSigningKey { static let publicKeyBase64: String; static var publicKey: Curve25519.Signing.PublicKey? }` — Task 6이 기본 인자로 쓴다.

- [ ] **Step 1: 실패하는 테스트 — 공개키가 구성돼 있어야 한다**

`UpdateVerifierTests`에 추가:

```swift
    /// 빈 키로 출하하면 `AutoUpdater`가 모든 업데이트를 거부한다. 키를 붙여 넣기 전까지 이 테스트가 빨갛다.
    @Test func updateSigningKeyIsConfigured() {
        #expect(UpdateSigningKey.publicKey != nil)
        #expect(Data(base64Encoded: UpdateSigningKey.publicKeyBase64)?.count == 32)
    }
```

- [ ] **Step 2: 키 파일 스켈레톤(빈 키) 작성 → 테스트가 실패하는지 확인**

```swift
// Wattly/Core/UpdateSigningKey.swift
import CryptoKit
import Foundation

/// 릴리스 zip 서명을 검증하는 Ed25519 공개키. 짝이 되는 개인키는 `~/.wattly/update-signing.key`에만 있다
/// (`scripts/generate-update-key.swift`). 키를 바꾸면 그 키로 서명된 릴리스만 설치된다 — 이전 릴리스 사용자는
/// 마지막 구키 릴리스까지는 자동 업데이트되고, 그다음은 수동 설치가 필요하다.
enum UpdateSigningKey {
    /// `scripts/generate-update-key.swift` 출력의 마지막 줄을 그대로 붙여 넣는다.
    static let publicKeyBase64 = ""

    static var publicKey: Curve25519.Signing.PublicKey? {
        guard let raw = Data(base64Encoded: publicKeyBase64), raw.count == 32 else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }
}
```

Run: `xcodebuild … test -only-testing:WattlyTests/UpdateVerifierTests/updateSigningKeyIsConfigured`
Expected: FAIL (`publicKey == nil`).

- [ ] **Step 3: 키 생성 스크립트**

```swift
#!/usr/bin/env swift
// scripts/generate-update-key.swift
// 사용법: swift scripts/generate-update-key.swift [개인키 경로]
// 개인키(base64 32바이트)를 0600으로 저장하고 공개키 base64를 출력한다. 리포에는 공개키만 들어간다.
import CryptoKit
import Foundation

let defaultPath = NSString(string: "~/.wattly/update-signing.key").expandingTildeInPath
let path = CommandLine.arguments.dropFirst().first ?? defaultPath
let fm = FileManager.default

if fm.fileExists(atPath: path) {
    FileHandle.standardError.write(Data("refusing to overwrite existing key at \(path)\n".utf8))
    exit(1)
}

let key = Curve25519.Signing.PrivateKey()
let directory = (path as NSString).deletingLastPathComponent
try fm.createDirectory(atPath: directory, withIntermediateDirectories: true,
                       attributes: [.posixPermissions: 0o700])
try key.rawRepresentation.base64EncodedString().write(toFile: path, atomically: true, encoding: .utf8)
try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

print("private key written to \(path) — back it up; it is NOT in the repo")
print("public key for Wattly/Core/UpdateSigningKey.swift:")
print(key.publicKey.rawRepresentation.base64EncodedString())
```

- [ ] **Step 4: 서명 스크립트**

```swift
#!/usr/bin/env swift
// scripts/sign-release.swift
// 사용법: swift scripts/sign-release.swift <Wattly.zip> [개인키 경로]
// <Wattly.zip>.sig 에 base64 Ed25519 서명을 쓰고, 방금 쓴 서명을 공개키로 다시 검증한다.
import CryptoKit
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard let archivePath = args.first else {
    FileHandle.standardError.write(Data("usage: sign-release.swift <archive> [keyfile]\n".utf8))
    exit(64)
}
let keyPath = args.count > 1
    ? args[1]
    : NSString(string: "~/.wattly/update-signing.key").expandingTildeInPath

guard let keyText = try? String(contentsOfFile: keyPath, encoding: .utf8),
      let raw = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
    FileHandle.standardError.write(Data("cannot read private key at \(keyPath)\n".utf8))
    exit(66)
}

let archive = try Data(contentsOf: URL(fileURLWithPath: archivePath))
let signature = try key.signature(for: archive)
let signaturePath = archivePath + ".sig"
try (signature.base64EncodedString() + "\n").write(toFile: signaturePath, atomically: true, encoding: .utf8)

guard key.publicKey.isValidSignature(signature, for: archive) else {
    FileHandle.standardError.write(Data("self-check failed\n".utf8))
    exit(70)
}
print("signed \(archivePath) -> \(signaturePath)")
print("public key: \(key.publicKey.rawRepresentation.base64EncodedString())")
```

- [ ] **Step 5: 키 생성 후 공개키를 붙여 넣기**

```bash
swift scripts/generate-update-key.swift
```

출력 마지막 줄(44자 base64)을 `UpdateSigningKey.publicKeyBase64`의 값으로 넣는다. 그다음:

Run: `xcodebuild … test -only-testing:WattlyTests/UpdateVerifierTests`
Expected: 4개 PASS.

- [ ] **Step 6: `build_release.sh`에 서명 단계 추가, `.gitignore`에 키 제외**

`scripts/build_release.sh`의 마지막 두 줄(`echo "==> Success! …"` 앞)에 삽입:

```bash
KEY_FILE="${WATTLY_UPDATE_KEY_FILE:-$HOME/.wattly/update-signing.key}"
if [ ! -f "$KEY_FILE" ]; then
  echo "Error: update signing key not found at $KEY_FILE (run scripts/generate-update-key.swift)" >&2
  exit 1
fi
echo "==> Signing $ZIP_PATH..."
swift scripts/sign-release.swift "$ZIP_PATH" "$KEY_FILE"
echo "==> Upload BOTH $ZIP_PATH and $ZIP_PATH.sig as release assets."
```

`.gitignore`의 `# Secrets / env` 블록에 `*.key` 한 줄 추가.

- [ ] **Step 7: 스크립트 동작 확인**

```bash
echo hello > /tmp/wattly-sign-test.zip && swift scripts/sign-release.swift /tmp/wattly-sign-test.zip && cat /tmp/wattly-sign-test.zip.sig
```

Expected: `signed …` 출력과 base64 한 줄. 출력된 public key가 `UpdateSigningKey.publicKeyBase64`와 같은지 눈으로 확인.

- [ ] **Step 8: Commit**

```bash
git add scripts/generate-update-key.swift scripts/sign-release.swift scripts/build_release.sh .gitignore Wattly/Core/UpdateSigningKey.swift WattlyTests/UpdateVerifierTests.swift
git commit -m "feat(update): embed Ed25519 public key and sign release archives"
```

---

### Task 4: `GitHubRelease.signatureAsset`

**Files:**
- Modify: `Wattly/Core/UpdateChecker.swift:46-48`
- Test: `WattlyTests/UpdateCheckerTests.swift`

**Interfaces:**
- Produces: `GitHubRelease.signatureAsset: GitHubReleaseAsset?` — zip 이름 + `.sig`(대소문자 무시)인 자산.

- [ ] **Step 1: 실패하는 테스트**

`UpdateCheckerTests`의 `parsesGitHubReleaseJsonAndFindsZipAsset`에 자산 하나를 추가하고 단정을 붙인다. `assets` 배열에 추가:

```json
                {
                    "name": "Wattly.zip.sig",
                    "browser_download_url": "https://github.com/jjundev/Wattly/releases/download/v1.2.0/Wattly.zip.sig",
                    "size": 89
                }
```

기존 `#expect(release.assets.count == 2)`를 `== 3`으로 바꾸고 추가:

```swift
        #expect(release.signatureAsset?.name == "Wattly.zip.sig")
```

그리고 `handlesReleaseWithoutZipAsset`에 `#expect(release.signatureAsset == nil)` 추가.

- [ ] **Step 2: 실패 확인**

Run: `xcodebuild … test -only-testing:WattlyTests/UpdateCheckerTests`
Expected: 컴파일 실패 — `signatureAsset` 없음.

- [ ] **Step 3: 구현** — `zipAsset` 바로 아래:

```swift
    /// zip 옆에 올라오는 `<zip 이름>.sig`. 없으면 자동 업데이트 대신 릴리스 페이지로 안내한다.
    public var signatureAsset: GitHubReleaseAsset? {
        guard let zip = zipAsset else { return nil }
        let expected = zip.name.lowercased() + ".sig"
        return assets.first(where: { $0.name.lowercased() == expected })
    }
```

- [ ] **Step 4: 통과 확인** — Expected: `UpdateCheckerTests` 전부 PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/UpdateChecker.swift WattlyTests/UpdateCheckerTests.swift
git commit -m "feat(update): locate the release signature asset"
```

---

### Task 5: `AppReplacer` — 위치 인자 스크립트와 백업/복원

**Files:**
- Rewrite: `Wattly/Core/AppReplacer.swift`
- Rewrite: `WattlyTests/AppReplacerTests.swift` (1~35행의 스크립트 문자열 테스트 2개 교체; `autoUpdater*` 테스트는 Task 6에서 새 파일로 옮김)

**Interfaces:**
- Produces:
  - `AppReplacer.replaceScript: String` — `open` 없이 교체만 하는 POSIX sh (테스트용).
  - `AppReplacer.relaunchScript: String` — `replaceScript` + `open -n "$current"`.
  - `AppReplacer.arguments(script:currentAppURL:newAppURL:currentPID:) -> [String]` — `/bin/sh`에 넘길 argv.
  - `AppReplacer.replaceAndRelaunch(currentAppURL:newAppURL:) throws` (시그니처 유지).

- [ ] **Step 1: 실패하는 테스트 작성** — `AppReplacerTests.swift`의 앞 두 테스트를 다음으로 교체:

```swift
import Testing
import Foundation
@testable import Wattly

@Suite struct AppReplacerTests {
    /// 경로는 argv로만 전달된다. 스크립트 본문에 경로 문자열이 섞여 들어가면 `"`·`$(`가 셸 인젝션이 된다.
    @Test func pathsTravelAsArgumentsNotAsScriptText() {
        let current = URL(fileURLWithPath: "/Applications/It's \"Wattly\" $(rm -rf ~).app")
        let newApp = URL(fileURLWithPath: "/tmp/staging dir/Wattly.app")
        let argv = AppReplacer.arguments(script: AppReplacer.relaunchScript,
                                         currentAppURL: current, newAppURL: newApp, currentPID: 4242)
        #expect(argv[0] == "-c")
        #expect(argv[1] == AppReplacer.relaunchScript)
        #expect(argv[3] == current.path)
        #expect(argv[4] == newApp.path)
        #expect(argv[5] == "4242")
        #expect(!AppReplacer.relaunchScript.contains(current.path))
        #expect(AppReplacer.relaunchScript.hasSuffix("open -n \"$current\"\n"))
    }

    /// 실제 /bin/sh로 교체 스크립트를 돌린다. 성공하면 백업이 사라지고, ditto가 실패하면 원본이 복원된다.
    @Test func replaceScriptSwapsBundleAndRollsBackOnFailure() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let current = root.appendingPathComponent("Wattly.app", isDirectory: true)
        let newApp = root.appendingPathComponent("New.app", isDirectory: true)
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        try "old".write(to: current.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: newApp, withIntermediateDirectories: true)
        try "new".write(to: newApp.appendingPathComponent("marker"), atomically: true, encoding: .utf8)

        // 이미 종료된 pid — `kill -0`이 즉시 실패해 대기 루프를 빠져나온다.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try probe.run(); probe.waitUntilExit()
        let deadPID = probe.processIdentifier

        // 성공 경로
        try Self.runSh(AppReplacer.arguments(script: AppReplacer.replaceScript,
                                             currentAppURL: current, newAppURL: newApp, currentPID: deadPID))
        #expect(try String(contentsOf: current.appendingPathComponent("marker"), encoding: .utf8) == "new")
        #expect(!fm.fileExists(atPath: current.path + ".wattly-previous"))

        // 실패 경로: 새 앱 경로가 없으면 ditto가 실패하고 원본(지금은 "new")이 그대로 남는다.
        let missing = root.appendingPathComponent("Missing.app")
        _ = try? Self.runSh(AppReplacer.arguments(script: AppReplacer.replaceScript,
                                                  currentAppURL: current, newAppURL: missing, currentPID: deadPID))
        #expect(try String(contentsOf: current.appendingPathComponent("marker"), encoding: .utf8) == "new")
        #expect(!fm.fileExists(atPath: current.path + ".wattly-previous"))
    }

    private static func runSh(_ arguments: [String]) throws {
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = arguments
        try sh.run(); sh.waitUntilExit()
        if sh.terminationStatus != 0 { throw NSError(domain: "sh", code: Int(sh.terminationStatus)) }
    }
}
```

파일에 남아 있던 `autoUpdater*` 테스트 5개는 삭제한다(Task 6에서 새 파일로 대체).

- [ ] **Step 2: 실패 확인** — Run: `… -only-testing:WattlyTests/AppReplacerTests` — Expected: 컴파일 실패(`arguments`, `replaceScript` 없음).

- [ ] **Step 3: 구현**

```swift
// Wattly/Core/AppReplacer.swift
import Foundation
import AppKit

/// 다운로드·검증이 끝난 새 번들을 현재 번들 자리에 놓고 다시 연다. 경로는 argv로만 넘긴다 —
/// 스크립트 본문에 보간하면 경로의 `"`·`$(`가 그대로 셸에 들어간다.
public enum AppReplacer: Sendable {
    /// 교체만. `mv` 백업 → `ditto` → 실패 시 복원. 어느 단계가 실패해도 실행 가능한 앱 하나는 남는다.
    /// quarantine 제거는 6단계(Developer ID + 공증)에서 사라진다; 지금은 `UpdateVerifier`의 서명 검증이 근거다.
    nonisolated public static let replaceScript = """
    set -eu
    current="$1"; new="$2"; pid="$3"
    while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    backup="$current.wattly-previous"
    rm -rf "$backup"
    mv "$current" "$backup"
    if ditto "$new" "$current"; then
      rm -rf "$backup"
    else
      rm -rf "$current"
      mv "$backup" "$current"
      exit 1
    fi
    xattr -dr com.apple.quarantine "$current" 2>/dev/null || true

    """

    nonisolated public static let relaunchScript = replaceScript + "open -n \"$current\"\n"

    /// `/bin/sh -c <script> <argv0> <current> <new> <pid>` — `$0`은 이름표, `$1…$3`이 경로와 pid다.
    nonisolated public static func arguments(
        script: String, currentAppURL: URL, newAppURL: URL, currentPID: Int32
    ) -> [String] {
        ["-c", script, "wattly-relaunch", currentAppURL.path, newAppURL.path, String(currentPID)]
    }

    @MainActor
    public static func replaceAndRelaunch(currentAppURL: URL = Bundle.main.bundleURL, newAppURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments(
            script: relaunchScript,
            currentAppURL: currentAppURL,
            newAppURL: newAppURL,
            currentPID: ProcessInfo.processInfo.processIdentifier)
        try process.run()
        NSApplication.shared.terminate(nil)
    }
}
```

- [ ] **Step 4: 통과 확인** — Expected: `AppReplacerTests` 2개 PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/AppReplacer.swift WattlyTests/AppReplacerTests.swift
git commit -m "fix(update): replace the app via argv script with backup and rollback"
```

---

### Task 6: `AutoUpdater` 재작성 — 서명 → zip → 검증 → 교체, 취소 가능

**Files:**
- Rewrite: `Wattly/Core/AutoUpdater.swift`
- Create: `WattlyTests/AutoUpdaterTests.swift`
- Modify: `Wattly/Resources/Localizable.xcstrings` (새 키 5개)

**Interfaces:**
- Consumes: `UpdateVerifier`, `UpdateSigningKey.publicKey`, `GitHubRelease.zipAsset/signatureAsset`, `AppReplacer.replaceAndRelaunch(newAppURL:)`, `MockURLProtocol.makeConfiguration()`(테스트).
- Produces:
  - `AutoUpdater.State`에 `.verifying` 추가.
  - `init(sessionConfiguration:publicKey:expectedBundleIdentifier:currentVersion:replacer:)` — 전부 기본값 있음.
  - `func startUpdate(release: GitHubRelease)` (기존 `startUpdate(asset:)` 삭제).
  - `func cancel()` — 다운로드·검증·교체 어느 단계든 멈춘다.

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
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
        for _ in 0..<100 {
            if await MainActor.run(body: condition) { return }
            try? await Task.sleep(for: .milliseconds(50))
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
```

- [ ] **Step 2: 실패 확인** — Run: `… -only-testing:WattlyTests/AutoUpdaterTests` — Expected: 컴파일 실패(새 init·`startUpdate(release:)` 없음).

- [ ] **Step 3: 구현**

```swift
// Wattly/Core/AutoUpdater.swift
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
```

- [ ] **Step 4: 새 문자열을 `Localizable.xcstrings`에 추가**

키 5개: `"업데이트 서명 키가 구성되지 않았습니다."`, `"이 릴리스에는 서명 파일이 없습니다. 릴리스 페이지에서 직접 받아 주세요."`, `"허용되지 않은 다운로드 주소입니다."`, `"서명 파일을 받지 못했습니다."`, `"업데이트 서명이 맞지 않습니다. 설치를 중단했습니다."`, `"받은 번들이 Wattly의 새 버전이 아닙니다. 설치를 중단했습니다."`. 기존 키(예: `"압축 해제에 실패했습니다."`)의 JSON 블록을 복사해 30개 로케일 값에 한국어 원문을 넣는다.

- [ ] **Step 5: 통과 확인**

Run: `… -only-testing:WattlyTests/AutoUpdaterTests` 그리고 `… -only-testing:WattlyTests/LocalizationTests`
Expected: 7개 + 현지화 테스트 PASS.

- [ ] **Step 6: Commit**

```bash
git add Wattly/Core/AutoUpdater.swift WattlyTests/AutoUpdaterTests.swift Wattly/Resources/Localizable.xcstrings
git commit -m "feat(update): verify signature, host and bundle before replacing; make cancel stop replacement"
```

---

### Task 7: 설정 화면 배선

**Files:**
- Modify: `Wattly/Views/SettingsView.swift:270-275`

- [ ] **Step 1: 호출부 교체**

```swift
        if case .available(let release) = updateChecker.status, case .idle = autoUpdater.state {
            if release.zipAsset != nil, release.signatureAsset != nil {
                Button {
                    autoUpdater.startUpdate(release: release)
                } label: {
```

(나머지 라벨/스타일은 그대로. `else` 분기의 "릴리즈 열기" 버튼이 서명 없는 릴리스를 받는다.)

- [ ] **Step 2: 빌드 + 전체 테스트**

Run: 전체 `xcodebuild … test`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: 실기 확인(선택, 릴리스 전 1회)**

`scripts/build_release.sh`로 만든 zip+sig를 테스트 릴리스에 올리고, 이전 버전 앱에서 "지금 업데이트"를 눌러 `.verifying → .extracting → 재실행`을 눈으로 확인한다. `.sig`를 빼고 올리면 버튼이 "릴리즈 열기"로 바뀌는지도 본다.

- [ ] **Step 4: Commit**

```bash
git add Wattly/Views/SettingsView.swift
git commit -m "feat(update): only offer in-app update for signed releases"
```

---

### Task 8: README의 "서명된 .dmg" 문구 정정

**Files:**
- Modify: `README.md:314` (그리고 `README.en.md`의 대응 줄)

- [ ] **Step 1: 문구 교체** — "서명된 최신 .dmg"를 "최신 .dmg(현재는 ad-hoc 서명이라 처음 열 때 Gatekeeper 경고가 뜹니다; 자동 업데이트는 릴리스 서명으로 검증됩니다)"로 바꾼다. 영문 README도 같은 뜻으로.

- [ ] **Step 2: Commit**

```bash
git add README.md README.en.md
git commit -m "docs: describe ad-hoc signing and release signature verification honestly"
```

---

## Self-Review

- **Spec coverage:** Critical(호스트 제한·서명·번들 ID·버전 → Task 2/6; `rm -rf` 후 `ditto` → Task 5; quarantine은 명시적으로 6단계 이월) ✔. Medium `cancel()` → Task 6 `runID` ✔. README L3 → Task 8 ✔.
- **Placeholder scan:** `UpdateSigningKey.publicKeyBase64 = ""`는 스텁이 아니라 Task 3 Step 5가 채우는 값이며, 빈 채로는 테스트가 실패한다 ✔.
- **Type consistency:** `UpdateVerifier.verify(archive:signatureBase64:publicKey:)`가 Task 2 정의·Task 6 호출에서 동일. `AppReplacer.arguments(script:currentAppURL:newAppURL:currentPID:)` 동일. `MockURLProtocol.makeConfiguration()` Task 1 정의·Task 6 사용 동일 ✔.
