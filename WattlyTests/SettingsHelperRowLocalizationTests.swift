import Testing
import Foundation
@testable import Wattly

@Suite("SettingsHelperRowLocalizationTests")
struct SettingsHelperRowLocalizationTests {

    private final class TestBundleAnchor {}

    private static let appBundle: Bundle? = {
        for b in Bundle.allBundles {
            if b.bundleIdentifier == "dev.jjundev.Wattly" {
                return b
            }
        }
        let testBundleURL = Bundle(for: TestBundleAnchor.self).bundleURL
        // When running in PlugIns/WattlyTests.xctest inside Wattly.app:
        let insideAppURL = testBundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if let bundle = Bundle(url: insideAppURL), bundle.bundleIdentifier == "dev.jjundev.Wattly" {
            return bundle
        }
        // When running in BUILT_PRODUCTS_DIR alongside Wattly.app:
        let siblingAppURL = testBundleURL.deletingLastPathComponent().appendingPathComponent("Wattly.app")
        if let bundle = Bundle(url: siblingAppURL), bundle.bundleIdentifier == "dev.jjundev.Wattly" {
            return bundle
        }
        return nil
    }()

    private static func localized(_ key: String, in locale: String) -> String {
        guard let bundle = appBundle,
              let path = bundle.path(forResource: locale, ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else {
            return key
        }
        return localizedBundle.localizedString(forKey: key, value: nil, table: nil)
    }

    // MARK: - Helper Status Localization Tests

    @Test func helperStatusCheckingLocalization() {
        let key = "확인 중…"
        let en = Self.localized(key, in: "en")
        let ja = Self.localized(key, in: "ja")
        let de = Self.localized(key, in: "de")
        let fr = Self.localized(key, in: "fr")
        let ko = Self.localized(key, in: "ko")

        #expect(!en.isEmpty)
        #expect(en == "Checking…")
        #expect(!ja.isEmpty)
        #expect(ja == "確認中…")
        #expect(!de.isEmpty)
        #expect(de == "Wird gesucht…")
        #expect(!fr.isEmpty)
        #expect(fr == "Vérification…")
        #expect(!ko.isEmpty)
        #expect(ko == "확인 중…")
    }

    @Test func helperStatusInstallingLocalization() {
        let key = "도우미 설치 중…"
        let en = Self.localized(key, in: "en")
        let ja = Self.localized(key, in: "ja")
        let de = Self.localized(key, in: "de")
        let fr = Self.localized(key, in: "fr")
        let ko = Self.localized(key, in: "ko")

        #expect(!en.isEmpty)
        #expect(en == "Installing helper…")
        #expect(!ja.isEmpty)
        #expect(ja == "ヘルパーをインストール中…")
        #expect(!de.isEmpty)
        #expect(de == "Helfer wird installiert…")
        #expect(!fr.isEmpty)
        #expect(fr == "Installation de l'assistant…")
        #expect(!ko.isEmpty)
        #expect(ko == "도우미 설치 중…")
    }

    @Test func helperStatusOperatingNormallyLocalization() {
        let key = "정상 작동 중"
        let en = Self.localized(key, in: "en")
        let ja = Self.localized(key, in: "ja")
        let de = Self.localized(key, in: "de")
        let fr = Self.localized(key, in: "fr")
        let ko = Self.localized(key, in: "ko")

        #expect(!en.isEmpty)
        #expect(en == "Operating Normally")
        #expect(!ja.isEmpty)
        #expect(ja == "正常に動作中")
        #expect(!de.isEmpty)
        #expect(de == "Normaler Betrieb")
        #expect(!fr.isEmpty)
        #expect(fr == "Fonctionnement normal")
        #expect(!ko.isEmpty)
        #expect(ko == "정상 작동 중")
    }

    @Test func helperStatusUpdateRequiredLocalization() {
        let key = "업데이트 필요"
        let en = Self.localized(key, in: "en")
        let ja = Self.localized(key, in: "ja")
        let de = Self.localized(key, in: "de")
        let fr = Self.localized(key, in: "fr")
        let ko = Self.localized(key, in: "ko")

        #expect(!en.isEmpty)
        #expect(en == "Update Required")
        #expect(!ja.isEmpty)
        #expect(ja == "更新が必要")
        #expect(!de.isEmpty)
        #expect(de == "Update erforderlich")
        #expect(!fr.isEmpty)
        #expect(fr == "Mise à jour requise")
        #expect(!ko.isEmpty)
        #expect(ko == "업데이트 필요")
    }

    @Test func helperStatusNotInstalledLocalization() {
        let key = "미설치"
        let en = Self.localized(key, in: "en")
        let ja = Self.localized(key, in: "ja")
        let de = Self.localized(key, in: "de")
        let fr = Self.localized(key, in: "fr")
        let ko = Self.localized(key, in: "ko")

        #expect(!en.isEmpty)
        #expect(en == "Not Installed")
        #expect(!ja.isEmpty)
        #expect(ja == "未インストール")
        #expect(!de.isEmpty)
        #expect(de == "Nicht installiert")
        #expect(!fr.isEmpty)
        #expect(fr == "Non installé")
        #expect(!ko.isEmpty)
        #expect(ko == "미설치")
    }

    @Test func helperStatusUnavailableLocalization() {
        let key = "응답 없음"
        let en = Self.localized(key, in: "en")
        let ja = Self.localized(key, in: "ja")
        let de = Self.localized(key, in: "de")
        let fr = Self.localized(key, in: "fr")
        let ko = Self.localized(key, in: "ko")

        #expect(!en.isEmpty)
        #expect(en == "No Response")
        #expect(!ja.isEmpty)
        #expect(ja == "応答なし")
        #expect(!de.isEmpty)
        #expect(de == "Keine Antwort")
        #expect(!fr.isEmpty)
        #expect(fr == "Aucune réponse")
        #expect(!ko.isEmpty)
        #expect(ko == "응답 없음")
    }

    @Test func helperStatusOwnershipMismatchLocalization() {
        let key = "다른 사용자 소유"
        let en = Self.localized(key, in: "en")
        let ja = Self.localized(key, in: "ja")
        let de = Self.localized(key, in: "de")
        let fr = Self.localized(key, in: "fr")
        let ko = Self.localized(key, in: "ko")

        #expect(!en.isEmpty)
        #expect(en == "Owned by Another User")
        #expect(!ja.isEmpty)
        #expect(ja == "別のユーザーが所有")
        #expect(!de.isEmpty)
        #expect(de == "Im Besitz eines anderen Benutzers")
        #expect(!fr.isEmpty)
        #expect(fr == "Appartient à un autre utilisateur")
        #expect(!ko.isEmpty)
        #expect(ko == "다른 사용자 소유")
    }

    // MARK: - Popover Diagnostics Localization Tests

    @Test func popoverDiagnosticMetadataErrorLocalization() {
        let key = "메타데이터 오류"
        let en = Self.localized(key, in: "en")
        let ja = Self.localized(key, in: "ja")
        let de = Self.localized(key, in: "de")
        let fr = Self.localized(key, in: "fr")
        let ko = Self.localized(key, in: "ko")

        #expect(!en.isEmpty)
        #expect(en == "Metadata Error")
        #expect(!ja.isEmpty)
        #expect(ja == "メタデータエラー")
        #expect(!de.isEmpty)
        #expect(de == "Metadatenfehler")
        #expect(!fr.isEmpty)
        #expect(fr == "Erreur de métadonnées")
        #expect(!ko.isEmpty)
        #expect(ko == "메타데이터 오류")
    }

    @Test func popoverDiagnosticMatchesLatestBinaryLocalization() {
        let key = "최신 바이너리와 일치"
        let en = Self.localized(key, in: "en")
        let ja = Self.localized(key, in: "ja")
        let de = Self.localized(key, in: "de")
        let fr = Self.localized(key, in: "fr")
        let ko = Self.localized(key, in: "ko")

        #expect(!en.isEmpty)
        #expect(en == "Matches Latest Binary")
        #expect(!ja.isEmpty)
        #expect(ja == "最新バイナリと一致")
        #expect(!de.isEmpty)
        #expect(de == "Entspricht der neuesten Binärdatei")
        #expect(!fr.isEmpty)
        #expect(fr == "Correspond au dernier binaire")
        #expect(!ko.isEmpty)
        #expect(ko == "최신 바이너리와 일치")
    }

    @Test func popoverDiagnosticUpdateRequiredMismatchLocalization() {
        let key = "업데이트 필요 (불일치)"
        let en = Self.localized(key, in: "en")
        let ja = Self.localized(key, in: "ja")
        let de = Self.localized(key, in: "de")
        let fr = Self.localized(key, in: "fr")
        let ko = Self.localized(key, in: "ko")

        #expect(!en.isEmpty)
        #expect(en == "Update Required (Mismatch)")
        #expect(!ja.isEmpty)
        #expect(ja == "更新が必要（不一致）")
        #expect(!de.isEmpty)
        #expect(de == "Update erforderlich (Abweichung)")
        #expect(!fr.isEmpty)
        #expect(fr == "Mise à jour requise (non-concordance)")
        #expect(!ko.isEmpty)
        #expect(ko == "업데이트 필요 (불일치)")
    }

    @Test func popoverDiagnosticCannotVerifyLocalization() {
        let key = "확인 불가"
        let en = Self.localized(key, in: "en")
        let ja = Self.localized(key, in: "ja")
        let de = Self.localized(key, in: "de")
        let fr = Self.localized(key, in: "fr")
        let ko = Self.localized(key, in: "ko")

        #expect(!en.isEmpty)
        #expect(en == "Cannot Verify")
        #expect(!ja.isEmpty)
        #expect(ja == "確認不可")
        #expect(!de.isEmpty)
        #expect(de == "Überprüfung nicht möglich")
        #expect(!fr.isEmpty)
        #expect(fr == "Vérification impossible")
        #expect(!ko.isEmpty)
        #expect(ko == "확인 불가")
    }

    @Test func popoverDiagnosticUnsupportedNoFanLocalization() {
        let key = "미지원 (팬 없음)"
        let en = Self.localized(key, in: "en")
        let ja = Self.localized(key, in: "ja")
        let de = Self.localized(key, in: "de")
        let fr = Self.localized(key, in: "fr")
        let ko = Self.localized(key, in: "ko")

        #expect(!en.isEmpty)
        #expect(en == "Unsupported (No Fan)")
        #expect(!ja.isEmpty)
        #expect(ja == "非対応（ファンなし）")
        #expect(!de.isEmpty)
        #expect(de == "Nicht unterstützt (kein Lüfter)")
        #expect(!fr.isEmpty)
        #expect(fr == "Non pris en charge (aucun ventilateur)")
        #expect(!ko.isEmpty)
        #expect(ko == "미지원 (팬 없음)")
    }

    @Test func popoverDiagnosticCurrentPrefixLocalization() {
        let key = "현재:"
        let en = Self.localized(key, in: "en")
        let ja = Self.localized(key, in: "ja")
        let de = Self.localized(key, in: "de")
        let fr = Self.localized(key, in: "fr")
        let ko = Self.localized(key, in: "ko")

        #expect(!en.isEmpty)
        #expect(en == "Current:")
        #expect(!ja.isEmpty)
        #expect(ja == "現在:")
        #expect(!de.isEmpty)
        #expect(de == "Aktuell:")
        #expect(!fr.isEmpty)
        #expect(fr == "Actuel :")
        #expect(!ko.isEmpty)
        #expect(ko == "현재:")
    }

    // MARK: - String Catalog Coverage Tests

    @Test func stringCatalogContainsAllHelperAndDiagnosticKeys() throws {
        let targetLocales = ["en", "ja", "de", "fr", "ko"]
        let allRequiredKeys = [
            "확인 중…",
            "도우미 설치 중…",
            "정상 작동 중",
            "업데이트 필요",
            "미설치",
            "응답 없음",
            "다른 사용자 소유",
            "메타데이터 오류",
            "최신 바이너리와 일치",
            "업데이트 필요 (불일치)",
            "확인 불가",
            "미지원 (팬 없음)",
            "현재:"
        ]

        let fileURL: URL?
        if let currentFile = URL(string: "file://\(#filePath)") {
            let testDir = currentFile.deletingLastPathComponent()
            let catalogPath = testDir.deletingLastPathComponent()
                .appendingPathComponent("Wattly")
                .appendingPathComponent("Resources")
                .appendingPathComponent("Localizable.xcstrings")
            if FileManager.default.fileExists(atPath: catalogPath.path) {
                fileURL = catalogPath
            } else {
                fileURL = nil
            }
        } else {
            fileURL = nil
        }

        guard let catalogURL = fileURL else {
            return
        }

        let data = try Data(contentsOf: catalogURL)
        guard let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = catalog["strings"] as? [String: [String: Any]] else {
            Issue.record("Could not parse Localizable.xcstrings")
            return
        }

        for key in allRequiredKeys {
            guard let keyEntry = strings[key] else {
                Issue.record("Missing required key in catalog: '\(key)'")
                continue
            }
            guard let localizations = keyEntry["localizations"] as? [String: Any] else {
                Issue.record("Missing localizations object for key: '\(key)'")
                continue
            }

            for loc in targetLocales {
                guard let locData = localizations[loc] as? [String: Any],
                      let stringUnit = locData["stringUnit"] as? [String: Any],
                      let val = stringUnit["value"] as? String else {
                    Issue.record("Key '\(key)' missing or invalid for locale '\(loc)'")
                    continue
                }
                #expect(!val.isEmpty, "Value for '\(key)' in locale '\(loc)' must not be empty")
            }
        }
    }
}
