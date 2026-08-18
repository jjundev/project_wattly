# Contact Developer ("개발자에게 문의하기") Implementation Plan (Browser Webmail)

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "개발자에게 문의하기" (Contact Developer) row to the "일반" (General) settings section in `SettingsView`, opening the Gmail web compose interface in the user's default browser targeting `jjundev@gmail.com` with pre-filled diagnostics (app version, macOS version, hardware model) and providing clipboard copy fallback.

**Architecture:** A standalone `ContactDeveloperHelper` model constructs Gmail web compose URLs (`https://mail.google.com/mail/?view=cm&fs=1&to=...&su=...&body=...`) containing pre-formatted system telemetry and provides safe clipboard fallback logic. Localization strings are registered in `Localizable.xcstrings` for all 31 supported languages and covered by `LocalizationTests`. `SettingsView` hosts the new row in `generalGroup` following Wattly's native design system tokens (`SettingsCard`, `WattlyFont`, `Tokens`).

**Tech Stack:** Swift 6, SwiftUI, Swift Testing framework (`@Test`, `#expect`), AppKit (`NSWorkspace`, `NSPasteboard`, `ProcessInfo`), XcodeGen (`xcodegen generate`).

## Global Constraints

- **Developer Email Address:** Must be exactly `jjundev@gmail.com`.
- **Browser Webmail Mode (Option A):** Use Gmail Web Compose URL (`https://mail.google.com/mail/?view=cm&fs=1&to=jjundev@gmail.com&su=...&body=...`) opened in the default browser via `NSWorkspace.shared.open`.
- **Pure logic isolation:** URL construction and system diagnostic formatting must be decoupled from UI and fully unit-tested with Swift Testing.
- **Defensive fallback:** If the system cannot launch the browser or URL creation fails, the email `jjundev@gmail.com` must be copied to `NSPasteboard.general`.
- **Project generation:** Execute `xcodegen generate` whenever new Swift files or tests are created.
- **Design System alignment:** UI elements in `SettingsView` must use `WattlyFont`, `Tokens`, `SettingsCard`, and existing component styles.
- **Swift 6 Strict Concurrency:** Helper functions and types must conform to `Sendable` and `@MainActor` as appropriate.
- **Test execution command:** `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData`

---

### Task 1: Contact Developer Helper Model & Tests (`ContactDeveloperHelper`)

**Files:**
- Create: `Wattly/Core/ContactDeveloperHelper.swift`
- Create: `WattlyTests/ContactDeveloperHelperTests.swift`

**Interfaces:**
- Consumes: `Bundle.main.infoDictionary`, `ProcessInfo.processInfo`, `currentHardwareModel()`
- Produces:
  - `enum ContactDeveloperHelper: Sendable` with:
    - `static let email: String` (`"jjundev@gmail.com"`)
    - `static let defaultSubject: String` (`"[Wattly] 문의 및 피드백"`)
    - `static func generateDiagnosticBody(version:build:osVersion:hardwareModel:) -> String`
    - `static func buildGmailWebComposeURL(email:subject:body:) -> URL?`
    - `static func copyEmailToClipboard(email:pasteboard:)`
    - `@MainActor static func openContactEmailInBrowser(email:subject:body:workspace:pasteboard:) -> Bool`

- [ ] **Step 1: Write the failing unit tests**

Create `WattlyTests/ContactDeveloperHelperTests.swift`:
```swift
import Testing
import Foundation
import AppKit
@testable import Wattly

@Suite struct ContactDeveloperHelperTests {
    @Test func emailAddressMatchesRequirement() {
        #expect(ContactDeveloperHelper.email == "jjundev@gmail.com")
    }

    @Test func diagnosticBodyContainsVersionAndSystemInfo() {
        let body = ContactDeveloperHelper.generateDiagnosticBody(
            version: "1.0.2",
            build: "3",
            osVersion: "macOS 14.5",
            hardwareModel: "Mac14,2"
        )
        #expect(body.contains("Wattly Version: v1.0.2 (3)"))
        #expect(body.contains("macOS: macOS 14.5"))
        #expect(body.contains("Hardware Model: Mac14,2"))
    }

    @Test func buildGmailWebComposeURLConstructsValidURL() {
        let url = ContactDeveloperHelper.buildGmailWebComposeURL(
            email: "jjundev@gmail.com",
            subject: "[Wattly] Feedback",
            body: "Test Body"
        )
        #expect(url != nil)
        #expect(url?.scheme == "https")
        #expect(url?.host == "mail.google.com")
        let absoluteString = url?.absoluteString ?? ""
        #expect(absoluteString.contains("view=cm"))
        #expect(absoluteString.contains("fs=1"))
        #expect(absoluteString.contains("to=jjundev@gmail.com"))
        #expect(absoluteString.contains("su=%5BWattly%5D%20Feedback"))
        #expect(absoluteString.contains("body=Test%20Body"))
    }

    @Test func copyEmailToClipboardSetsPasteboard() {
        let pb = NSPasteboard.withUniqueName()
        ContactDeveloperHelper.copyEmailToClipboard(email: "jjundev@gmail.com", pasteboard: pb)
        #expect(pb.string(forType: .string) == "jjundev@gmail.com")
    }
}
```

- [ ] **Step 2: Regenerate Xcode project & run test to verify it fails**

Run: `xcodegen generate && xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/ContactDeveloperHelperTests`
Expected: FAIL with "cannot find 'ContactDeveloperHelper' in scope".

- [ ] **Step 3: Implement `ContactDeveloperHelper.swift`**

Create `Wattly/Core/ContactDeveloperHelper.swift`:
```swift
import Foundation
import AppKit

public enum ContactDeveloperHelper: Sendable {
    public static let email = "jjundev@gmail.com"
    public static let defaultSubject = "[Wattly] 문의 및 피드백"

    public static func generateDiagnosticBody(
        version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
        build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1",
        osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        hardwareModel: String = currentHardwareModel()
    ) -> String {
        """
        
        
        --------------------
        • Wattly Version: v\(version) (\(build))
        • macOS: \(osVersion)
        • Hardware Model: \(hardwareModel.isEmpty ? "Unknown" : hardwareModel)
        --------------------
        """
    }

    public static func buildGmailWebComposeURL(
        email: String = email,
        subject: String = defaultSubject,
        body: String? = nil
    ) -> URL? {
        var components = URLComponents(string: "https://mail.google.com/mail/")
        var queryItems = [
            URLQueryItem(name: "view", value: "cm"),
            URLQueryItem(name: "fs", value: "1"),
            URLQueryItem(name: "to", value: email)
        ]
        if !subject.isEmpty {
            queryItems.append(URLQueryItem(name: "su", value: subject))
        }
        let mailBody = body ?? generateDiagnosticBody()
        if !mailBody.isEmpty {
            queryItems.append(URLQueryItem(name: "body", value: mailBody))
        }
        components?.queryItems = queryItems
        return components?.url
    }

    @discardableResult
    @MainActor
    public static func openContactEmailInBrowser(
        email: String = email,
        subject: String = defaultSubject,
        body: String? = nil,
        workspace: NSWorkspace = .shared,
        pasteboard: NSPasteboard = .general
    ) -> Bool {
        guard let url = buildGmailWebComposeURL(email: email, subject: subject, body: body) else {
            copyEmailToClipboard(email: email, pasteboard: pasteboard)
            return false
        }

        let opened = workspace.open(url)
        if !opened {
            copyEmailToClipboard(email: email, pasteboard: pasteboard)
        }
        return opened
    }

    public static func copyEmailToClipboard(
        email: String = email,
        pasteboard: NSPasteboard = .general
    ) {
        pasteboard.clearContents()
        pasteboard.setString(email, forType: .string)
    }
}
```

- [ ] **Step 4: Regenerate Xcode project & run test to verify it passes**

Run: `xcodegen generate && xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/ContactDeveloperHelperTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/ContactDeveloperHelper.swift WattlyTests/ContactDeveloperHelperTests.swift
git commit -m "feat(contact): add ContactDeveloperHelper with Gmail web compose URL and tests"
```

---

### Task 2: Multi-Language String Catalog Localization (`Localizable.xcstrings` & `LocalizationTests`)

**Files:**
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Modify: `WattlyTests/LocalizationTests.swift`

**Interfaces:**
- Produces: Localization entries for `"개발자에게 문의하기"` and `"문의하기"` across all 31 supported languages.

- [ ] **Step 1: Add localization test assertions**

In `WattlyTests/LocalizationTests.swift`, add:
```swift
    @Test func contactDeveloperTranslations() {
        #expect(String(localized: "개발자에게 문의하기", locale: Locale(identifier: "en")) == "Contact Developer")
        #expect(String(localized: "개발자에게 문의하기", locale: Locale(identifier: "ja")) == "開発者に問い合わせ")
        #expect(String(localized: "개발자에게 문의하기", locale: Locale(identifier: "zh-Hans")) == "联系开发者")
        #expect(String(localized: "개발자에게 문의하기", locale: Locale(identifier: "zh-Hant")) == "聯絡開發者")
        #expect(String(localized: "개발자에게 문의하기", locale: Locale(identifier: "de")) == "Entwickler kontaktieren")
        #expect(String(localized: "개발자에게 문의하기", locale: Locale(identifier: "fr")) == "Contacter le développeur")
        #expect(String(localized: "개발자에게 문의하기", locale: Locale(identifier: "es")) == "Contactar al desarrollador")

        #expect(String(localized: "문의하기", locale: Locale(identifier: "en")) == "Contact")
        #expect(String(localized: "문의하기", locale: Locale(identifier: "ja")) == "問い合わせ")
        #expect(String(localized: "문의하기", locale: Locale(identifier: "zh-Hans")) == "联系")
        #expect(String(localized: "문의하기", locale: Locale(identifier: "zh-Hant")) == "聯絡")
        #expect(String(localized: "문의하기", locale: Locale(identifier: "de")) == "Kontaktieren")
        #expect(String(localized: "문의하기", locale: Locale(identifier: "fr")) == "Contacter")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/LocalizationTests`
Expected: FAIL due to missing translations.

- [ ] **Step 3: Update `Localizable.xcstrings`**

Add JSON entries for `"개발자에게 문의하기"` and `"문의하기"` covering all 31 supported languages in `Wattly/Resources/Localizable.xcstrings`.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/LocalizationTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Resources/Localizable.xcstrings WattlyTests/LocalizationTests.swift
git commit -m "feat(i18n): add 31-language localizations for contact developer"
```

---

### Task 3: Settings View UI Integration (`SettingsView.swift`)

**Files:**
- Modify: `Wattly/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `ContactDeveloperHelper`, `Tokens`, `WattlyFont`, `SettingsRowTitle`
- Produces: Contact Developer row in `generalGroup` with email address label and contact action button.

- [ ] **Step 1: Add Contact Developer row to `SettingsView.swift`**

In `Wattly/Views/SettingsView.swift`, inside `generalGroup` (immediately following the software update row and its divider line):

```swift
                // 개발자에게 문의하기
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        SettingsRowTitle("개발자에게 문의하기")
                        Text(ContactDeveloperHelper.email)
                            .font(WattlyFont.at(11.5, weight: .regular))
                            .foregroundStyle(t.faint)
                    }

                    Spacer(minLength: 8)

                    Button {
                        ContactDeveloperHelper.openContactEmailInBrowser()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "envelope")
                                .font(.system(size: 11, weight: .medium))
                            Text("문의하기")
                                .font(WattlyFont.at(12, weight: .medium))
                                .foregroundStyle(t.text)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(t.segTrack))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.rowBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))

                Rectangle().fill(t.line).frame(height: 1)
```

- [ ] **Step 2: Run full test suite to verify no regressions**

Run: `xcodegen generate && xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData`
Expected: PASS with 0 failures across all test suites.

- [ ] **Step 3: Commit**

```bash
git add Wattly/Views/SettingsView.swift
git commit -m "feat(settings): add contact developer row opening Gmail webmail in browser"
```
