# Battery Charge Limit Localization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every user-visible string in the battery charge limit feature render in all 30 languages the app already supports, instead of Korean only.

**Architecture:** The status line is built by the **root LaunchDaemon**, a process with no `.lproj` resources and no knowledge of the user's locale — so it stops shipping prose and starts shipping a structured `BatteryControlStatusReason`. The app renders that reason into localized text. Everything else in the feature is a plain literal that is already a valid catalog key; those are fixed at the **render site**, where SwiftUI's `String` overloads were silently skipping lookup. A frozen legacy parser recognizes the Korean sentences an already-installed older helper still sends, so users on a stale daemon also see their own language.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Xcode String Catalog (`.xcstrings`), Swift Testing, xcodegen, Python 3 (catalog merge tooling).

## Global Constraints

- **Source language is Korean.** Catalog keys ARE the Korean strings. Never introduce an English-keyed or dot-separated key — `Wattly/Resources/Localizable.xcstrings` has `"sourceLanguage": "ko"` and all 195 existing keys are Korean sentences.
- **Every key must carry all 30 languages**, in this exact set: `ko, en, ja, zh-Hans, zh-Hant, de, fr, es, it, pt-BR, pt-PT, nl, sv, da, fi, nb, pl, cs, hu, ro, el, ru, uk, tr, ar, he, th, vi, id, hi`. A key with a missing language is a build-passing, user-visible regression.
- **Every new catalog entry uses** `"extractionState": "manual"` and per-language `{"stringUnit": {"state": "translated", "value": ...}}`.
- **`FanControlShared/` compiles into BOTH targets** (`Wattly` app and `WattlyFanDaemon` root tool — see `project.yml` `sources:`). Code there must **never** call a localization API: in the daemon `Bundle.main` is a resource-less executable and every lookup silently returns the key.
- **The daemon must not be given a locale.** It runs as root, outside any user session. Localization happens in the app, always.
- **`Text(someString)` does NOT localize.** SwiftUI's `StringProtocol` overload renders verbatim. Use `Text(LocalizedStringKey(s))` for keys, or `Text(alreadyLocalizedString)` only where the string was resolved through `String(localized:locale:)` first. The same applies to `.accessibilityHint(_:)` and `.accessibilityValue(_:)` — their `StringProtocol` overloads are verbatim; the `Text` overloads localize.
- **Deployment target is macOS 14.0.** Do not use `String(localized:)` from Foundation's newer overloads; the project has its own `String.init(localized:locale:bundle:)` in `Wattly/Settings/Settings.swift:340`, which is app-target only.
- **Swift 6 strict concurrency.** New shared types must be `Sendable`.
- **Any new `.swift` file needs `xcodegen generate`.** `Wattly.xcodeproj/project.pbxproj` lists
  sources individually, so a file that only exists on disk never compiles — and an unreferenced
  *test* file makes the suite pass without running it. Commit the regenerated `project.pbxproj`.
- **Run the full suite like this** — `-quiet` suppresses the summary line, so do not use it:

  ```bash
  xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 \
    | grep -E "error:|✘|Test run with" | tail -20
  ```

  The last line reads `✔ Test run with N tests in M suites passed after …`.
  **Baseline measured on this branch: 636 tests in 57 suites, green** (corrected 2026-08-23 —
  Task 1's implementer and a fresh run both confirmed 636/57 pre-Task-1 and 641/57 post; an earlier
  610/55 reading in this plan's history was stale DerivedData, not a real count. If Task 1 is
  already committed on your checkout, `git log --oneline` for `i18n(battery): add the charge
  limit's 31 strings` and run the suite once to confirm 641/57 before trusting the numbers below).
  This plan adds **42 tests and 3 suites** total (5+7+7+5+12+5+1 across Tasks 1-7; Tasks 8-9 add
  none). Each task below states the running absolute total; if yours differs, another branch has
  landed and you should track the delta instead.

---

## Background: what is actually broken

A read of the current code found **28 untranslated strings** in the charge-limit feature, failing in three distinct ways. They need three different fixes, which is why this is nine tasks and not one.

**Failure 1 — produced in the wrong process (9 strings).**
`FanControlShared/BatteryControlEngine.swift:198-210` (`detailText`) and `WattlyFanDaemon/FanControlDaemon.swift:48,185` build the status sentence inside the root daemon and ship it over XPC as `BatteryControlServiceStatus.detail`. No amount of catalog work fixes this: the daemon has no `.lproj` resources and no user locale. Two of the nine are interpolated (`"충전 제한 \(target)% 도달 …"`), so they could never match a catalog key even in the app.

**Failure 2 — localization dropped at the render site (16 strings).**
`Wattly/Views/Settings/SettingsBatterySection.swift:130` does `Text(resolved.text)`; `:118` does `Text(installErrorMessage)`. Both are the verbatim `String` overload. Likewise `Wattly/Views/SettingsComponents.swift:148,201,328,330` pass `String` to `.accessibilityHint`/`.accessibilityValue`. These strings never reach the catalog at runtime, so adding keys alone changes nothing.

**Failure 3 — simply absent from the catalog (all 31 keys).**
None of the keys this feature needs exist in `Localizable.xcstrings` yet — verified by probing the catalog directly. Even the correctly-written call sites (`SettingsSection(title:)`, `SettingsRowTitle(_:)`, `.alert("도우미 설치 실패")`, which all convert `String` → `LocalizedStringKey` for free) fall back to Korean because there is nothing to look up.

**Scope decision (confirmed with the user):** battery feature + the shared components the battery UI actually exercises. The app-wide sweep — 182 untranslated literals across 34 files (fan curve, updater, providers, menubar icon copy) — is explicitly **out of scope** and left for a follow-up. `scripts/add_localizations.py` from Task 1 is built to be reused for it.

**Stale-helper decision (confirmed with the user):** the app reverse-maps the nine known Korean sentences back to reason codes. This matters concretely: this very branch hit the case where the app reinstalls a *missing* helper but never replaces an *outdated* one, so a user who updates Wattly keeps a Korean-only daemon indefinitely. Forcing a helper reinstall on version mismatch is a real fix but a separate feature (it needs admin auth) and is **out of scope here**.

---

## File Structure

**New — shared (compiled into app + daemon):**
- `FanControlShared/BatteryControlStatusReason.swift` — the structured reason: a `Kind` enum, an optional `limitPercentage`, lenient decoding for forward compatibility, and `legacyKoreanDetail` so a current daemon still fills the old `detail` field for an older app.

**New — app only:**
- `Wattly/Core/LegacyBatteryDetail.swift` — frozen v1.0.4 Korean-sentence → reason parser. Pure, no SwiftUI.
- `Wattly/Core/BatteryStatusText.swift` — reason → localized text. Pure; takes a `Locale`. Also formats the install-failure message.

**Modified — shared:**
- `FanControlShared/BatteryControlProtocol.swift` — `BatteryControlServiceStatus` gains `detailReason: BatteryControlStatusReason?`.
- `FanControlShared/BatteryControlEngine.swift` — `detailText` → `detailReason`; `detail` derived from it.

**Modified — daemon:**
- `WattlyFanDaemon/FanControlDaemon.swift:44-49, 181-193` — the two hand-built statuses stamp `.initializing` / `.powerSourceUnreadable`.

**Modified — app:**
- `Wattly/Core/BatterySectionPresentation.swift` — `status(...)` takes `reason:` + `locale:` and returns localized text.
- `Wattly/Control/BatteryControlClient.swift` — `installAndApply` returns a structured `InstallFailure`.
- `Wattly/Views/Settings/SettingsBatterySection.swift` — `@Environment(\.locale)`, localized alert body.
- `Wattly/Views/SettingsComponents.swift` — a11y hint/value localization (3 sites).
- `Wattly/Control/FanHelperInstaller.swift` — no code change needed; its literals become catalog keys resolved by the app.
- `Wattly/Resources/Localizable.xcstrings` — 31 new keys × 30 languages.

**New — tooling:**
- `scripts/add_localizations.py` — merges a translations JSON into the catalog, refusing any key that is missing a language.

**Tests:**
- New: `WattlyTests/BatteryControlStatusReasonTests.swift`, `WattlyTests/LegacyBatteryDetailTests.swift`, `WattlyTests/BatteryStatusTextTests.swift`
- Modified: `WattlyTests/LocalizationTests.swift`, `WattlyTests/BatterySectionPresentationTests.swift`

---

### Why the legacy Korean table is duplicated on purpose

`BatteryControlStatusReason.legacyKoreanDetail` (shared) and `LegacyBatteryDetail` (app) will contain the same nine Korean sentences on the day this ships. **Do not DRY them together.** They answer different questions:

- `legacyKoreanDetail` describes what **this build's** daemon emits. It is free to change whenever the copy is improved.
- `LegacyBatteryDetail` describes what the daemon binary **already sitting on the user's disk** emits — compiled from commit `e311a7f` and frozen forever.

Merging them means that the day someone rewords a status message, the app silently stops recognizing every already-installed helper. The duplication is the safety property.

---

## Task 1: Catalog tooling and all 31 keys

**Files:**
- Create: `scripts/add_localizations.py`
- Create: `/private/tmp/claude-501/-Users-hyunjun-macbook-pro-Documents-Project-project-wattly/edbe0c05-0fed-43dc-8e45-f25af3386917/scratchpad/battery-l10n.json` (working file, not committed)
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Test: `WattlyTests/LocalizationTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: 31 catalog keys, listed verbatim in the table below. Every later task depends on these exact key strings — copy them character for character, including the `%lld%%` and `%@` specifiers.

- [ ] **Step 1: Write the merge script**

Create `scripts/add_localizations.py`:

```python
#!/usr/bin/env python3
"""Merge translations into Wattly/Resources/Localizable.xcstrings.

Usage:  python3 scripts/add_localizations.py <additions.json>

<additions.json> maps each Korean catalog key to a {language: translation} dict.
Every key must supply a translation for every language already present in the
catalog; a partially-translated key builds fine and then shows Korean to the
users it forgot, so it is rejected here instead.

The catalog round-trips byte-identically through json.loads/json.dumps with
these settings, so the diff shows only the keys that were actually added.
"""
import json
import pathlib
import sys

CATALOG = pathlib.Path(__file__).resolve().parent.parent / "Wattly/Resources/Localizable.xcstrings"


def main(additions_path: str) -> None:
    catalog = json.loads(CATALOG.read_text())
    additions = json.loads(pathlib.Path(additions_path).read_text())

    known = {lang
             for entry in catalog["strings"].values()
             for lang in entry.get("localizations", {})}
    if not known:
        sys.exit("catalog has no languages to match against")

    for key, translations in additions.items():
        missing = known - set(translations)
        if missing:
            sys.exit(f"key {key!r} is missing languages: {sorted(missing)}")
        extra = set(translations) - known
        if extra:
            sys.exit(f"key {key!r} has languages the catalog does not use: {sorted(extra)}")

    for key, translations in additions.items():
        entry = catalog["strings"].setdefault(key, {})
        entry["extractionState"] = "manual"
        localizations = entry.setdefault("localizations", {})
        for lang, value in translations.items():
            localizations[lang] = {"stringUnit": {"state": "translated", "value": value}}

    CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
    print(f"merged {len(additions)} keys; catalog now has {len(catalog['strings'])} keys")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
```

- [ ] **Step 2: Verify the script refuses an incomplete key**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
echo '{"테스트키": {"en": "Test"}}' > /tmp/bad-l10n.json
python3 scripts/add_localizations.py /tmp/bad-l10n.json; echo "exit=$?"
git diff --stat Wattly/Resources/Localizable.xcstrings
```

Expected: prints `key '테스트키' is missing languages: [...]` listing 29 languages, `exit=1`, and **an empty `git diff --stat`** — the script must validate every key before writing anything.

- [ ] **Step 3: Author the translations JSON**

Write `battery-l10n.json` in the scratchpad directory. It must contain **exactly these 31 keys**, each with **all 30 languages**.

The Korean key and the `en` / `ja` values below are **normative — use them verbatim.** Produce the other 27 languages yourself, matching the register of the existing catalog (concise UI copy, sentence case in the Latin languages, no trailing period unless the Korean key has one).

| # | Korean key (verbatim) | `en` | `ja` |
|---|---|---|---|
| 1 | `초기화 중` | `Initializing` | `初期化中` |
| 2 | `전원 소스를 읽을 수 없습니다` | `Cannot read power source` | `電源を読み取れません` |
| 3 | `이 Mac은 충전 제어를 지원하지 않습니다` | `This Mac does not support charge control` | `このMacは充電制御に対応していません` |
| 4 | `충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)` | `Could not resume charging (try reconnecting the power adapter)` | `充電を再開できませんでした（電源アダプタを接続し直してください）` |
| 5 | `이 Mac에서 충전 제어를 적용하지 못했습니다` | `Could not apply charge control on this Mac` | `このMacで充電制御を適用できませんでした` |
| 6 | `충전 제한 %lld%% 도달 (전원 어댑터 바이패스 구동)` | `Charge limit %lld%% reached (running on adapter bypass)` | `充電上限 %lld%% に到達（電源アダプタのバイパス駆動）` |
| 7 | `충전 제한 비활성화됨` | `Charge limit off` | `充電上限オフ` |
| 8 | `목표치(%lld%%)까지 충전 중` | `Charging to %lld%%` | `%lld%% まで充電中` |
| 9 | `배터리 전원으로 구동 중` | `Running on battery` | `バッテリー電源で動作中` |
| 10 | `도우미에 연결되지 않음` | `Not connected to helper` | `ヘルパーに接続されていません` |
| 11 | `충전 제한 설정을 인코딩할 수 없음` | `Cannot encode charge limit settings` | `充電上限設定をエンコードできません` |
| 12 | `도우미 응답 오류` | `Helper response error` | `ヘルパー応答エラー` |
| 13 | `도우미 연결을 만들 수 없음` | `Cannot create helper connection` | `ヘルパー接続を作成できません` |
| 14 | `도우미는 설치했지만 충전 제한을 적용하지 못했습니다: %@` | `Helper installed, but the charge limit could not be applied: %@` | `ヘルパーはインストールされましたが、充電上限を適用できませんでした: %@` |
| 15 | `도우미 설치 중…` | `Installing helper…` | `ヘルパーをインストール中…` |
| 16 | `앱 번들에서 도우미 실행 파일을 찾을 수 없습니다.` | `Could not find the helper executable in the app bundle.` | `アプリバンドル内にヘルパー実行ファイルが見つかりません。` |
| 17 | `설치 스크립트를 임시 폴더에 쓰지 못했습니다.` | `Could not write the installation script to the temporary folder.` | `インストールスクリプトを一時フォルダに書き込めませんでした。` |
| 18 | `관리자 인증이 취소되었거나 실패했습니다.` | `Administrator authentication was cancelled or failed.` | `管理者認証がキャンセルされたか失敗しました。` |
| 19 | `배터리 충전 제어` | `Battery Charge Control` | `バッテリー充電制御` |
| 20 | `배터리 충전 제한` | `Battery Charge Limit` | `バッテリー充電上限` |
| 21 | `이 Mac은 충전 제어를 지원하지 않습니다. 이 기능이 사용하는 SMC 레지스터가 없습니다.` | `This Mac does not support charge control. It lacks the SMC register this feature uses.` | `このMacは充電制御に対応していません。この機能が使用するSMCレジスタがありません。` |
| 22 | `설정한 한도에 도달하면 충전을 멈추고 전원 어댑터로만 작동하여 배터리 수명을 보호합니다.` | `Stops charging at your limit and runs from the power adapter to protect battery lifespan.` | `設定した上限に達すると充電を停止し、電源アダプタのみで動作してバッテリー寿命を保護します。` |
| 23 | `최대 충전 한도` | `Maximum Charge Limit` | `最大充電上限` |
| 24 | `충전 제한을 켜면 한도를 조절할 수 있습니다.` | `Turn on the charge limit to adjust the maximum.` | `充電上限をオンにすると上限を調整できます。` |
| 25 | `도우미 설치 실패` | `Helper Installation Failed` | `ヘルパーのインストールに失敗` |
| 26 | `도우미 설치` | `Install Helper` | `ヘルパーをインストール` |
| 27 | `확인` | `OK` | `OK` |
| 28 | `원활한 동작을 위해 시스템 설정 > 배터리의 '최적화된 배터리 충전'을 꺼두는 것을 권장합니다.` | `For reliable operation, we recommend turning off “Optimized Battery Charging” in System Settings › Battery.` | `確実に動作させるため、システム設定 > バッテリーの「バッテリー充電の最適化」をオフにすることをおすすめします。` |
| 29 | `켜짐` | `On` | `オン` |
| 30 | `꺼짐` | `Off` | `オフ` |
| 31 | `사용할 수 없습니다` | `Unavailable` | `使用できません` |

Additional values that Step 6's tests assert verbatim — use exactly these:

- key 3, `de`: `Dieser Mac unterstützt keine Ladesteuerung`
- key 3, `zh-Hans`: `此 Mac 不支持充电控制`
- key 7, `de`: `Ladelimit aus`
- key 7, `zh-Hans`: `充电上限已关闭`
- key 19, `de`: `Batterieladesteuerung`
- key 19, `zh-Hans`: `电池充电控制`
- key 20, `fr`: `Limite de charge de la batterie`
- key 29, `de`: `Ein`
- key 30, `de`: `Aus`

Format-specifier rules — **getting these wrong makes the lookup silently fall back to Korean**:
- Keys 6 and 8 use `%lld` for the integer and `%%` for a literal percent sign. They are rendered with `String(format:locale:_:)`, so the doubling is required.
- Key 14 uses `%@` for an embedded string.
- Every language's translation must keep the **same specifiers in the same order** as the Korean key. In key 8 the Korean is `목표치(%lld%%)까지 충전 중` and the English is `Charging to %lld%%` — the parenthesis is Korean phrasing, not part of the format.
- Right-to-left languages (`ar`, `he`) keep the specifiers in logical order; do not reorder or add positional `%1$@` markers.

The JSON shape:

```json
{
  "초기화 중": {
    "ko": "초기화 중",
    "en": "Initializing",
    "ja": "初期化中",
    "zh-Hans": "正在初始化",
    "…": "… all 30 languages …"
  }
}
```

Note that `ko` is required too, and its value is the key itself.

- [ ] **Step 4: Merge into the catalog**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
python3 scripts/add_localizations.py "/private/tmp/claude-501/-Users-hyunjun-macbook-pro-Documents-Project-project-wattly/edbe0c05-0fed-43dc-8e45-f25af3386917/scratchpad/battery-l10n.json"
```

Expected: `merged 31 keys; catalog now has N keys` where N = (pre-task count + 31). This plan's text assumed a pre-task count of 195 (226 total); the real count on this branch was 196 (227 total) — confirmed during Task 1's execution. Trust your own pre-task count, not the number printed here.

- [ ] **Step 5: Verify catalog integrity**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
python3 -c "
import json
d = json.load(open('Wattly/Resources/Localizable.xcstrings'))
langs = {}
for v in d['strings'].values():
    for l in v.get('localizations', {}):
        langs[l] = langs.get(l, 0) + 1
total = len(d['strings'])
print('keys:', total)
bad = {l: c for l, c in langs.items() if c != total}
print('languages:', len(langs))
print('INCOMPLETE:', bad if bad else 'none')
"
```

Expected: `keys: N` (pre-task count + 31 — 227 on this branch, see the note above), `languages: 30`, `INCOMPLETE: none`.

- [ ] **Step 6: Write the failing localization test**

Append this suite to `WattlyTests/LocalizationTests.swift`, inside the existing `struct LocalizationTests`, just before its closing brace:

```swift
    // MARK: - 배터리 충전 제한 (plan 2026-08-23)

    @Test func batteryStatusReasonTranslations() {
        #expect(String(localized: "이 Mac은 충전 제어를 지원하지 않습니다", locale: Locale(identifier: "en"))
                == "This Mac does not support charge control")
        #expect(String(localized: "이 Mac은 충전 제어를 지원하지 않습니다", locale: Locale(identifier: "ja"))
                == "このMacは充電制御に対応していません")
        #expect(String(localized: "이 Mac은 충전 제어를 지원하지 않습니다", locale: Locale(identifier: "de"))
                == "Dieser Mac unterstützt keine Ladesteuerung")
        #expect(String(localized: "이 Mac은 충전 제어를 지원하지 않습니다", locale: Locale(identifier: "zh-Hans"))
                == "此 Mac 不支持充电控制")

        #expect(String(localized: "충전 제한 비활성화됨", locale: Locale(identifier: "en")) == "Charge limit off")
        #expect(String(localized: "충전 제한 비활성화됨", locale: Locale(identifier: "ja")) == "充電上限オフ")
        #expect(String(localized: "충전 제한 비활성화됨", locale: Locale(identifier: "de")) == "Ladelimit aus")
        #expect(String(localized: "충전 제한 비활성화됨", locale: Locale(identifier: "zh-Hans")) == "充电上限已关闭")

        #expect(String(localized: "배터리 전원으로 구동 중", locale: Locale(identifier: "en")) == "Running on battery")
        #expect(String(localized: "초기화 중", locale: Locale(identifier: "en")) == "Initializing")
        #expect(String(localized: "전원 소스를 읽을 수 없습니다", locale: Locale(identifier: "en"))
                == "Cannot read power source")
        #expect(String(localized: "이 Mac에서 충전 제어를 적용하지 못했습니다", locale: Locale(identifier: "en"))
                == "Could not apply charge control on this Mac")
        #expect(String(localized: "충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)",
                       locale: Locale(identifier: "en"))
                == "Could not resume charging (try reconnecting the power adapter)")
    }

    /// 서식 지정자가 어긋나면 조회는 조용히 실패하고 한국어로 되돌아간다. 지정자 자체를 못박아 둔다.
    @Test func batteryFormatKeysKeepTheirSpecifiers() {
        for lang in ["ko", "en", "ja", "de", "fr", "zh-Hans", "ar", "he", "hi"] {
            let inhibited = String(localized: "충전 제한 %lld%% 도달 (전원 어댑터 바이패스 구동)",
                                   locale: Locale(identifier: lang))
            #expect(inhibited.contains("%lld"), "\(lang): %lld 유실")
            #expect(inhibited.contains("%%"), "\(lang): %% 유실")

            let charging = String(localized: "목표치(%lld%%)까지 충전 중", locale: Locale(identifier: lang))
            #expect(charging.contains("%lld"), "\(lang): %lld 유실")
            #expect(charging.contains("%%"), "\(lang): %% 유실")

            let installFailed = String(localized: "도우미는 설치했지만 충전 제한을 적용하지 못했습니다: %@",
                                       locale: Locale(identifier: lang))
            #expect(installFailed.contains("%@"), "\(lang): %@ 유실")
        }

        #expect(String(localized: "충전 제한 %lld%% 도달 (전원 어댑터 바이패스 구동)", locale: Locale(identifier: "en"))
                == "Charge limit %lld%% reached (running on adapter bypass)")
        #expect(String(localized: "목표치(%lld%%)까지 충전 중", locale: Locale(identifier: "en"))
                == "Charging to %lld%%")
    }

    @Test func batterySettingsSectionTranslations() {
        #expect(String(localized: "배터리 충전 제어", locale: Locale(identifier: "en")) == "Battery Charge Control")
        #expect(String(localized: "배터리 충전 제어", locale: Locale(identifier: "ja")) == "バッテリー充電制御")
        #expect(String(localized: "배터리 충전 제어", locale: Locale(identifier: "de")) == "Batterieladesteuerung")
        #expect(String(localized: "배터리 충전 제어", locale: Locale(identifier: "zh-Hans")) == "电池充电控制")

        #expect(String(localized: "배터리 충전 제한", locale: Locale(identifier: "en")) == "Battery Charge Limit")
        #expect(String(localized: "배터리 충전 제한", locale: Locale(identifier: "fr"))
                == "Limite de charge de la batterie")

        #expect(String(localized: "최대 충전 한도", locale: Locale(identifier: "en")) == "Maximum Charge Limit")
        #expect(String(localized: "도우미 설치", locale: Locale(identifier: "en")) == "Install Helper")
        #expect(String(localized: "도우미 설치 실패", locale: Locale(identifier: "en")) == "Helper Installation Failed")
        #expect(String(localized: "도우미 설치 중…", locale: Locale(identifier: "en")) == "Installing helper…")
        #expect(String(localized: "확인", locale: Locale(identifier: "en")) == "OK")
        #expect(String(localized: "충전 제한을 켜면 한도를 조절할 수 있습니다.", locale: Locale(identifier: "en"))
                == "Turn on the charge limit to adjust the maximum.")
    }

    @Test func sharedControlAccessibilityTranslations() {
        #expect(String(localized: "켜짐", locale: Locale(identifier: "en")) == "On")
        #expect(String(localized: "꺼짐", locale: Locale(identifier: "en")) == "Off")
        #expect(String(localized: "켜짐", locale: Locale(identifier: "de")) == "Ein")
        #expect(String(localized: "꺼짐", locale: Locale(identifier: "de")) == "Aus")
        #expect(String(localized: "사용할 수 없습니다", locale: Locale(identifier: "en")) == "Unavailable")
    }

    @Test func helperInstallErrorTranslations() {
        #expect(String(localized: "앱 번들에서 도우미 실행 파일을 찾을 수 없습니다.", locale: Locale(identifier: "en"))
                == "Could not find the helper executable in the app bundle.")
        #expect(String(localized: "관리자 인증이 취소되었거나 실패했습니다.", locale: Locale(identifier: "en"))
                == "Administrator authentication was cancelled or failed.")
        #expect(String(localized: "도우미에 연결되지 않음", locale: Locale(identifier: "en"))
                == "Not connected to helper")
        #expect(String(localized: "도우미 응답 오류", locale: Locale(identifier: "en")) == "Helper response error")
    }
```

- [ ] **Step 7: Run the tests**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 \
  | grep -E "error:|✘|Test run with" | tail -25
```

Expected: PASS, **641 tests in 57 suites** (already committed as `7c2884a` if you are resuming).

If a translation assertion fails showing the Korean key echoed back, the key in the JSON does not byte-match the key in the test — check for a different space, ellipsis (`…` vs `...`), or quote character.

- [ ] **Step 8: Commit**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
git add scripts/add_localizations.py Wattly/Resources/Localizable.xcstrings WattlyTests/LocalizationTests.swift
git commit -m "i18n(battery): add the charge limit's 31 strings in all 30 languages"
```

---

## Task 2: The structured status reason

**Files:**
- Create: `FanControlShared/BatteryControlStatusReason.swift`
- Test: `WattlyTests/BatteryControlStatusReasonTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct BatteryControlStatusReason: Codable, Equatable, Sendable`
  - `public enum BatteryControlStatusReason.Kind: String, Codable, Equatable, Sendable, CaseIterable` with cases `initializing, powerSourceUnreadable, hardwareUnsupported, releaseFailed, applyFailed, inhibitedAtLimit, limitDisabled, chargingToTarget, onBatteryPower, unrecognized`
  - `public init(kind: Kind, limitPercentage: Int? = nil)`
  - `public var kind: Kind`, `public var limitPercentage: Int?`
  - `public var legacyKoreanDetail: String`

- [ ] **Step 1: Write the failing test**

Create `WattlyTests/BatteryControlStatusReasonTests.swift`:

```swift
import Testing
import Foundation
@testable import Wattly

@Suite struct BatteryControlStatusReasonTests {

    @Test func roundTripsThroughJSON() throws {
        let reason = BatteryControlStatusReason(kind: .inhibitedAtLimit, limitPercentage: 80)
        let data = try BatteryControlCodec.encode(reason)
        let decoded = try BatteryControlCodec.decode(BatteryControlStatusReason.self, from: data)
        #expect(decoded == reason)
    }

    @Test func encodesKindAsItsRawToken() throws {
        let data = try BatteryControlCodec.encode(
            BatteryControlStatusReason(kind: .chargingToTarget, limitPercentage: 85))
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"chargingToTarget\""))
        #expect(json.contains("85"))
    }

    /// 새 데몬 + 구버전 앱. 모르는 토큰에서 상태 전체 디코딩이 실패하면, 앱은 배터리 상태를
    /// 아예 못 읽는다 — 문구 하나 때문에 기능이 통째로 죽는 셈이다.
    @Test func unknownKindDecodesAsUnrecognizedRatherThanThrowing() throws {
        let json = Data(#"{"kind":"someFutureState","limitPercentage":90}"#.utf8)
        let decoded = try BatteryControlCodec.decode(BatteryControlStatusReason.self, from: json)
        #expect(decoded.kind == .unrecognized)
        #expect(decoded.limitPercentage == 90)
    }

    @Test func limitIsOptionalAndAbsentByDefault() throws {
        let json = Data(#"{"kind":"limitDisabled"}"#.utf8)
        let decoded = try BatteryControlCodec.decode(BatteryControlStatusReason.self, from: json)
        #expect(decoded.kind == .limitDisabled)
        #expect(decoded.limitPercentage == nil)
        #expect(BatteryControlStatusReason(kind: .limitDisabled).limitPercentage == nil)
    }

    /// 이 문자열들은 구버전 **앱**이 읽는 값이다. 바꾸면 그 앱의 상태 줄이 깨진다.
    @Test func legacyKoreanDetailMatchesTheShippedWording() {
        #expect(BatteryControlStatusReason(kind: .initializing).legacyKoreanDetail == "초기화 중")
        #expect(BatteryControlStatusReason(kind: .powerSourceUnreadable).legacyKoreanDetail
                == "전원 소스를 읽을 수 없습니다")
        #expect(BatteryControlStatusReason(kind: .hardwareUnsupported).legacyKoreanDetail
                == "이 Mac은 충전 제어를 지원하지 않습니다")
        #expect(BatteryControlStatusReason(kind: .releaseFailed).legacyKoreanDetail
                == "충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)")
        #expect(BatteryControlStatusReason(kind: .applyFailed).legacyKoreanDetail
                == "이 Mac에서 충전 제어를 적용하지 못했습니다")
        #expect(BatteryControlStatusReason(kind: .inhibitedAtLimit, limitPercentage: 80).legacyKoreanDetail
                == "충전 제한 80% 도달 (전원 어댑터 바이패스 구동)")
        #expect(BatteryControlStatusReason(kind: .limitDisabled).legacyKoreanDetail == "충전 제한 비활성화됨")
        #expect(BatteryControlStatusReason(kind: .chargingToTarget, limitPercentage: 85).legacyKoreanDetail
                == "목표치(85%)까지 충전 중")
        #expect(BatteryControlStatusReason(kind: .onBatteryPower).legacyKoreanDetail == "배터리 전원으로 구동 중")
    }

    /// 한도가 필요한 종류인데 값이 없는 경우. 크래시도, "nil%"도 안 된다.
    @Test func legacyDetailSurvivesAMissingLimit() {
        #expect(BatteryControlStatusReason(kind: .inhibitedAtLimit).legacyKoreanDetail
                == "충전 제한 100% 도달 (전원 어댑터 바이패스 구동)")
        #expect(BatteryControlStatusReason(kind: .chargingToTarget).legacyKoreanDetail
                == "목표치(100%)까지 충전 중")
    }

    @Test func everyKindHasNonEmptyLegacyCopy() {
        for kind in BatteryControlStatusReason.Kind.allCases where kind != .unrecognized {
            #expect(!BatteryControlStatusReason(kind: kind).legacyKoreanDetail.isEmpty, "\(kind)")
        }
    }
}
```

- [ ] **Step 2: Regenerate the Xcode project**

`Wattly.xcodeproj/project.pbxproj` enumerates every source file individually, so a file that only
exists on disk is invisible to the build. For a **test** file this fails silently in the worst
possible way: an unreferenced test target file is never compiled, the suite goes green, and the new
tests never ran at all. Regenerate before trusting any result from this task.

Files that must become referenced:
- `FanControlShared/BatteryControlStatusReason.swift (created in Step 3)`
- `WattlyTests/BatteryControlStatusReasonTests.swift`

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
xcodegen generate
grep -c "BatteryControlStatusReasonTests.swift" Wattly.xcodeproj/project.pbxproj
```

Expected: `Created project at …/Wattly.xcodeproj`, then a **non-zero** count. The daemon-embed copy
phase is declared in `project.yml`, so regeneration preserves it.

- [ ] **Step 3: Run it to verify it fails**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 \
  | grep -E "error:|✘|Test run with" | tail -20
```

Expected: compile FAIL — `cannot find 'BatteryControlStatusReason' in scope`.

- [ ] **Step 4: Implement the type**

Create `FanControlShared/BatteryControlStatusReason.swift`:

```swift
import Foundation

/// Why the charge limit is in the state it is in — as a code rather than a sentence.
///
/// The status line is produced by `WattlyFanDaemon`, which runs as root outside any user session.
/// It has no `.lproj` resources and no idea what language the user reads, so prose built there can
/// only ever be Korean. Shipping the *reason* instead lets the app render it in the user's own
/// language, and keeps the two interpolated states (which could never match a catalog key) working
/// like every other string.
///
/// This type lives in `FanControlShared`, which compiles into both the app and the daemon, so it
/// must not touch any localization API — in the daemon every lookup silently returns its own key.
public struct BatteryControlStatusReason: Codable, Equatable, Sendable {

    public enum Kind: String, Codable, Equatable, Sendable, CaseIterable {
        /// The daemon has started but has not evaluated a power reading yet.
        case initializing
        /// IOKit would not hand over a power source snapshot, and there is no cached one.
        case powerSourceUnreadable
        /// This Mac exposes no charge-control register at all (`BatteryControlRegisterSet.unsupported`).
        case hardwareUnsupported
        /// Charging is inhibited and the write that would release it keeps failing — the Mac is
        /// stuck not charging. The most user-actionable state there is.
        case releaseFailed
        /// The user asked for the limit and the register write will not land.
        case applyFailed
        /// Working as intended, sitting at the limit on adapter bypass. Carries `limitPercentage`.
        case inhibitedAtLimit
        /// The user has the feature switched off.
        case limitDisabled
        /// Plugged in and charging up toward the limit. Carries `limitPercentage`.
        case chargingToTarget
        /// Unplugged.
        case onBatteryPower
        /// A token this build does not know — a newer daemon talking to an older app. Never
        /// produced locally; only ever decoded. The app falls back to the `detail` sentence.
        case unrecognized

        /// Decoding is lenient on purpose. The default synthesized initializer throws on an
        /// unknown raw value, which would fail the decode of the *entire* `BatteryControlServiceStatus`
        /// — taking the battery percentage, the mode, and the hardware-support flag down with one
        /// unfamiliar status word.
        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unrecognized
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public var kind: Kind
    /// The limit in play, for the two kinds that name one. `nil` everywhere else.
    public var limitPercentage: Int?

    public init(kind: Kind, limitPercentage: Int? = nil) {
        self.kind = kind
        self.limitPercentage = limitPercentage
    }

    /// The Korean sentence this reason used to be, for an app too old to understand `kind`.
    ///
    /// A current daemon keeps filling `BatteryControlServiceStatus.detail` with this so that a
    /// downgraded or not-yet-updated app still shows something true. It is deliberately NOT the
    /// same table as the app's `LegacyBatteryDetail`: this one describes what *this* build emits
    /// and may be reworded freely, while that one describes binaries already installed on disk and
    /// must never change. Merging them means a copy edit silently breaks recognition of every
    /// helper already out there.
    public var legacyKoreanDetail: String {
        // 100 is the no-op ceiling the engine uses when it has no configured target, so a reason
        // that arrives without a limit degrades to "no limit" rather than to a crash.
        let target = limitPercentage ?? 100
        switch kind {
        case .initializing: return "초기화 중"
        case .powerSourceUnreadable: return "전원 소스를 읽을 수 없습니다"
        case .hardwareUnsupported: return "이 Mac은 충전 제어를 지원하지 않습니다"
        case .releaseFailed: return "충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)"
        case .applyFailed: return "이 Mac에서 충전 제어를 적용하지 못했습니다"
        case .inhibitedAtLimit: return "충전 제한 \(target)% 도달 (전원 어댑터 바이패스 구동)"
        case .limitDisabled: return "충전 제한 비활성화됨"
        case .chargingToTarget: return "목표치(\(target)%)까지 충전 중"
        case .onBatteryPower: return "배터리 전원으로 구동 중"
        case .unrecognized: return ""
        }
    }
}
```

- [ ] **Step 5: Run the tests**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 \
  | grep -E "error:|✘|Test run with" | tail -20
```

Expected: PASS, **648 tests in 58 suites** (the new `BatteryControlStatusReasonTests`).

- [ ] **Step 6: Commit**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
git add FanControlShared/BatteryControlStatusReason.swift WattlyTests/BatteryControlStatusReasonTests.swift Wattly.xcodeproj/project.pbxproj
git commit -m "feat(battery): carry the status as a reason code, not a Korean sentence"
```

---

## Task 3: The daemon emits the reason

**Files:**
- Modify: `FanControlShared/BatteryControlProtocol.swift`
- Modify: `FanControlShared/BatteryControlEngine.swift:198-233`
- Modify: `WattlyFanDaemon/FanControlDaemon.swift:44-49, 181-193`
- Test: `WattlyTests/BatteryControlProtocolTests.swift`, `WattlyTests/BatteryControlEngineTests.swift`

**Interfaces:**
- Consumes: `BatteryControlStatusReason`, `.Kind` (Task 2).
- Produces: `BatteryControlServiceStatus.detailReason: BatteryControlStatusReason?` — the new last parameter of its initializer, defaulting to `nil`.

- [ ] **Step 1: Write the failing tests**

Append to `WattlyTests/BatteryControlProtocolTests.swift`, inside its existing suite:

```swift
    /// 구버전 도우미의 페이로드에는 이 필드가 없다. 없다고 디코딩이 실패하면
    /// 업데이트한 앱이 기존 도우미와 대화하지 못한다.
    @Test func statusDecodesWithoutAReason() throws {
        let json = Data(#"{"mode":"charging","currentPercentage":70,"isPowerAdapterConnected":true,"detail":"충전 중","updatedAt":1.0}"#.utf8)
        let decoded = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: json)
        #expect(decoded.detailReason == nil)
        #expect(decoded.detail == "충전 중")
    }

    @Test func statusRoundTripsAReason() throws {
        let status = BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 80,
            isPowerAdapterConnected: true,
            detail: "충전 제한 80% 도달 (전원 어댑터 바이패스 구동)",
            updatedAt: 12.0,
            appliedLimitPercentage: 80,
            isHardwareSupported: true,
            detailReason: .init(kind: .inhibitedAtLimit, limitPercentage: 80))
        let decoded = try BatteryControlCodec.decode(
            BatteryControlServiceStatus.self, from: BatteryControlCodec.encode(status))
        #expect(decoded == status)
        #expect(decoded.detailReason?.kind == .inhibitedAtLimit)
        #expect(decoded.detailReason?.limitPercentage == 80)
    }

    /// 새 데몬 + 구버전 앱의 반대 방향: 모르는 종류 하나가 상태 전체를 못 읽게 만들면 안 된다.
    @Test func statusSurvivesAnUnknownReasonKind() throws {
        let json = Data(#"{"mode":"charging","currentPercentage":70,"isPowerAdapterConnected":true,"detail":"충전 중","updatedAt":1.0,"detailReason":{"kind":"aFutureKind"}}"#.utf8)
        let decoded = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: json)
        #expect(decoded.detailReason?.kind == .unrecognized)
        #expect(decoded.currentPercentage == 70)
    }
```

Append to `WattlyTests/BatteryControlEngineTests.swift`, inside its existing suite:

```swift
    /// `detail`과 `detailReason`은 같은 사실의 두 표현이다. 어긋나면 구버전 앱과 신버전 앱이
    /// 서로 다른 이야기를 보게 된다.
    @Test func statusReasonAgreesWithTheKoreanDetail() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 80))
        let status = engine.update(currentSoC: 70, isPluggedIn: true)
        #expect(status.detailReason?.kind == .chargingToTarget)
        #expect(status.detailReason?.limitPercentage == 80)
        #expect(status.detail == status.detailReason?.legacyKoreanDetail)
    }

    @Test func statusReasonReportsUnsupportedHardware() {
        let mockHW = MockBatteryHardware()
        mockHW.registerSet = .unsupported
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 80))
        let status = engine.update(currentSoC: 70, isPluggedIn: true)
        #expect(status.detailReason?.kind == .hardwareUnsupported)
        #expect(status.detail == "이 Mac은 충전 제어를 지원하지 않습니다")
    }

    @Test func statusReasonReportsTheDisabledLimit() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: false, limitPercentage: 80))
        let status = engine.update(currentSoC: 70, isPluggedIn: true)
        #expect(status.detailReason?.kind == .limitDisabled)
    }

    @Test func statusReasonReportsBatteryPower() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: false, limitPercentage: 80))
        let status = engine.update(currentSoC: 70, isPluggedIn: false)
        #expect(status.detailReason?.kind == .onBatteryPower)
    }
```

`MockBatteryHardware` is the fake already defined at the top of `WattlyTests/BatteryControlEngineTests.swift:5`; it defaults to `registerSet = .modern` and exposes it as a settable `var`. The suite is a plain `struct BatteryControlEngineTests` (no `@Suite` attribute) — add these inside it, matching the surrounding style.

- [ ] **Step 2: Run to verify failure**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 \
  | grep -E "error:|✘|Test run with" | tail -20
```

Expected: compile FAIL — `extra argument 'detailReason' in call` and `value of type 'BatteryControlServiceStatus' has no member 'detailReason'`.

- [ ] **Step 3: Add the field to the protocol**

In `FanControlShared/BatteryControlProtocol.swift`, inside `struct BatteryControlServiceStatus`, add the stored property immediately after `isHardwareSupported`:

```swift
    /// The structured form of `detail`. `nil` from a helper too old to send one — which is the
    /// common case right after an app update, since nothing replaces an installed helper that still
    /// answers. The app falls back to parsing `detail` in that case.
    ///
    /// `detail` is kept rather than replaced so the reverse pairing also works: a current helper
    /// talking to an older app still fills the sentence that app knows how to read.
    public var detailReason: BatteryControlStatusReason?
```

Then extend the initializer — add the parameter **last**, so every existing call site keeps compiling:

```swift
    public init(
        mode: BatteryControlServiceMode,
        currentPercentage: Int,
        isPowerAdapterConnected: Bool,
        detail: String,
        updatedAt: TimeInterval,
        appliedLimitPercentage: Int? = nil,
        isHardwareSupported: Bool? = nil,
        detailReason: BatteryControlStatusReason? = nil
    ) {
        self.mode = mode
        self.currentPercentage = currentPercentage
        self.isPowerAdapterConnected = isPowerAdapterConnected
        self.detail = detail
        self.updatedAt = updatedAt
        self.appliedLimitPercentage = appliedLimitPercentage
        self.isHardwareSupported = isHardwareSupported
        self.detailReason = detailReason
    }
```

- [ ] **Step 4: Switch the engine from prose to reasons**

In `FanControlShared/BatteryControlEngine.swift`, replace the whole `detailText(isPluggedIn:target:)` method (currently at lines 198-210) with:

```swift
    private func detailReason(isPluggedIn: Bool, target: Int) -> BatteryControlStatusReason {
        if !isHardwareSupported { return .init(kind: .hardwareUnsupported) }
        if hasActionableFailure {
            // A failed release is the opposite failure from a failed apply: control IS applied and
            // stuck on, so telling the user it could not be applied would be actively misleading.
            return .init(kind: isCurrentlyInhibited ? .releaseFailed : .applyFailed)
        }
        if isCurrentlyInhibited { return .init(kind: .inhibitedAtLimit, limitPercentage: target) }
        if !config.enabled { return .init(kind: .limitDisabled) }
        return isPluggedIn
            ? .init(kind: .chargingToTarget, limitPercentage: target)
            : .init(kind: .onBatteryPower)
    }
```

Then in `status(currentSoC:isPluggedIn:target:)`, insert a local at the top of the method body, immediately before `let mode: BatteryControlServiceMode`:

```swift
        let reason = detailReason(isPluggedIn: isPluggedIn, target: target)
```

and change the `detail:` argument of the returned `BatteryControlServiceStatus` from
`detail: detailText(isPluggedIn: isPluggedIn, target: target),` to:

```swift
            // Derived from the reason so the two can never disagree — an older app reads this
            // sentence while a current one reads the code beside it.
            detail: reason.legacyKoreanDetail,
```

and add the new argument after `isHardwareSupported: isHardwareSupported`:

```swift
            isHardwareSupported: isHardwareSupported,
            detailReason: reason
```

- [ ] **Step 5: Stamp the daemon's two hand-built statuses**

In `WattlyFanDaemon/FanControlDaemon.swift`, the initializer at lines 44-49 becomes:

```swift
        self.latestBatteryStatus = BatteryControlServiceStatus(
            mode: .unavailable,
            currentPercentage: 0,
            isPowerAdapterConnected: false,
            detail: BatteryControlStatusReason(kind: .initializing).legacyKoreanDetail,
            updatedAt: 0,
            detailReason: .init(kind: .initializing)
        )
```

and the unreadable-power-source status inside `sampleBatteryAndEvaluate(force:)` (lines 181-193) becomes:

```swift
            latestBatteryStatus = BatteryControlServiceStatus(
                mode: .unsupported,
                currentPercentage: 0,
                isPowerAdapterConnected: false,
                detail: BatteryControlStatusReason(kind: .powerSourceUnreadable).legacyKoreanDetail,
                updatedAt: Date().timeIntervalSince1970,
                appliedLimitPercentage: nil,
                // A Mac whose power source cannot be read still knows whether it has a charge
                // register. Without this the app cannot tell "no battery here, stop asking" from
                // "read failed, try again", and re-pushes at the first one forever.
                isHardwareSupported: batteryEngine.isHardwareSupported,
                detailReason: .init(kind: .powerSourceUnreadable)
            )
```

- [ ] **Step 6: Run the tests**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 \
  | grep -E "error:|✘|Test run with" | tail -20
```

Expected: PASS, **655 tests in 58 suites**.

The four pre-existing `detail` assertions in `BatteryControlEngineTests.swift` (lines 271, 367, 458, 495) must still pass **unchanged** — `legacyKoreanDetail` reproduces the exact shipped wording. If one fails, the Korean copy was altered; restore it byte for byte rather than editing the test.

- [ ] **Step 7: Commit**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
git add FanControlShared/BatteryControlProtocol.swift FanControlShared/BatteryControlEngine.swift WattlyFanDaemon/FanControlDaemon.swift WattlyTests/BatteryControlProtocolTests.swift WattlyTests/BatteryControlEngineTests.swift
git commit -m "feat(battery): have the daemon report a reason code beside the sentence"
```

---

## Task 4: Recognize sentences from an already-installed helper

**Files:**
- Create: `Wattly/Core/LegacyBatteryDetail.swift`
- Test: `WattlyTests/LegacyBatteryDetailTests.swift`

**Interfaces:**
- Consumes: `BatteryControlStatusReason` (Task 2).
- Produces: `enum LegacyBatteryDetail` with `static func reason(from detail: String) -> BatteryControlStatusReason?`

- [ ] **Step 1: Write the failing test**

Create `WattlyTests/LegacyBatteryDetailTests.swift`:

```swift
import Testing
import Foundation
@testable import Wattly

/// 설치된 도우미는 앱과 따로 갱신된다 — 앱이 이미 응답하는 도우미를 교체하지 않기 때문이다.
/// 그래서 업데이트한 앱은 한동안 구버전 데몬의 한국어 문장만 받는다. 이 표는 그 문장들을
/// 되돌려 읽어서, 구버전 도우미를 쓰는 사용자도 자기 언어로 상태를 보게 한다.
@Suite struct LegacyBatteryDetailTests {

    @Test func recognizesEveryFixedSentence() {
        let table: [(String, BatteryControlStatusReason.Kind)] = [
            ("초기화 중", .initializing),
            ("전원 소스를 읽을 수 없습니다", .powerSourceUnreadable),
            ("이 Mac은 충전 제어를 지원하지 않습니다", .hardwareUnsupported),
            ("충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)", .releaseFailed),
            ("이 Mac에서 충전 제어를 적용하지 못했습니다", .applyFailed),
            ("충전 제한 비활성화됨", .limitDisabled),
            ("배터리 전원으로 구동 중", .onBatteryPower)
        ]
        for (sentence, kind) in table {
            let parsed = LegacyBatteryDetail.reason(from: sentence)
            #expect(parsed?.kind == kind, sentence)
            #expect(parsed?.limitPercentage == nil, sentence)
        }
    }

    /// 보간된 두 문장은 카탈로그 조회로는 절대 잡히지 않는다 — 이 파서만이 유일한 경로다.
    @Test func extractsTheLimitFromTheInterpolatedSentences() {
        for limit in [50, 80, 85, 100] {
            let inhibited = LegacyBatteryDetail.reason(
                from: "충전 제한 \(limit)% 도달 (전원 어댑터 바이패스 구동)")
            #expect(inhibited?.kind == .inhibitedAtLimit, "\(limit)")
            #expect(inhibited?.limitPercentage == limit, "\(limit)")

            let charging = LegacyBatteryDetail.reason(from: "목표치(\(limit)%)까지 충전 중")
            #expect(charging?.kind == .chargingToTarget, "\(limit)")
            #expect(charging?.limitPercentage == limit, "\(limit)")
        }
    }

    /// XPC 오류 설명처럼 도우미가 만든 게 아닌 문자열은 그대로 통과해야 한다 —
    /// 억지로 어떤 상태로 우겨넣으면 진짜 오류가 숨는다.
    @Test func leavesUnknownTextAlone() {
        #expect(LegacyBatteryDetail.reason(from: "Couldn’t communicate with a helper application.") == nil)
        #expect(LegacyBatteryDetail.reason(from: "") == nil)
        #expect(LegacyBatteryDetail.reason(from: "충전 제한") == nil)
        #expect(LegacyBatteryDetail.reason(from: "도우미에 연결되지 않음") == nil)
    }

    /// 껍데기는 맞는데 가운데가 숫자가 아닌 경우. nil을 돌려 원문을 그대로 보여줘야 한다.
    @Test func rejectsAMalformedLimit() {
        #expect(LegacyBatteryDetail.reason(from: "충전 제한 팔십% 도달 (전원 어댑터 바이패스 구동)") == nil)
        #expect(LegacyBatteryDetail.reason(from: "목표치(%)까지 충전 중") == nil)
        #expect(LegacyBatteryDetail.reason(from: "충전 제한 % 도달 (전원 어댑터 바이패스 구동)") == nil)
    }

    /// 현재 데몬이 내보내는 모든 문장을 이 파서가 알아봐야 한다. 이 어서션은 두 표가
    /// **오늘** 일치함을 보장할 뿐, 하나로 합쳐도 된다는 뜻이 아니다 —
    /// 파일 주석과 `BatteryControlStatusReason.legacyKoreanDetail`의 설명을 읽을 것.
    @Test func coversEveryReasonTheCurrentDaemonEmits() {
        for kind in BatteryControlStatusReason.Kind.allCases where kind != .unrecognized {
            let sentence = BatteryControlStatusReason(kind: kind, limitPercentage: 80).legacyKoreanDetail
            #expect(LegacyBatteryDetail.reason(from: sentence)?.kind == kind, "\(kind): \(sentence)")
        }
    }
}
```

- [ ] **Step 2: Regenerate the Xcode project**

`Wattly.xcodeproj/project.pbxproj` enumerates every source file individually, so a file that only
exists on disk is invisible to the build. For a **test** file this fails silently in the worst
possible way: an unreferenced test target file is never compiled, the suite goes green, and the new
tests never ran at all. Regenerate before trusting any result from this task.

Files that must become referenced:
- `Wattly/Core/LegacyBatteryDetail.swift (created in Step 4)`
- `WattlyTests/LegacyBatteryDetailTests.swift`

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
xcodegen generate
grep -c "LegacyBatteryDetailTests.swift" Wattly.xcodeproj/project.pbxproj
```

Expected: `Created project at …/Wattly.xcodeproj`, then a **non-zero** count. The daemon-embed copy
phase is declared in `project.yml`, so regeneration preserves it.

- [ ] **Step 3: Run to verify failure**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 \
  | grep -E "error:|✘|Test run with" | tail -20
```

Expected: compile FAIL — `cannot find 'LegacyBatteryDetail' in scope`.

- [ ] **Step 4: Implement the parser**

Create `Wattly/Core/LegacyBatteryDetail.swift`:

```swift
import Foundation

/// Reads the Korean status sentences that an **already-installed, older** `WattlyFanDaemon` sends,
/// and turns them back into reason codes the app can localize.
///
/// This is not belt-and-braces. Nothing in the app replaces a privileged helper that is outdated
/// but still answering — only a missing one gets installed — so a user who updates Wattly keeps
/// their old daemon, and its Korean-only `detail` field, until something else replaces it. Without
/// this table those users would read Korean in an otherwise fully translated app.
///
/// **This table is frozen.** It describes binaries already on disk (built from commit `e311a7f`),
/// which can never change retroactively. `BatteryControlStatusReason.legacyKoreanDetail` looks
/// identical today but answers a different question — what *this* build emits — and is free to be
/// reworded. Sharing one table between them means the day someone improves the copy, the app
/// silently stops recognizing every helper already installed in the field.
enum LegacyBatteryDetail {

    /// `nil` for anything not on the list, which is the right answer for XPC/system error
    /// descriptions travelling in the same field: they are already localized by macOS, and forcing
    /// them into a status code would hide a real failure behind a cheerful sentence.
    static func reason(from detail: String) -> BatteryControlStatusReason? {
        switch detail {
        case "초기화 중": return .init(kind: .initializing)
        case "전원 소스를 읽을 수 없습니다": return .init(kind: .powerSourceUnreadable)
        case "이 Mac은 충전 제어를 지원하지 않습니다": return .init(kind: .hardwareUnsupported)
        case "충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)": return .init(kind: .releaseFailed)
        case "이 Mac에서 충전 제어를 적용하지 못했습니다": return .init(kind: .applyFailed)
        case "충전 제한 비활성화됨": return .init(kind: .limitDisabled)
        case "배터리 전원으로 구동 중": return .init(kind: .onBatteryPower)
        default: break
        }

        // The two interpolated sentences. A catalog lookup can never match these — the limit is
        // baked into the string — so this is the only path that localizes them.
        if let limit = number(in: detail,
                              between: "충전 제한 ",
                              and: "% 도달 (전원 어댑터 바이패스 구동)") {
            return .init(kind: .inhibitedAtLimit, limitPercentage: limit)
        }
        if let limit = number(in: detail, between: "목표치(", and: "%)까지 충전 중") {
            return .init(kind: .chargingToTarget, limitPercentage: limit)
        }
        return nil
    }

    /// Affix matching rather than a regular expression: the surrounding copy contains `(`, `)` and
    /// `%`, all of which would need escaping, and the shape here is fixed enough that a pattern
    /// would only add ways to get it wrong.
    private static func number(in text: String, between prefix: String, and suffix: String) -> Int? {
        guard text.hasPrefix(prefix), text.hasSuffix(suffix),
              text.count > prefix.count + suffix.count else { return nil }
        let start = text.index(text.startIndex, offsetBy: prefix.count)
        let end = text.index(text.endIndex, offsetBy: -suffix.count)
        return Int(text[start..<end])
    }
}
```

- [ ] **Step 5: Run the tests**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 \
  | grep -E "error:|✘|Test run with" | tail -20
```

Expected: PASS, **660 tests in 59 suites** (the new `LegacyBatteryDetailTests`).

- [ ] **Step 6: Commit**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
git add Wattly/Core/LegacyBatteryDetail.swift WattlyTests/LegacyBatteryDetailTests.swift Wattly.xcodeproj/project.pbxproj
git commit -m "feat(battery): read status sentences from an older installed helper"
```

---

## Task 5: Render a reason as localized text

**Files:**
- Create: `Wattly/Core/BatteryStatusText.swift`
- Test: `WattlyTests/BatteryStatusTextTests.swift`

**Interfaces:**
- Consumes: `BatteryControlStatusReason` (Task 2), `LegacyBatteryDetail.reason(from:)` (Task 4), the catalog keys (Task 1), and `String.init(localized:locale:bundle:)` from `Wattly/Settings/Settings.swift:340`.
- Produces:
  - `static func BatteryStatusText.resolve(reason:detail:) -> BatteryControlStatusReason?`
  - `static func BatteryStatusText.text(reason:detail:locale:) -> String`
  - `static func BatteryStatusText.installFailureMessage(reason:detail:locale:) -> String`

- [ ] **Step 1: Write the failing test**

Create `WattlyTests/BatteryStatusTextTests.swift`:

```swift
import Testing
import Foundation
@testable import Wattly

@Suite struct BatteryStatusTextTests {
    private let en = Locale(identifier: "en")
    private let ja = Locale(identifier: "ja")
    private let ko = Locale(identifier: "ko")

    // MARK: - 어느 출처를 믿을지

    @Test func structuredReasonWinsOverTheSentence() {
        // 데몬이 코드를 보냈다면 문장은 하위 호환용 잔재다. 코드를 믿는다.
        let resolved = BatteryStatusText.resolve(
            reason: .init(kind: .onBatteryPower),
            detail: "충전 제한 비활성화됨")
        #expect(resolved?.kind == .onBatteryPower)
    }

    @Test func fallsBackToParsingTheSentence() {
        let resolved = BatteryStatusText.resolve(reason: nil, detail: "목표치(85%)까지 충전 중")
        #expect(resolved?.kind == .chargingToTarget)
        #expect(resolved?.limitPercentage == 85)
    }

    /// 신버전 데몬 + 구버전 앱이 아니라, 구버전 앱 코드가 신버전 데몬을 만난 경우.
    /// 모르는 코드는 무시하고 문장으로 되돌아가야 한다.
    @Test func unrecognizedKindDefersToTheSentence() {
        let resolved = BatteryStatusText.resolve(
            reason: .init(kind: .unrecognized),
            detail: "충전 제한 비활성화됨")
        #expect(resolved?.kind == .limitDisabled)
    }

    @Test func unknownTextResolvesToNothing() {
        #expect(BatteryStatusText.resolve(reason: nil, detail: "Connection interrupted") == nil)
    }

    // MARK: - 현지화

    @Test func rendersFixedReasonsInTheRequestedLanguage() {
        #expect(BatteryStatusText.text(reason: .init(kind: .limitDisabled), detail: "", locale: en)
                == "Charge limit off")
        #expect(BatteryStatusText.text(reason: .init(kind: .limitDisabled), detail: "", locale: ja)
                == "充電上限オフ")
        #expect(BatteryStatusText.text(reason: .init(kind: .limitDisabled), detail: "", locale: ko)
                == "충전 제한 비활성화됨")

        #expect(BatteryStatusText.text(reason: .init(kind: .onBatteryPower), detail: "", locale: en)
                == "Running on battery")
        #expect(BatteryStatusText.text(reason: .init(kind: .hardwareUnsupported), detail: "", locale: en)
                == "This Mac does not support charge control")
        #expect(BatteryStatusText.text(reason: .init(kind: .releaseFailed), detail: "", locale: en)
                == "Could not resume charging (try reconnecting the power adapter)")
        #expect(BatteryStatusText.text(reason: .init(kind: .initializing), detail: "", locale: en)
                == "Initializing")
    }

    @Test func substitutesTheLimitIntoFormattedReasons() {
        #expect(BatteryStatusText.text(reason: .init(kind: .inhibitedAtLimit, limitPercentage: 80),
                                       detail: "", locale: en)
                == "Charge limit 80% reached (running on adapter bypass)")
        #expect(BatteryStatusText.text(reason: .init(kind: .inhibitedAtLimit, limitPercentage: 80),
                                       detail: "", locale: ko)
                == "충전 제한 80% 도달 (전원 어댑터 바이패스 구동)")
        #expect(BatteryStatusText.text(reason: .init(kind: .chargingToTarget, limitPercentage: 85),
                                       detail: "", locale: en)
                == "Charging to 85%")
        #expect(BatteryStatusText.text(reason: .init(kind: .chargingToTarget, limitPercentage: 85),
                                       detail: "", locale: ko)
                == "목표치(85%)까지 충전 중")
    }

    /// 구버전 도우미를 그대로 쓰는 사용자도 자기 언어로 봐야 한다 — 이 계획의 핵심 약속.
    @Test func localizesASentenceFromAnOlderHelper() {
        #expect(BatteryStatusText.text(reason: nil, detail: "충전 제한 비활성화됨", locale: en)
                == "Charge limit off")
        #expect(BatteryStatusText.text(reason: nil,
                                       detail: "충전 제한 80% 도달 (전원 어댑터 바이패스 구동)",
                                       locale: en)
                == "Charge limit 80% reached (running on adapter bypass)")
        #expect(BatteryStatusText.text(reason: nil, detail: "목표치(85%)까지 충전 중", locale: ja)
                == "85% まで充電中")
    }

    /// 앱 자신이 쓰는 문구(`BatteryControlClient`)도 카탈로그 키다.
    @Test func localizesTheAppsOwnDetailStrings() {
        #expect(BatteryStatusText.text(reason: nil, detail: "도우미에 연결되지 않음", locale: en)
                == "Not connected to helper")
        #expect(BatteryStatusText.text(reason: nil, detail: "도우미 응답 오류", locale: en)
                == "Helper response error")
    }

    /// macOS가 만든 XPC 오류 설명은 이미 사용자 언어다. 건드리지 말고 그대로 통과.
    @Test func passesSystemErrorTextThrough() {
        let systemText = "Couldn’t communicate with a helper application."
        #expect(BatteryStatusText.text(reason: nil, detail: systemText, locale: en) == systemText)
        #expect(BatteryStatusText.text(reason: nil, detail: systemText, locale: ja) == systemText)
    }

    @Test func neverRendersEmptyForAKnownReason() {
        for kind in BatteryControlStatusReason.Kind.allCases where kind != .unrecognized {
            let text = BatteryStatusText.text(reason: .init(kind: kind, limitPercentage: 80),
                                              detail: "", locale: en)
            #expect(!text.isEmpty, "\(kind)")
        }
    }

    // MARK: - 설치 실패 문구

    @Test func buildsTheInstallFailureMessage() {
        #expect(BatteryStatusText.installFailureMessage(
                    reason: .init(kind: .hardwareUnsupported), detail: "", locale: en)
                == "Helper installed, but the charge limit could not be applied: This Mac does not support charge control")
    }

    @Test func installFailureMessageLocalizesAnOlderHelpersSentence() {
        #expect(BatteryStatusText.installFailureMessage(
                    reason: nil, detail: "이 Mac에서 충전 제어를 적용하지 못했습니다", locale: en)
                == "Helper installed, but the charge limit could not be applied: Could not apply charge control on this Mac")
    }
}
```

- [ ] **Step 2: Regenerate the Xcode project**

`Wattly.xcodeproj/project.pbxproj` enumerates every source file individually, so a file that only
exists on disk is invisible to the build. For a **test** file this fails silently in the worst
possible way: an unreferenced test target file is never compiled, the suite goes green, and the new
tests never ran at all. Regenerate before trusting any result from this task.

Files that must become referenced:
- `Wattly/Core/BatteryStatusText.swift (created in Step 4)`
- `WattlyTests/BatteryStatusTextTests.swift`

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
xcodegen generate
grep -c "BatteryStatusTextTests.swift" Wattly.xcodeproj/project.pbxproj
```

Expected: `Created project at …/Wattly.xcodeproj`, then a **non-zero** count. The daemon-embed copy
phase is declared in `project.yml`, so regeneration preserves it.

- [ ] **Step 3: Run to verify failure**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 \
  | grep -E "error:|✘|Test run with" | tail -20
```

Expected: compile FAIL — `cannot find 'BatteryStatusText' in scope`.

- [ ] **Step 4: Implement the renderer**

Create `Wattly/Core/BatteryStatusText.swift`:

```swift
import Foundation

/// Turns a charge-limit status into text in the user's language.
///
/// This is the app-side half of the split introduced by
/// `FanControlShared/BatteryControlStatusReason.swift`: the root daemon reports *why* the limit is
/// in the state it is in, and this decides *what that says* — the only place that can, since it is
/// the only one of the two processes with resources and a locale.
///
/// Pure and locale-injected, like `CardPresentation` / `Accessibility` / `MenuBarText`, so every
/// language it can produce is reachable from a test rather than only from a running app.
enum BatteryStatusText {

    /// Which reason to believe, given a status that may carry a code, a sentence, or both.
    ///
    /// Order matters. A code from the running helper is authoritative; the sentence is either the
    /// back-compat copy beside it or — on a helper too old to send a code — the only thing there.
    /// `nil` means the text is not ours at all (a macOS XPC error description, say), and the caller
    /// should show it as it stands.
    static func resolve(reason: BatteryControlStatusReason?,
                        detail: String) -> BatteryControlStatusReason? {
        if let reason, reason.kind != .unrecognized { return reason }
        return LegacyBatteryDetail.reason(from: detail)
    }

    static func text(reason: BatteryControlStatusReason?,
                     detail: String,
                     locale: Locale) -> String {
        guard let resolved = resolve(reason: reason, detail: detail) else {
            // Not a status of ours. A catalog lookup still gets the app's own `detail` literals
            // translated, and returns anything else — system error text, already localized by
            // macOS — untouched.
            return String(localized: detail, locale: locale)
        }

        // Mirrors `BatteryControlStatusReason.legacyKoreanDetail`, but every arm is a catalog key.
        let target = Int64(resolved.limitPercentage ?? 100)
        switch resolved.kind {
        case .initializing:
            return String(localized: "초기화 중", locale: locale)
        case .powerSourceUnreadable:
            return String(localized: "전원 소스를 읽을 수 없습니다", locale: locale)
        case .hardwareUnsupported:
            return String(localized: "이 Mac은 충전 제어를 지원하지 않습니다", locale: locale)
        case .releaseFailed:
            return String(localized: "충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)",
                          locale: locale)
        case .applyFailed:
            return String(localized: "이 Mac에서 충전 제어를 적용하지 못했습니다", locale: locale)
        case .inhibitedAtLimit:
            return String(format: String(localized: "충전 제한 %lld%% 도달 (전원 어댑터 바이패스 구동)",
                                         locale: locale),
                          locale: locale, target)
        case .limitDisabled:
            return String(localized: "충전 제한 비활성화됨", locale: locale)
        case .chargingToTarget:
            return String(format: String(localized: "목표치(%lld%%)까지 충전 중", locale: locale),
                          locale: locale, target)
        case .onBatteryPower:
            return String(localized: "배터리 전원으로 구동 중", locale: locale)
        case .unrecognized:
            // `resolve` never returns this, but the switch has to be total. Falling back to the
            // sentence is what the caller would want anyway.
            return String(localized: detail, locale: locale)
        }
    }

    /// The alert body for an install that succeeded while the configuration push did not. The
    /// embedded status goes through `text(reason:detail:locale:)` first, so the sentence is not
    /// half-translated.
    static func installFailureMessage(reason: BatteryControlStatusReason?,
                                      detail: String,
                                      locale: Locale) -> String {
        String(format: String(localized: "도우미는 설치했지만 충전 제한을 적용하지 못했습니다: %@",
                              locale: locale),
               locale: locale,
               text(reason: reason, detail: detail, locale: locale))
    }
}
```

Note on `String(format:locale:_:)`: passing the locale is what makes `%lld` render in the digits the language actually uses (Arabic-Indic for `ar`, Devanagari for `hi`), matching how SwiftUI's own `Text` interpolation behaves elsewhere in the app.

- [ ] **Step 5: Run the tests**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 \
  | grep -E "error:|✘|Test run with" | tail -20
```

Expected: PASS, **672 tests in 60 suites** (the new `BatteryStatusTextTests`).

- [ ] **Step 6: Commit**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
git add Wattly/Core/BatteryStatusText.swift WattlyTests/BatteryStatusTextTests.swift Wattly.xcodeproj/project.pbxproj
git commit -m "feat(battery): render the charge limit status in the user's language"
```

---

## Task 6: Make the presentation layer locale-aware

**Files:**
- Modify: `Wattly/Core/BatterySectionPresentation.swift:26, 56-89`
- Test: `WattlyTests/BatterySectionPresentationTests.swift`

**Interfaces:**
- Consumes: `BatteryStatusText.text(reason:detail:locale:)` (Task 5).
- Produces:
  - `BatterySectionPresentation.status(isLimitOn:isInstalling:mode:reason:detail:locale:) -> Status` (replaces the `detail:`-only signature)
  - `BatterySectionPresentation.disabledStatusText(locale:) -> String` (replaces the `static let`)
  - `BatterySectionPresentation.limitPickerDisabledReason(isLimitOn:)` — **unchanged**; it returns a catalog key that the view resolves via `LocalizedStringKey`.

- [ ] **Step 1: Update the existing tests to the new signature**

In `WattlyTests/BatterySectionPresentationTests.swift`:

1. Add a locale constant at the top of the suite body:

```swift
    private let en = Locale(identifier: "en")
    private let ko = Locale(identifier: "ko")
```

2. Every one of the **6** `BatterySectionPresentation.status(` call sites gains `reason: nil,` before `detail:` and `locale: ko` at the end, so the existing Korean expectations keep holding. For example the `installingOutranksEverything` test becomes:

```swift
    @Test func installingOutranksEverything() {
        // 설치 중에는 토글이 이미 ON이지만, 순서가 뒤집히면 설치 진행 표시가 사라진다.
        for isOn in [true, false] {
            let s = BatterySectionPresentation.status(isLimitOn: isOn, isInstalling: true,
                                                     mode: .unavailable,
                                                     reason: nil, detail: "도우미에 연결되지 않음",
                                                     locale: ko)
            #expect(s == .init(dot: .orange, text: "도우미 설치 중…"))
        }
    }
```

3. Replace any reference to `BatterySectionPresentation.disabledStatusText` with `BatterySectionPresentation.disabledStatusText(locale: ko)`.

4. Add these new tests to the suite:

```swift
    // MARK: - 현지화 (plan 2026-08-23)

    @Test func statusTextFollowsTheLocale() {
        let s = BatterySectionPresentation.status(isLimitOn: true, isInstalling: false,
                                                  mode: .charging,
                                                  reason: .init(kind: .chargingToTarget, limitPercentage: 80),
                                                  detail: "목표치(80%)까지 충전 중",
                                                  locale: en)
        #expect(s == .init(dot: .green, text: "Charging to 80%"))
    }

    @Test func installingTextIsLocalized() {
        let s = BatterySectionPresentation.status(isLimitOn: true, isInstalling: true,
                                                  mode: .unavailable, reason: nil, detail: "",
                                                  locale: en)
        #expect(s == .init(dot: .orange, text: "Installing helper…"))
    }

    /// 도우미가 없는데 기능도 꺼져 있으면 고장이 아니다 — 그 대체 문구도 번역돼야 한다.
    @Test func disabledSubstituteTextIsLocalized() {
        #expect(BatterySectionPresentation.disabledStatusText(locale: en) == "Charge limit off")
        #expect(BatterySectionPresentation.disabledStatusText(locale: ko) == "충전 제한 비활성화됨")

        let s = BatterySectionPresentation.status(isLimitOn: false, isInstalling: false,
                                                  mode: .unavailable,
                                                  reason: nil, detail: "도우미에 연결되지 않음",
                                                  locale: en)
        #expect(s == .init(dot: .faint, text: "Charge limit off"))
    }

    /// 껐는데 하드웨어가 아직 물고 있는 상태. 회복 안내가 사라지지도, 한국어로 남지도 않아야 한다.
    @Test func stuckAfterTurningOffStaysLoudAndTranslated() {
        let s = BatterySectionPresentation.status(isLimitOn: false, isInstalling: false,
                                                  mode: .unsupported,
                                                  reason: .init(kind: .releaseFailed),
                                                  detail: "충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)",
                                                  locale: en)
        #expect(s == .init(dot: .orange,
                           text: "Could not resume charging (try reconnecting the power adapter)"))
    }

    /// 한도 선택기의 사유는 **카탈로그 키**로 남는다. 뷰가 `LocalizedStringKey`로 푼다.
    @Test func limitPickerReasonStaysAKey() {
        #expect(BatterySectionPresentation.limitPickerDisabledReason(isLimitOn: false)
                == "충전 제한을 켜면 한도를 조절할 수 있습니다.")
    }
```

- [ ] **Step 2: Run to verify failure**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 \
  | grep -E "error:|✘|Test run with" | tail -20
```

Expected: compile FAIL — `extra argument 'locale' in call` on the `status(...)` sites.

- [ ] **Step 3: Update `BatterySectionPresentation`**

In `Wattly/Core/BatterySectionPresentation.swift`:

Add `import Foundation` if the file does not already have it (it does).

Replace the `disabledStatusText` constant (line 26) with:

```swift
    /// 도우미가 없어서 모드가 `.unavailable`일 때만 쓰는 대체 문구. 사용자가 일부러 끈 기능 옆에
    /// "도우미에 연결되지 않음"을 띄우면 고장으로 읽히기 때문이다. 정상적으로 꺼진 상태
    /// (`.charging`)에서는 데몬이 이미 같은 사유를 돌려주지만, 그 값 자체는 그대로 통과시키므로
    /// 여기 문구와 반드시 같게 유지해야 하는 것은 아니다.
    static func disabledStatusText(locale: Locale) -> String {
        BatteryStatusText.text(reason: .init(kind: .limitDisabled), detail: "", locale: locale)
    }
```

Replace the `status(...)` signature and its two `detail`-passthrough bodies. The full replacement for the method (keeping its existing doc comment above it verbatim):

```swift
    static func status(isLimitOn: Bool,
                       isInstalling: Bool,
                       mode: BatteryControlServiceMode,
                       reason: BatteryControlStatusReason?,
                       detail: String,
                       locale: Locale) -> Status {
        // 데몬의 사유/문장을 사용자 언어로 푼 것. 아래 모든 분기가 이 값을 쓴다.
        let resolved = BatteryStatusText.text(reason: reason, detail: detail, locale: locale)

        if isInstalling {
            return Status(dot: .orange, text: String(localized: "도우미 설치 중…", locale: locale))
        }
        if !isLimitOn {
            switch mode {
            case .unavailable:
                // 도우미가 없다는 사실은 사용자가 일부러 끈 기능과 무관하다. 빨간 점 +
                // "도우미에 연결되지 않음"을 여기 띄우면 고장으로 읽힌다.
                return Status(dot: .faint, text: disabledStatusText(locale: locale))
            case .charging:
                // 정상적으로 꺼진 상태. 데몬의 사유가 이미 `limitDisabled`이므로 그대로 통과시킨다.
                return Status(dot: .faint, text: resolved)
            case .inhibited, .unsupported:
                // 껐는데 하드웨어가 아직 물고 있거나 해제 쓰기가 실패한 상태. 회색 점 + "비활성화됨"으로
                // 덮으면 충전을 멈춘 Mac을 두고 "정상적으로 꺼졌다"고 단언하는 셈이 된다.
                // 이때 사유는 `releaseFailed`이며, 그게 사용자가 할 수 있는 유일한 복구 안내다.
                return Status(dot: .orange, text: resolved)
            }
        }
        switch mode {
        case .inhibited: return Status(dot: .orange, text: resolved)
        case .charging: return Status(dot: .green, text: resolved)
        case .unavailable: return Status(dot: .red, text: resolved)
        case .unsupported: return Status(dot: .faint, text: resolved)
        }
    }
```

- [ ] **Step 4: Run the tests**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 \
  | grep -E "error:|✘|Test run with" | tail -20
```

Expected: compile FAIL in `SettingsBatterySection.swift` — its `status(...)` call has no `reason:`/`locale:`. **This is expected**; Task 8 fixes it. To keep this task independently verifiable, apply the minimal call-site repair now (the full view work stays in Task 8):

In `Wattly/Views/Settings/SettingsBatterySection.swift`, add near the other `@Environment` properties:

```swift
    @Environment(\.locale) private var locale
```

and update the `resolvedStatus` computed property to pass the two new arguments:

```swift
    private var resolvedStatus: BatterySectionPresentation.Status {
        BatterySectionPresentation.status(
            isLimitOn: batteryLimitEnabled,
            isInstalling: batteryControl.isInstallingHelper,
            mode: batteryControl.status.mode,
            reason: batteryControl.status.detailReason,
            detail: batteryControl.status.detail,
            locale: locale)
    }
```

Re-run. Expected: PASS, **677 tests in 60 suites**.

- [ ] **Step 5: Commit**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
git add Wattly/Core/BatterySectionPresentation.swift Wattly/Views/Settings/SettingsBatterySection.swift WattlyTests/BatterySectionPresentationTests.swift
git commit -m "feat(battery): resolve the settings status line against the active locale"
```

---

## Task 7: A structured install failure

**Files:**
- Modify: `Wattly/Control/BatteryControlClient.swift:73-89`
- Test: `WattlyTests/BatteryControlClientTests.swift`

**Interfaces:**
- Consumes: `BatteryControlStatusReason` (Task 2).
- Produces: `BatteryControlClient.InstallFailure` (enum, `Error`) with cases `install(any Error)` and `configureRejected(reason: BatteryControlStatusReason?, detail: String)`; `installAndApply(enabled:limitPercentage:window:)` now returns `InstallFailure?` instead of `Error?`.

**Why:** the current code builds `"도우미는 설치했지만 …: \(status.detail)"` by interpolation inside the client. An interpolated string can never be a catalog key, and the client — an `@Observable` model, not a view — has no locale to resolve one with. Handing the view the pieces lets the view, which does have a locale, do the formatting.

- [ ] **Step 1: Write the failing test**

Append to `WattlyTests/BatteryControlClientTests.swift`, inside its existing suite:

```swift
    @MainActor
    @Test func installFailureCarriesTheStatusRatherThanAKoreanSentence() async {
        // 도우미는 설치됐지만 설정 푸시가 거부된 상황. 클라이언트는 문장을 조립하지 않고
        // 사유와 원문을 그대로 넘겨야 한다 — 언어를 아는 쪽은 뷰다.
        let client = BatteryControlClient(requestHandler: { _ in
            let status = BatteryControlServiceStatus(
                mode: .unsupported,
                currentPercentage: 70,
                isPowerAdapterConnected: true,
                detail: "이 Mac에서 충전 제어를 적용하지 못했습니다",
                updatedAt: 1,
                appliedLimitPercentage: nil,
                isHardwareSupported: true,
                detailReason: .init(kind: .applyFailed))
            return (try? BatteryControlCodec.encode(status), nil)
        })
        await client.apply(enabled: true, limitPercentage: 80)

        let failure = BatteryControlClient.InstallFailure.configureRejected(
            reason: client.status.detailReason, detail: client.status.detail)
        guard case .configureRejected(let reason, let detail) = failure else {
            Issue.record("expected .configureRejected")
            return
        }
        #expect(reason?.kind == .applyFailed)
        #expect(detail == "이 Mac에서 충전 제어를 적용하지 못했습니다")

        #expect(BatteryStatusText.installFailureMessage(reason: reason, detail: detail,
                                                        locale: Locale(identifier: "en"))
                == "Helper installed, but the charge limit could not be applied: Could not apply charge control on this Mac")
    }
```

- [ ] **Step 2: Run to verify failure**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 \
  | grep -E "error:|✘|Test run with" | tail -20
```

Expected: compile FAIL — `type 'BatteryControlClient' has no member 'InstallFailure'`.

- [ ] **Step 3: Add the failure type and change the return**

In `Wattly/Control/BatteryControlClient.swift`, add inside the class, next to `BatteryControlClientRequest`:

```swift
    /// Why enabling the limit did not take. Kept structured rather than pre-rendered: the message
    /// embeds the helper's status, and only the view knows what language to build it in.
    public enum InstallFailure: Error {
        /// The privileged install itself failed or was cancelled. `localizedDescription` is either
        /// a catalog key from `FanHelperInstaller.InstallError` or text macOS already localized.
        case install(any Error)
        /// The helper installed and answered, but would not take the configuration.
        case configureRejected(reason: BatteryControlStatusReason?, detail: String)
    }
```

Replace `installAndApply` (lines 73-89) with:

```swift
    /// Installs the privileged helper with one admin-auth prompt and immediately pushes the user's
    /// configuration — without this the helper would sit at its disabled default while the toggle
    /// reads ON. `enabled` is the caller's real opt-in rather than an assumption, so installing from
    /// a recovery button can never switch the limit on behind the user's back.
    /// Returns `nil` only when both halves landed.
    public func installAndApply(enabled: Bool, limitPercentage: Int, window: NSWindow?) async -> InstallFailure? {
        isInstallingHelper = true
        defer { isInstallingHelper = false }
        if let failure = await PrivilegedHelperInstallSession.run(window: window, postInstall: {
            await self.apply(enabled: enabled, limitPercentage: limitPercentage)
        }) {
            return .install(failure)
        }
        // Installing is only half of it — the configure push is what actually engages the limit.
        // Reporting success here would leave the toggle ON over a helper that is doing nothing.
        guard status.mode != .unavailable else {
            return .configureRejected(reason: status.detailReason, detail: status.detail)
        }
        return nil
    }
```

- [ ] **Step 4: Run the tests**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 \
  | grep -E "error:|✘|Test run with" | tail -20
```

Expected: compile FAIL in `SettingsBatterySection.swift` — `installErrorMessage = failure.localizedDescription` no longer type-checks against `InstallFailure`. Task 8 owns that. Apply the minimal repair now at **both** call sites (the toggle handler and the recovery button), replacing `installErrorMessage = failure.localizedDescription` with:

```swift
                            installErrorMessage = Self.message(for: failure, locale: locale)
```

and add this helper to `SettingsBatterySection`:

```swift
    /// 설치 실패 문구. `.install`은 설치기 자신의 오류(카탈로그 키이거나 macOS가 이미 현지화한
    /// 문장)이고, `.configureRejected`는 도우미 상태를 문장 안에 끼워 넣어야 한다.
    private static func message(for failure: BatteryControlClient.InstallFailure,
                                locale: Locale) -> String {
        switch failure {
        case .install(let error):
            return String(localized: error.localizedDescription, locale: locale)
        case .configureRejected(let reason, let detail):
            return BatteryStatusText.installFailureMessage(reason: reason, detail: detail,
                                                           locale: locale)
        }
    }
```

Re-run. Expected: PASS, **678 tests in 60 suites**.

- [ ] **Step 5: Commit**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
git add Wattly/Control/BatteryControlClient.swift Wattly/Views/Settings/SettingsBatterySection.swift WattlyTests/BatteryControlClientTests.swift
git commit -m "feat(battery): hand the view a structured install failure to translate"
```

---

## Task 8: Fix the settings view's render sites

**Files:**
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift:63, 116-119, 130`
- Test: manual verification (SwiftUI body rendering has no unit-test seam in this project; the pure layers it calls are covered by Tasks 5-7).

**Interfaces:**
- Consumes: `BatteryStatusText` (Task 5), `BatterySectionPresentation` (Task 6), `BatteryControlClient.InstallFailure` (Task 7).
- Produces: nothing new.

**What is left after Tasks 6-7:** the view already has `@Environment(\.locale)`, passes `reason:`/`locale:` into the presentation layer, and formats install failures. Three render sites still drop localization.

- [ ] **Step 1: Localize the alert body**

`Text(installErrorMessage)` at line ~118 is correct **as long as** `installErrorMessage` is already resolved — which it now is, via `Self.message(for:locale:)`. Make that explicit so a future reader does not "fix" it into a lookup:

```swift
        } message: {
            // 이미 `Self.message(for:locale:)`로 해석된 문자열이다. `LocalizedStringKey`로
            // 감싸면 두 번 조회하게 되고, 보간된 문장은 키가 없어 그대로 통과할 뿐이다.
            Text(verbatim: installErrorMessage)
        }
```

- [ ] **Step 2: Make the status line's verbatim rendering explicit**

At line ~130, `Text(resolved.text)` is likewise already-localized. Change it to:

```swift
            // `BatterySectionPresentation.status(…)`가 로케일까지 반영해 만든 최종 문자열이다.
            Text(verbatim: resolved.text)
```

- [ ] **Step 3: Confirm the key-based sites resolve**

These four need **no code change** — they hand a `String` to an API that converts it to `LocalizedStringKey`, and Task 1 supplied the keys. Read each and confirm it is untouched and correct:

- `SettingsSection(title: "배터리 충전 제어")` — `SettingsComponents.swift:254` takes `String` and wraps it.
- `SettingsRowTitle("배터리 충전 제한")` — `SettingsComponents.swift:346` wraps it.
- `.alert("도우미 설치 실패", …)` and `Button("확인", role: .cancel)` — SwiftUI string literals become `LocalizedStringKey` at compile time.
- The two `Text("…")` string **literals** (the feature description at line ~33 and the advisory banner at line ~174) and `Text("최대 충전 한도")` — SwiftUI literals localize automatically.

The one remaining `disabledReason:` argument at line 29 (`"이 Mac은 충전 제어를 지원하지 않습니다"`) stays a Korean **key**; Task 9 makes `SettingsToggleRow` resolve it.

- [ ] **Step 4: Build and run the suite**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 \
  | grep -E "error:|✘|Test run with" | tail -20
```

Expected: PASS, **678 tests** — no count change; this task is render-site wiring.

- [ ] **Step 5: Verify on screen**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' build -quiet 2>&1 | tail -5
open "$(xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/ {print $3}')/Wattly.app"
```

Then in the menubar → Settings → 일반 → 언어, switch to **English** and open the 배터리 충전 제어 section. Expected: section title "Battery Charge Control", row "Battery Charge Limit", the description sentence, "Maximum Charge Limit", the advisory banner, and the status line all in English. Switch to 日本語 and confirm the same.

**Note:** the status line is the one string that depends on the **installed daemon**, not on the app build. If the installed helper predates Task 3 it sends no `detailReason`, and the `LegacyBatteryDetail` path from Task 4 is what translates it — which is exactly the case worth eyeballing here. Both paths must read English.

- [ ] **Step 6: Commit**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
git add Wattly/Views/Settings/SettingsBatterySection.swift
git commit -m "fix(battery): stop dropping localization at the settings render sites"
```

---

## Task 9: Localize the shared controls' VoiceOver copy

**Files:**
- Modify: `Wattly/Views/SettingsComponents.swift:148, 201, 328, 330`
- Test: manual VoiceOver verification + the Task 1 catalog assertions

**Interfaces:**
- Consumes: catalog keys `켜짐`, `꺼짐`, `사용할 수 없습니다` (Task 1).
- Produces: nothing new.

**Why this is in scope:** `SettingsToggleRow` and `WattlySegment` are the controls the battery section is built from, and the battery section passes them Korean `disabledReason` keys. Their `.accessibilityHint(_:)` / `.accessibilityValue(_:)` calls take `String`, whose overload renders verbatim — so a VoiceOver user running the app in English hears Korean in the middle of the battery row. The `Text` overloads localize.

Three other sections (`SettingsDisplaySection`, `SettingsMenuBarSection`, `SettingsThresholdSection`) pass `disabledReason` Korean keys too and get fixed for free by the same change. Their own keys are **not** part of this plan's catalog additions and stay Korean until the app-wide sweep — except `이 Mac에서는 사용할 수 없습니다`, which is already in the catalog.

- [ ] **Step 1: Localize the three `accessibilityHint` sites**

At `SettingsComponents.swift` lines 148, 201, and 330 the expression is identical:

```swift
            .accessibilityHint(isEnabled ? "" : (disabledReason ?? "사용할 수 없습니다"))
```

Replace each with:

```swift
            // `disabledReason`은 호출부가 넘긴 **카탈로그 키**다 (예: "이 Mac은 충전 제어를
            // 지원하지 않습니다"). `String` 오버로드는 조회 없이 그대로 읽으므로,
            // 영어로 쓰는 VoiceOver 사용자에게 한국어가 들린다.
            .accessibilityHint(isEnabled
                               ? Text(verbatim: "")
                               : Text(LocalizedStringKey(disabledReason ?? "사용할 수 없습니다")))
```

- [ ] **Step 2: Localize the on/off value**

At line 328:

```swift
        .accessibilityValue(isOn ? "켜짐" : "꺼짐")
```

becomes:

```swift
        .accessibilityValue(Text(LocalizedStringKey(isOn ? "켜짐" : "꺼짐")))
```

- [ ] **Step 3: Build and run the suite**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 \
  | grep -E "error:|✘|Test run with" | tail -20
```

Expected: PASS, **678 tests**.

If the compiler reports an ambiguity on `.accessibilityHint`, the ternary's branches must both be `Text` — check that the `isEnabled` branch is `Text(verbatim: "")` and not `""`.

- [ ] **Step 4: Verify with VoiceOver**

Launch the app (command in Task 8 Step 5), set the language to English, turn VoiceOver on with `Cmd+F5`, and tab to the 배터리 충전 제한 toggle.

Expected to hear: "Battery Charge Limit, On" (or "Off"). On a Mac with no charge register, the row is disabled and the hint reads "This Mac does not support charge control". Nothing Korean.

Turn VoiceOver off with `Cmd+F5`.

- [ ] **Step 5: Commit**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
git add Wattly/Views/SettingsComponents.swift
git commit -m "fix(a11y): localize the shared controls' VoiceOver state and hints"
```

---

## Final verification

- [ ] **Full suite**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 \
  | grep -E "error:|✘|Test run with" | tail -20
```

Expected: **678 tests in 60 suites**, 0 failures.

- [ ] **No Korean literal left unaccounted for in the feature**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
python3 - <<'PY'
import json, re, subprocess
cat = json.load(open('Wattly/Resources/Localizable.xcstrings'))
keys = set(cat['strings'])
files = ["FanControlShared/BatteryControlEngine.swift",
         "FanControlShared/BatteryControlStatusReason.swift",
         "Wattly/Control/BatteryControlClient.swift",
         "Wattly/Core/BatterySectionPresentation.swift",
         "Wattly/Core/BatteryStatusText.swift",
         "Wattly/Core/LegacyBatteryDetail.swift",
         "Wattly/Views/Settings/SettingsBatterySection.swift",
         "Wattly/Control/FanHelperInstaller.swift"]
hangul, lit = re.compile(r'[가-힣]'), re.compile(r'"((?:[^"\\]|\\.)*)"')
bad = []
for f in files:
    body = "\n".join(l for l in open(f).read().split("\n") if not l.strip().startswith("//"))
    for m in lit.finditer(body):
        v = m.group(1)
        if hangul.search(v) and v not in keys and "\\(" not in v:
            bad.append((f, v))
print("unaccounted Korean literals:", len(bad))
for f, v in bad:
    print("  ", f, "->", repr(v))
PY
```

Expected: `unaccounted Korean literals: 0`.

The two files that legitimately hold Korean sentences **not** in the catalog are the frozen legacy tables — `BatteryControlStatusReason.legacyKoreanDetail` and `LegacyBatteryDetail` — but their sentences are all catalog keys too, so they pass. Any literal this reports is a real gap.

- [ ] **Catalog completeness**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
python3 -c "
import json
d = json.load(open('Wattly/Resources/Localizable.xcstrings'))
t = len(d['strings'])
langs = {}
for v in d['strings'].values():
    for l in v.get('localizations', {}): langs[l] = langs.get(l, 0) + 1
print('keys:', t, '| languages:', len(langs), '| incomplete:', {l: c for l, c in langs.items() if c != t} or 'none')
"
```

Expected: `keys: 227 | languages: 30 | incomplete: none` (196 pre-existing + 31 new, confirmed during Task 1).

- [ ] **Daemon carries no localization dependency**

```bash
cd /Users/hyunjun_macbook_pro/Documents/Project/project_wattly
grep -rn "String(localized:\|LocalizedStringKey\|NSLocalizedString\|Bundle.main" FanControlShared/ WattlyFanDaemon/ || echo "clean — no localization API in shared or daemon code"
```

Expected: `clean — …`. A hit here means localization leaked into a process that cannot do it.

- [ ] **Manual: language round-trip**

With the app running, switch 설정 → 일반 → 언어 through 한국어 → English → 日本語 → Deutsch, checking the 배터리 충전 제어 section each time. Every string must change; none may stay Korean.

---

## Out of scope (deliberately)

State these in the PR description so a reviewer does not read them as oversights:

1. **The other 182 untranslated literals** across 34 files (fan curve editor, auto-updater, metric providers, menubar icon copy, several VoiceOver strings). `scripts/add_localizations.py` and the reason/render split established here are the pattern to reuse.
2. **Forcing a helper reinstall when the installed daemon is outdated.** This branch already established that the app only reinstalls a *missing* helper. Until that changes, users keep an older daemon and depend on `LegacyBatteryDetail` — which is why Task 4 exists. Fixing it properly needs an admin-auth prompt and a version handshake, and belongs in its own change.
3. **Translation review by native speakers.** The 30 languages here are machine-authored against the catalog's existing register. The `en` / `ja` / `de` / `zh-Hans` / `fr` values that tests pin are the reviewed subset.
