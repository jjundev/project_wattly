# Developer ID 서명 + 코드 서명 요구사항 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 앱과 데몬을 하나의 Developer ID로 서명·공증하고, 그 신원을 (1) 데몬의 XPC 접속 검사, (2) 설치 스크립트의 바이너리 검증, (3) 앱의 데몬 연결 검사에 요구사항 문자열로 쓴다. 그 결과 basename 인증, 설치 전 바꿔치기 창, quarantine 제거, README의 "서명됨" 불일치가 모두 사라진다.

**Architecture:** 요구사항 문자열은 순수 `CodeSigningRequirement`(FanControlShared)가 만든다. 팀 ID는 `SigningIdentity.teamIdentifier` 상수 한 곳에만 있고, 테스트가 채워졌는지 강제한다. `project.yml`은 Developer ID + hardened runtime + 타임스탬프로 바꾸고, 임베드된 데몬도 서명한다. 릴리스 스크립트는 `notarytool` 제출 → `stapler` → zip 재생성 → Ed25519 서명(1단계) 순서다. `AppReplacer`에서 `xattr -dr`를 뺀다.

**Tech Stack:** XcodeGen, `codesign`, `xcrun notarytool`, `xcrun stapler`, `NSXPCConnection.setCodeSigningRequirement`, Swift Testing.

**Spec:** 감사 보고서 §1 High("XPC 접속자 인증이 UID + basename"), §5 6번 항목, 2단계 계획의 "남는 한계" — https://claude.ai/code/artifact/20a3c5b7-ad33-4ec3-ae78-288a0259454d

## Global Constraints

- 선행: 유료 Apple Developer Program 계정, "Developer ID Application" 인증서가 로그인 키체인에 있음, `xcrun notarytool store-credentials wattly-notary`로 저장된 키체인 프로필. 없으면 이 계획은 시작하지 않는다.
- 선행: 1단계(릴리스 서명 스크립트)와 2단계(스테이징 설치 스크립트)가 병합됨.
- `project.yml`이 프로젝트의 source of truth다. 수정 후 반드시 `xcodegen generate`.
- 팀 ID(10자 영숫자)는 `WattlyFanDaemon`과 앱 양쪽에서 컴파일되는 `FanControlShared/SigningIdentity.swift` 한 곳에만 둔다.
- 요구사항 문자열 형식: `anchor apple generic and identifier "<bundle id>" and certificate leaf[subject.OU] = "<TEAMID>"` — Developer ID Application 인증서의 표준 designated requirement에서 `certificate 1[field…]` 절을 생략한 축약형이며 `codesign -d -r-`로 확인한다.
- Swift 6 strict concurrency, macOS 14.0.

---

## 파일 구조

| 파일 | 책임 |
|------|------|
| `FanControlShared/SigningIdentity.swift` (신규) | `teamIdentifier`, 앱/데몬 번들 ID 상수. |
| `FanControlShared/CodeSigningRequirement.swift` (신규) | 순수 요구사항 문자열 생성. |
| `project.yml` (수정) | 서명 설정. |
| `WattlyFanDaemon/FanControlDaemon.swift:66-72, 311-324` (수정) | `setCodeSigningRequirement`, basename 검사 삭제. |
| `Wattly/Control/BatteryControlClient.swift:544-547`, `Wattly/Control/FanControlClient.swift:115-119` (수정) | 앱 → 데몬 요구사항. |
| `Wattly/Control/FanHelperInstaller.swift` (수정) | 스크립트에 `codesign --verify -R`. |
| `scripts/build_release.sh`, `scripts/make-dmg.sh` (수정) | 공증·스테이플. |
| `Wattly/Core/AppReplacer.swift`, `WattlyTests/AppReplacerTests.swift` (수정) | quarantine 제거 삭제. |
| `README.md`, `README.en.md`, `docs/fan-control-local-install.md` (수정) | |
| `WattlyTests/CodeSigningRequirementTests.swift` (신규) | |

---

### Task 1: `SigningIdentity`와 `CodeSigningRequirement`

**Files:**
- Create: `FanControlShared/SigningIdentity.swift`, `FanControlShared/CodeSigningRequirement.swift`
- Create: `WattlyTests/CodeSigningRequirementTests.swift`

**Interfaces:**
- Produces:
  - `public enum SigningIdentity { public static let teamIdentifier: String; public static let appBundleIdentifier = "dev.jjundev.Wattly"; public static let daemonBundleIdentifier = "dev.jjundev.WattlyFanDaemon" }`
  - `public enum CodeSigningRequirement { public static func designated(identifier: String, teamIdentifier: String) -> String; public static var app: String; public static var daemon: String }`

- [ ] **Step 1: 실패하는 테스트**

```swift
// WattlyTests/CodeSigningRequirementTests.swift
import Testing
@testable import Wattly

@Suite struct CodeSigningRequirementTests {
    @Test func requirementNamesTheIdentifierAndTeam() {
        let r = CodeSigningRequirement.designated(identifier: "dev.jjundev.Wattly", teamIdentifier: "ABCDE12345")
        #expect(r == "anchor apple generic and identifier \"dev.jjundev.Wattly\" and certificate leaf[subject.OU] = \"ABCDE12345\"")
    }

    /// 팀 ID를 채우기 전까지 빨갛다. 빈 값으로 출하하면 데몬이 모든 접속을 거부한다.
    @Test func teamIdentifierIsConfigured() {
        #expect(SigningIdentity.teamIdentifier.count == 10)
        #expect(SigningIdentity.teamIdentifier.allSatisfy { $0.isLetter || $0.isNumber })
        #expect(CodeSigningRequirement.app.contains(SigningIdentity.teamIdentifier))
        #expect(CodeSigningRequirement.daemon.contains("dev.jjundev.WattlyFanDaemon"))
    }
}
```

- [ ] **Step 2: 실패 확인** — Expected: 컴파일 실패.

- [ ] **Step 3: 구현**

```swift
// FanControlShared/SigningIdentity.swift
import Foundation

/// 서명 신원. 앱·데몬 양쪽에 컴파일된다. 팀 ID는 Apple Developer 계정의 Membership 페이지에 있는 10자 값이며
/// `codesign -dvv Wattly.app 2>&1 | grep TeamIdentifier`로도 확인한다.
public enum SigningIdentity {
    public static let teamIdentifier = ""
    public static let appBundleIdentifier = "dev.jjundev.Wattly"
    public static let daemonBundleIdentifier = "dev.jjundev.WattlyFanDaemon"
}
```

```swift
// FanControlShared/CodeSigningRequirement.swift
import Foundation

/// `NSXPCConnection.setCodeSigningRequirement`와 `codesign --verify -R`에 넣는 요구사항 언어 문자열.
/// 순수 함수 — 형식이 바뀌면 세 소비자(데몬 리스너, 앱 클라이언트, 설치 스크립트)가 같이 바뀐다.
public enum CodeSigningRequirement {
    public static func designated(identifier: String, teamIdentifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    /// 데몬이 접속자(앱)에게 요구하는 것.
    public static var app: String {
        designated(identifier: SigningIdentity.appBundleIdentifier, teamIdentifier: SigningIdentity.teamIdentifier)
    }

    /// 앱이 데몬에게, 설치 스크립트가 스테이징된 바이너리에게 요구하는 것.
    public static var daemon: String {
        designated(identifier: SigningIdentity.daemonBundleIdentifier, teamIdentifier: SigningIdentity.teamIdentifier)
    }
}
```

- [ ] **Step 4: 팀 ID 채우기** — `SigningIdentity.teamIdentifier`에 실제 10자 팀 ID를 넣는다. Run: `… -only-testing:WattlyTests/CodeSigningRequirementTests` — Expected: 2개 PASS.

- [ ] **Step 5: Commit**

```bash
git add FanControlShared/SigningIdentity.swift FanControlShared/CodeSigningRequirement.swift WattlyTests/CodeSigningRequirementTests.swift
git commit -m "feat(signing): add signing identity constants and code-signing requirement strings"
```

---

### Task 2: `project.yml` — Developer ID, hardened runtime, 임베드 데몬 서명

**Files:**
- Modify: `project.yml:13-19, 45-55`

- [ ] **Step 1: 설정 교체** — `settings.base`의 서명 4줄을:

```yaml
    CODE_SIGN_IDENTITY: "Developer ID Application"
    CODE_SIGN_STYLE: Manual
    DEVELOPMENT_TEAM: "ABCDE12345"      # SigningIdentity.teamIdentifier와 같은 값
    ENABLE_HARDENED_RUNTIME: YES
    OTHER_CODE_SIGN_FLAGS: "--timestamp --options runtime"
    ENABLE_USER_SCRIPT_SANDBOXING: NO
```

앱 타깃의 데몬 임베드 의존성에서 `codeSign: false`를 `codeSign: true`로 바꾼다(주석도 "signed on copy so the embedded helper carries the same Developer ID" 로).

- [ ] **Step 2: 프로젝트 재생성 + Release 빌드 + 서명 확인**

```bash
xcodegen generate && xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Release -destination 'platform=macOS' -derivedDataPath .build/DerivedData build 2>&1 | tail -3
codesign -dvv .build/DerivedData/Build/Products/Release/Wattly.app 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier|Runtime"
codesign -dvv .build/DerivedData/Build/Products/Release/Wattly.app/Contents/Helpers/WattlyFanDaemon 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier|Identifier="
codesign --verify --strict --deep .build/DerivedData/Build/Products/Release/Wattly.app && echo VERIFIED
```

Expected: 앱·데몬 모두 `Authority=Developer ID Application: …`, `TeamIdentifier=<팀 ID>`, `Runtime Version`, 데몬 `Identifier=dev.jjundev.WattlyFanDaemon`, 마지막 줄 `VERIFIED`.

- [ ] **Step 3: 앱 실기 확인** — Release 앱을 실행해 텔레메트리(IOReport `dlopen`, SMC 읽기, `proc_pid_rusage`)가 hardened runtime 아래서도 동작하는지 팝오버로 확인한다. 실패하는 항목이 있으면 그 API에 필요한 entitlement를 `Wattly/Wattly.entitlements`로 추가하고 `project.yml`의 앱 타깃에 `CODE_SIGN_ENTITLEMENTS: Wattly/Wattly.entitlements`를 넣는다(현재 파악된 API에는 필요 없다).

- [ ] **Step 4: Commit**

```bash
git add project.yml Wattly.xcodeproj/project.pbxproj
git commit -m "build: sign app and embedded daemon with Developer ID under hardened runtime"
```

---

### Task 3: 데몬 리스너에 코드 서명 요구사항

**Files:**
- Modify: `WattlyFanDaemon/FanControlDaemon.swift:66-72, 311-324`

- [ ] **Step 1: 구현** — `listener(_:shouldAcceptNewConnection:)`을:

```swift
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // uid는 정책(어느 사용자의 도우미인가), 서명은 신원(정말 Wattly인가). 둘 다 필요하다.
        guard connection.effectiveUserIdentifier == allowedUID else { return false }
        do {
            try connection.setCodeSigningRequirement(CodeSigningRequirement.app)
        } catch {
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: FanControlXPCService.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
```

`isAllowedClient(_:)` 메서드(311-324행)를 삭제한다. `proc_pidpath` 관련 import가 다른 곳에 안 쓰이면 그대로 둬도 된다(Darwin).

- [ ] **Step 2: 실기 확인(핵심)**

1. 2단계 설치 경로로 도우미를 재설치한다(새 Developer ID 서명 데몬).
2. 앱에서 충전 한도를 켜서 정상 동작 확인.
3. 스푸핑 시도: `cp /bin/true /tmp/Wattly && /tmp/Wattly` 같은 단순 실행은 XPC 클라이언트가 아니므로, 대신 Debug 빌드(ad-hoc)의 Wattly.app을 실행해 설정에서 상태를 본다 → 도우미 "연결 안 됨"이어야 한다. `log stream --predicate 'process == "WattlyFanDaemon"'`에는 오류가 남지 않는다(요구사항 실패는 조용히 거부된다).

- [ ] **Step 3: Commit**

```bash
git add WattlyFanDaemon/FanControlDaemon.swift
git commit -m "fix(daemon): require the app's Developer ID signature on XPC connections"
```

---

### Task 4: 앱 → 데몬 연결에도 요구사항, 설치 스크립트에 `codesign --verify`

**Files:**
- Modify: `Wattly/Control/BatteryControlClient.swift:544-547`, `Wattly/Control/FanControlClient.swift:115-119`
- Modify: `Wattly/Control/FanHelperInstaller.swift` (`makeInstallScript` 시그니처에 `codeSigningRequirement:` 추가), `install()` 호출부
- Test: `WattlyTests/FanHelperInstallerScriptTests.swift`, `WattlyTests/BatteryControlClientTests.swift`(호출부 라벨)

- [ ] **Step 1: 실패하는 테스트** — `FanHelperInstallerScriptTests`에 추가:

```swift
    @Test func installScriptVerifiesTheStagedDaemonSignatureAfterTheHash() {
        let script = FanHelperInstaller.makeInstallScript(
            daemonPath: "/x/WattlyFanDaemon",
            expectedSHA256: String(repeating: "a", count: 64),
            codeSigningRequirement: "anchor apple generic and identifier \"dev.jjundev.WattlyFanDaemon\"",
            currentUID: 501)
        let hash = script.range(of: "shasum -a 256")!.lowerBound
        let verify = script.range(of: "/usr/bin/codesign --verify --strict -R \"$requirement\" \"$staged_daemon\"")!.lowerBound
        let run = script.range(of: "\"$staged_daemon\" --verify-battery-release")!.lowerBound
        #expect(hash < verify && verify < run)
        #expect(script.contains("requirement='anchor apple generic and identifier \"dev.jjundev.WattlyFanDaemon\"'"))
    }
```

- [ ] **Step 2: 실패 확인** — Expected: 컴파일 실패.

- [ ] **Step 3: 스크립트 수정** — `makeInstallScript`에 `codeSigningRequirement: String = CodeSigningRequirement.daemon` 파라미터를 `expectedSHA256:` 다음에 추가하고, 변수 선언에 `requirement=\(shellQuoted(codeSigningRequirement))`를, 해시 비교 블록 바로 뒤에:

```
        if ! /usr/bin/codesign --verify --strict -R "$requirement" "$staged_daemon"; then
          echo 'Staged helper is not signed with the expected Developer ID; aborting.' >&2
          exit 77
        fi
```

`install()`의 호출은 기본값을 쓰므로 바뀌지 않는다. `BatteryControlClientTests`의 `makeInstallScript(` 호출은 기본값으로 컴파일된다.

- [ ] **Step 4: 클라이언트 연결** — `BatteryControlClient.sendXPC`와 `FanControlClient.request`의 `connection.resume()` 직전에:

```swift
            try? connection.setCodeSigningRequirement(CodeSigningRequirement.daemon)
```

(`try?`인 이유: 요구사항 문자열이 파싱되지 않는 경우는 프로그래밍 오류이고, 그때는 요구사항 없이 연결되는 것보다 실패하는 편이 낫지만 여기서 예외를 던질 수 없다. 테스트 `teamIdentifierIsConfigured`가 형식을 보증한다.)

- [ ] **Step 5: 통과 확인** — Run: `… -only-testing:WattlyTests/FanHelperInstallerScriptTests`, `… -only-testing:WattlyTests/BatteryControlClientTests`, `… -only-testing:WattlyTests/FanControlClientTests` — Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Wattly/Control/BatteryControlClient.swift Wattly/Control/FanControlClient.swift Wattly/Control/FanHelperInstaller.swift WattlyTests/FanHelperInstallerScriptTests.swift
git commit -m "fix(helper): verify the daemon's Developer ID before installing and when connecting"
```

---

### Task 5: 공증 + 스테이플 + quarantine 제거 삭제

**Files:**
- Modify: `scripts/build_release.sh`, `scripts/make-dmg.sh`
- Modify: `Wattly/Core/AppReplacer.swift`, `WattlyTests/AppReplacerTests.swift`

- [ ] **Step 1: `build_release.sh`** — zip 생성 단계를 다음으로 교체(Ed25519 서명 단계는 그 뒤 그대로):

```bash
NOTARY_PROFILE="${WATTLY_NOTARY_PROFILE:-wattly-notary}"
echo "==> Verifying signature..."
codesign --verify --strict --deep "$APP_PATH"
echo "==> Notarizing..."
NOTARY_ZIP="$OUTPUT_DIR/Wattly-notary.zip"
rm -f "$NOTARY_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$NOTARY_ZIP"
echo "==> Stapling..."
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
echo "==> Creating $ZIP_PATH..."
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
```

`make-dmg.sh`의 `hdiutil create` 뒤에:

```zsh
xcrun notarytool submit "$out" --keychain-profile "${WATTLY_NOTARY_PROFILE:-wattly-notary}" --wait
xcrun stapler staple "$out"
```

- [ ] **Step 2: `AppReplacer.replaceScript`에서 `xattr -dr com.apple.quarantine "$current" 2>/dev/null || true` 줄과 그 주석을 삭제.** `AppReplacerTests.pathsTravelAsArgumentsNotAsScriptText`에 `#expect(!AppReplacer.relaunchScript.contains("xattr"))`를 추가.

- [ ] **Step 3: 확인**

Run: `… -only-testing:WattlyTests/AppReplacerTests` — Expected: PASS.
Run: `scripts/build_release.sh` — Expected: 공증 `status: Accepted`, `stapler validate` 성공, zip + sig 생성. 다른 Mac(또는 새 사용자)에서 zip을 받아 열었을 때 Gatekeeper 경고 없이 실행.

- [ ] **Step 4: Commit**

```bash
git add scripts/build_release.sh scripts/make-dmg.sh Wattly/Core/AppReplacer.swift WattlyTests/AppReplacerTests.swift
git commit -m "build: notarize and staple releases; stop stripping quarantine on update"
```

---

### Task 6: 문서

**Files:**
- Modify: `README.md`, `README.en.md`, `docs/fan-control-local-install.md`

- [ ] **Step 1: README** — 1단계 Task 8에서 바꾼 문구를 "Developer ID로 서명·공증된 최신 .dmg"로 되돌리고, 설치 절의 Gatekeeper 우회 안내(우클릭 → 열기 등)가 있으면 삭제한다.

- [ ] **Step 2: `docs/fan-control-local-install.md`** — "Authorization limitation" 절을 다음으로 교체:

```markdown
### Authorization

The daemon accepts an XPC connection only when the peer's effective uid matches `WATTLY_ALLOWED_UID`
**and** the peer satisfies `anchor apple generic and identifier "dev.jjundev.Wattly" and certificate
leaf[subject.OU] = "<TEAMID>"` (`CodeSigningRequirement.app`). A same-user binary merely named `Wattly`
is refused. The installer verifies the staged daemon against `CodeSigningRequirement.daemon` before
running it as root, and the app verifies the daemon on every connection. Local ad-hoc builds cannot talk
to a Developer ID daemon; use `scripts/install-fan-helper.sh` from the same build for development.
```

2단계 Task 5에서 추가한 "Install-time integrity" 절의 마지막 문단("It does NOT close…")은 삭제한다 — 이제 닫혔다.

- [ ] **Step 3: Commit**

```bash
git add README.md README.en.md docs/fan-control-local-install.md
git commit -m "docs: describe Developer ID signing, notarization and XPC code-signing requirements"
```

---

## Self-Review

- **Spec coverage:** basename 인증 → Task 3 ✔. 설치 전 바꿔치기 창 → Task 4 `codesign --verify` ✔. quarantine 제거 → Task 5 ✔. README 불일치 → Task 6 ✔.
- **Placeholder scan:** `SigningIdentity.teamIdentifier = ""`와 `DEVELOPMENT_TEAM: "ABCDE12345"`는 계정에서 얻는 실제 값으로 Task 1 Step 4·Task 2 Step 1이 채우며, 빈 값은 테스트가 잡는다. `wattly-notary` 프로필은 Global Constraints의 선행 조건이다.
- **Type consistency:** `CodeSigningRequirement.app/daemon` Task 1 정의·Task 3·4 사용 일치. `makeInstallScript(daemonPath:expectedSHA256:codeSigningRequirement:currentUID:transferringOwnership:)` Task 4 정의·테스트 일치(2단계 시그니처에 파라미터 하나 추가) ✔.
