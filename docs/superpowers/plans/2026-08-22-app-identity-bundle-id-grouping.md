# App Identity — Bundle-ID Grouping & Real App Names Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the memory / power Top-N lists group each app by its `CFBundleIdentifier` and label it with the app's real `CFBundleName`, so Claude Code shows as one **"Claude Code"** row instead of a lowercase **"claude"** row that reads like a duplicate of the desktop **"Claude"** app — and so an app never splits into two rows just because its install path carries a version number.

**Architecture:** Both Top-N sweeps currently coalesce per-pid metrics by the *outermost `.app` path* and label the row with that path's basename (`appBundlePath` + `appDisplayName`). That is wrong on two counts: the path can carry a version (`…/claude-code/2.1.237/claude.app`), and the bundle *directory* name is not the app's name (`claude.app` → `claude`, but the app is called `Claude Code`). This plan introduces one shared `AppIdentity` value — `key` (bundle id, else path, else `PID n`), `name` (`CFBundleDisplayName`/`CFBundleName`, else path basename), `iconPath` (the bundle path) — derived by a pure function from already-read Info.plist values, with the plist read itself memoised per bundle path in an injectable `BundleMetadataCache` that each provider actor owns. The two pure ranking functions (`topMemoryApps`, `topAppPower`) switch from keying on a `String` path to keying on `AppIdentity.key` while carrying the group's representative identity through to the row. **The views need no changes** — they already read `name` and `iconPath` off the row models.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Swift Testing (`import Testing`), XcodeGen project, macOS 14.0 deploy target, Apple Silicon only.

## Global Constraints

- **Swift 6 language mode**, deploy target macOS **14.0** — everything must compile clean under `-swift-version 6`.
- **No new entitlements, no private API.** `CFBundleCopyInfoDictionaryForURL` is public CoreFoundation. Do **not** reach for `NSRunningApplication`, `LSCopyApplicationURLsForBundleIdentifier`, or the private responsible-pid API — the existing no-entitlement path-based resolution stays the input.
- **Graceful degradation, never a fake value:** an unreadable path → the existing `PID n` fallback group; an unreadable/absent Info.plist → fall back to the current path-derived key and name. A malformed plist with empty-string values must be treated as absent, not collapsed into an empty key.
- **Two new files** (`Wattly/Core/AppIdentity.swift`, `WattlyTests/AppIdentityTests.swift`) → **`xcodegen generate` is REQUIRED** in Task 1. Both targets use directory globs (`sources: - path: Wattly` / `- path: WattlyTests`) with classic source lists, so a new file is invisible to the build until the project is regenerated.
- **Behaviour that must NOT change:** Claude Desktop (`com.anthropic.claudefordesktop`) and Claude Code (`com.anthropic.claude-code`) stay **two separate rows** — they are two different programs. This plan fixes their *labels* and *key stability*, it does not merge them (decided at the plan's decision checkpoint).
- **Icons stay as-is:** the Claude Code bundle ships no icon resource, so `NSWorkspace` returns the generic executable icon. That is accepted — no SF Symbol substitution, no parent-app icon inheritance (decided at the plan's decision checkpoint).
- **Verified facts (do not re-derive; measured on this Mac 2026-08-22):**
  - `/Applications/Claude.app` → id `com.anthropic.claudefordesktop`, name `Claude`.
  - `~/Library/Application Support/Claude/claude-code/2.1.237/claude.app` → id `com.anthropic.claude-code`, name `Claude Code`.
  - `CFBundleCopyInfoDictionaryForURL(_:) as? [String: Any]` compiles and works under `-swift-version 6`; a non-bundle path (`/usr/sbin/cfprefsd`) and a missing bundle both yield `nil`.
  - Cost ≈ **0.21 ms per call** → a cache is required (the memory sweep touches ~560 pids per poll).
  - Sorting equal-watt groups by key ascending puts `"PID 2"` **before** `"com.example.b"` (ASCII `P` 0x50 < `c` 0x63) — the opposite of the old path-keyed order (`"/…"` < `"PID"`). Tests must expect the new order.

**Build / test commands** (run from the worktree root):

```bash
/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml
```

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
```

To run a single Swift Testing case, filter by name:

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/AppIdentityTests/identityPrefersBundleIDAndBundleName
```

---

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `Wattly/Core/AppIdentity.swift` | **NEW.** Everything that answers "which app does this process belong to": the `AppIdentity` value, the pure derivation, the two moved path helpers, the Info.plist read, and its memo. | **Create** |
| `Wattly/Core/MemoryUsage.swift` | Pure memory derivations | **Remove** `appBundlePath` (moved); **rewrite** `topMemoryApps` to key on `AppIdentity` |
| `Wattly/Core/ProcessPower.swift` | Pure per-app power ranking | **Remove** `appDisplayName` (moved); **rewrite** `topAppPower` to key on `AppIdentity` |
| `Wattly/Providers/MemoryProvider.swift` | Real memory I/O (actor) | **Add** an actor-owned `BundleMetadataCache`; `topMemoryProcesses` becomes an instance method building identities |
| `Wattly/Providers/PowerProvider.swift` | Real power I/O (actor) | **Add** an actor-owned `BundleMetadataCache`; `processPower` builds identities instead of a `[pid: String]` key map |
| `Wattly/Providers/FakeProvider.swift` | Dev/preview synthetic samples | **Update** the synthetic memory rows to the new id shape (bundle id as `id`, path as `iconPath`) |
| `WattlyTests/AppIdentityTests.swift` | **NEW.** Pure identity derivation + the cache + the real plist reader | **Create** |
| `WattlyTests/MemoryUsageTests.swift` | Pure memory tests | **Move out** the `appBundlePath` case; **rewrite** the three `topMemoryApps` cases; **add** the Claude/Claude Code regression case |
| `WattlyTests/ProcessPowerTests.swift` | Pure power tests | **Move out** the `appDisplayName` case; **rewrite** the three `topAppPower` cases |
| `Wattly/Views/CardExpandRegion.swift` | Expand rows + icons | **No change** — already renders `p.name` / `p.iconPath` |

---

## Task 1: `AppIdentity` — the pure identity value and its derivation

Creates the new home for app-identity logic and moves the two existing pure helpers into it, so the memory and power files stop each owning a piece of the same concern. Nothing is wired yet: after this task the app behaves exactly as before.

**Files:**
- Create: `Wattly/Core/AppIdentity.swift`
- Create: `WattlyTests/AppIdentityTests.swift`
- Modify: `Wattly/Core/MemoryUsage.swift` (delete `appBundlePath`, lines 104–116 including its doc comment)
- Modify: `Wattly/Core/ProcessPower.swift` (delete `appDisplayName`, lines 52–57 including its doc comment)
- Modify: `WattlyTests/MemoryUsageTests.swift` (delete the `appBundlePath` case + its `// MARK:`, lines 199–212)
- Modify: `WattlyTests/ProcessPowerTests.swift` (delete the `appDisplayNameStripsDotApp` case, lines 72–76)

**Interfaces:**
- Consumes: nothing (first task).
- Produces:
  - `struct AppIdentity: Sendable, Equatable { var key: String; var name: String; var iconPath: String? }`
  - `func appBundlePath(forExecutable path: String) -> String?` (moved verbatim)
  - `func appDisplayName(forKey key: String) -> String` (moved verbatim)
  - `func appIdentity(bundlePath: String?, pid: Int32, bundleID: String?, bundleName: String?) -> AppIdentity`

> **Why a move and not a copy:** these are module-scope free functions. Leaving a copy behind is a redeclaration error — delete the original in the same step.

- [ ] **Step 1: Write the failing test file**

Create `WattlyTests/AppIdentityTests.swift`:

```swift
import Testing
@testable import Wattly

/// Pure app-identity derivation — no filesystem, no libproc. Who an app *is* (its grouping
/// key, its row label, its icon path) was previously derived from the executable PATH alone,
/// which split one app into two rows whenever the path carried a version and labelled rows
/// with a bundle DIRECTORY name instead of the app's real name. The Info.plist read and its
/// memo are covered in `BundleMetadataCacheTests`; live per-pid resolution is verified
/// on-device.
struct AppIdentityTests {

    // MARK: appBundlePath — outermost-.app heuristic (moved from MemoryUsageTests)

    @Test func appBundlePathPicksOutermostDotApp() {
        // Helper nested inside the main app → the OUTER app (Chrome icon, not the helper's).
        #expect(appBundlePath(forExecutable:
            "/Applications/Google Chrome.app/Contents/Frameworks/Chrome.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)")
            == "/Applications/Google Chrome.app")
        // CLI tool bundled in an app → that app (Xcode icon).
        #expect(appBundlePath(forExecutable: "/Applications/Xcode.app/Contents/Developer/usr/bin/lldb-rpc-server")
            == "/Applications/Xcode.app")
        // Plain CLI tool, no enclosing .app → the executable itself (generic icon).
        #expect(appBundlePath(forExecutable: "/usr/sbin/cfprefsd") == "/usr/sbin/cfprefsd")
        #expect(appBundlePath(forExecutable: "") == nil)
    }

    // MARK: appDisplayName — the no-Info.plist fallback (moved from ProcessPowerTests)

    @Test func appDisplayNameStripsDotApp() {
        #expect(appDisplayName(forKey: "/Applications/Claude.app") == "Claude")
        #expect(appDisplayName(forKey: "/usr/bin/node") == "node")
        #expect(appDisplayName(forKey: "PID 42") == "PID 42")
    }

    // MARK: appIdentity — the bundle id keys the group, CFBundleName labels it

    @Test func identityPrefersBundleIDAndBundleName() {
        let claude = appIdentity(bundlePath: "/Applications/Claude.app", pid: 1,
                                 bundleID: "com.anthropic.claudefordesktop", bundleName: "Claude")
        #expect(claude.key == "com.anthropic.claudefordesktop")
        #expect(claude.name == "Claude")
        #expect(claude.iconPath == "/Applications/Claude.app")
    }

    /// The reported bug (2026-08-22): the memory list showed "Claude" and "claude" as two
    /// rows. Claude Code's bundle lives at
    /// `…/Application Support/Claude/claude-code/<version>/claude.app`, so the DIRECTORY
    /// name is "claude" — a lowercase near-duplicate of the desktop app. Its Info.plist says
    /// `CFBundleName = Claude Code` and `CFBundleIdentifier = com.anthropic.claude-code`,
    /// which is both the right label AND version-independent.
    @Test func identityOfClaudeCodeIsNamedAndVersionIndependent() {
        let executable = "/Users/me/Library/Application Support/Claude/claude-code/2.1.237/claude.app/Contents/MacOS/claude"
        let identity = appIdentity(bundlePath: appBundlePath(forExecutable: executable), pid: 2,
                                   bundleID: "com.anthropic.claude-code", bundleName: "Claude Code")
        #expect(identity.key == "com.anthropic.claude-code")   // no "2.1.237" in the key
        #expect(identity.name == "Claude Code")                // not "claude"
        #expect(identity.iconPath
            == "/Users/me/Library/Application Support/Claude/claude-code/2.1.237/claude.app")
    }

    @Test func identityFallsBackToPathThenPID() {
        // Plain CLI: no bundle → the executable path both keys and names the group.
        let cli = appIdentity(bundlePath: "/usr/sbin/cfprefsd", pid: 3, bundleID: nil, bundleName: nil)
        #expect(cli == AppIdentity(key: "/usr/sbin/cfprefsd", name: "cfprefsd",
                                   iconPath: "/usr/sbin/cfprefsd"))
        // proc_pidpath failed → per-pid group, and no icon path for the view to resolve.
        let unknown = appIdentity(bundlePath: nil, pid: 4, bundleID: nil, bundleName: nil)
        #expect(unknown == AppIdentity(key: "PID 4", name: "PID 4", iconPath: nil))
    }

    /// A malformed Info.plist with empty strings must not collapse every such app into one
    /// "" group, nor label a row with a blank name.
    @Test func identityIgnoresEmptyPlistStrings() {
        let identity = appIdentity(bundlePath: "/Applications/Broken.app", pid: 5,
                                   bundleID: "", bundleName: "")
        #expect(identity.key == "/Applications/Broken.app")
        #expect(identity.name == "Broken")
    }
}
```

- [ ] **Step 2: Create the implementation file**

Create `Wattly/Core/AppIdentity.swift` (only the `AppIdentity` value + pure derivation + the two moved helpers for now — the Info.plist reader arrives in Task 2):

```swift
import Foundation

/// Who a process belongs to, *as an application*: the key the Top-N lists coalesce by, the
/// label the row shows, and the path `NSWorkspace` resolves the icon from. Shared by the
/// memory Top-N (`MemoryProvider`) and the per-app power Top-N (`PowerProvider`).
///
/// Both used to key on the `.app` bundle PATH and label the row with that path's basename,
/// which is wrong twice over: the path can carry a version (Claude Code installs at
/// `…/Application Support/Claude/claude-code/<version>/claude.app`, so an update splits one
/// app into two rows), and a bundle's DIRECTORY name is not its name (`claude.app` → `claude`,
/// but the app is called `Claude Code` — which read as a lowercase duplicate of the separate
/// `Claude` desktop app). `CFBundleIdentifier` fixes the first, `CFBundleName` the second.
///
/// The derivation here is pure — the caller supplies the already-read Info.plist values — so
/// it is table-testable with no filesystem.

struct AppIdentity: Sendable, Equatable {
    /// Coalescing key: `CFBundleIdentifier` when the process lives in a readable `.app`,
    /// else the bundle/executable path, else `"PID n"`. Version-independent, so an app keeps
    /// ONE row across an in-place update (and two copies of one app merge, as they should).
    var key: String
    /// Row label: `CFBundleDisplayName`/`CFBundleName` when readable, else the path basename
    /// minus `.app`.
    var name: String
    /// Bundle (or executable) path for `NSWorkspace.icon(forFile:)`; nil when the executable
    /// path was unreadable (a `PID n` group) — the row then draws no icon.
    var iconPath: String?
}

/// Assemble an identity from a resolved bundle path + the Info.plist values the caller read
/// for it. Empty strings are treated as absent: a malformed plist must not collapse every
/// such app into one `""` group or blank out the row label.
func appIdentity(bundlePath: String?, pid: Int32,
                 bundleID: String?, bundleName: String?) -> AppIdentity {
    let fallbackKey = bundlePath ?? "PID \(pid)"
    let id = bundleID.flatMap { $0.isEmpty ? nil : $0 }
    let name = bundleName.flatMap { $0.isEmpty ? nil : $0 }
    return AppIdentity(key: id ?? fallbackKey,
                       name: name ?? appDisplayName(forKey: fallbackKey),
                       iconPath: bundlePath)
}

/// Responsible app bundle for an executable path: the OUTERMOST `.app` component, so a Chrome
/// helper resolves to `Google Chrome.app` and `lldb-rpc-server` to `Xcode.app` — without the
/// private responsible-pid API. Falls back to the executable path itself when there's no
/// enclosing `.app` (a plain CLI tool → generic icon), or nil for an empty path.
func appBundlePath(forExecutable path: String) -> String? {
    guard !path.isEmpty else { return nil }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    if let idx = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
        return "/" + parts[1...idx].joined(separator: "/")
    }
    return path
}

/// Display name when there is no readable Info.plist: the `.app` basename minus ".app" (e.g.
/// "/Applications/Claude.app" → "Claude"), else the path basename (a CLI), else the key.
func appDisplayName(forKey key: String) -> String {
    let last = key.split(separator: "/").last.map(String.init) ?? key
    return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
}
```

- [ ] **Step 3: Delete the two moved originals**

In `Wattly/Core/MemoryUsage.swift`, delete lines 104–116 — the whole `appBundlePath` function **and** its doc comment (the block starting `/// Responsible app bundle for an executable path:` through the closing `}`). The file now ends after `barFraction`.

In `Wattly/Core/ProcessPower.swift`, delete lines 52–57 — the `appDisplayName` function **and** its doc comment (the block starting `/// Display name for an app group key:` through the closing `}`).

In `WattlyTests/MemoryUsageTests.swift`, delete lines 199–212 — the `// MARK: appBundlePath …` comment and the whole `appBundlePathPicksOutermostDotApp` case (now in `AppIdentityTests`). Keep line 213, the closing brace of the test struct.

In `WattlyTests/ProcessPowerTests.swift`, delete lines 72–76 — the `appDisplayNameStripsDotApp` case (now in `AppIdentityTests`). Leave the `// MARK: name + bar helpers` comment and the `wattFraction` case that follows it.

Verify nothing is declared twice:

```bash
grep -rn "^func appBundlePath\|^func appDisplayName" Wattly/
```

Expected: exactly two lines, both in `Wattly/Core/AppIdentity.swift`.

- [ ] **Step 4: Regenerate the Xcode project (two new files)**

```bash
/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml
```

Expected: `Loaded project`, then `Created project at .../Wattly.xcodeproj`. `No "base" settings found` warnings are normal for this bare xcodegen install — ignore them.

Confirm both new files landed in the project:

```bash
grep -c "AppIdentity.swift" Wattly.xcodeproj/project.pbxproj
```

Expected: a number ≥ 4 (file reference + build file, for each of the two new files).

- [ ] **Step 5: Run the new tests**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/AppIdentityTests
```

Expected: `TEST SUCCEEDED`, 5 cases passing.

- [ ] **Step 6: Run the full suite (the move must not break anything)**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
```

Expected: `TEST SUCCEEDED` with no failures. Nothing is wired yet, so the app still behaves exactly as before.

- [ ] **Step 7: Commit**

```bash
git add Wattly/Core/AppIdentity.swift WattlyTests/AppIdentityTests.swift Wattly/Core/MemoryUsage.swift Wattly/Core/ProcessPower.swift WattlyTests/MemoryUsageTests.swift WattlyTests/ProcessPowerTests.swift Wattly.xcodeproj/project.pbxproj
git commit -m "refactor(core): add AppIdentity and gather the app-identity helpers into it"
```

---

## Task 2: Info.plist reader + per-provider memo

Adds the only I/O this feature needs — reading `CFBundleIdentifier`/`CFBundleName` out of a bundle — plus the memo that keeps it off the poll path. The reader is injectable, so the caching behaviour is tested with no filesystem, and one test exercises the real reader against a bundle guaranteed to exist (the test host itself).

**Files:**
- Modify: `Wattly/Core/AppIdentity.swift` (append after `appDisplayName`)
- Modify: `WattlyTests/AppIdentityTests.swift` (append a second test struct)

**Interfaces:**
- Consumes: `AppIdentity`, `appIdentity(bundlePath:pid:bundleID:bundleName:)`, `appBundlePath(forExecutable:)` (Task 1).
- Produces:
  - `func bundleMetadata(atBundlePath path: String) -> (id: String?, name: String?)`
  - `struct BundleMetadataCache` with `init(read:)`, `static let capacity = 512`,
    `mutating func metadata(forBundlePath path: String?) -> (id: String?, name: String?)`, and
    `mutating func identity(executablePath: String, pid: Int32) -> AppIdentity` — the single call each provider makes per pid.

- [ ] **Step 1: Write the failing tests**

Append to `WattlyTests/AppIdentityTests.swift` (a second top-level struct, after the closing brace of `AppIdentityTests`):

```swift
/// The Info.plist read and its memo. The reader is injected, so cache behaviour is verified
/// with a counting stub and no filesystem; one case exercises the real CoreFoundation read
/// against the test host bundle (Wattly.app), which is guaranteed to exist while tests run.
struct BundleMetadataCacheTests {

    /// Every poll re-resolves the same few dozen bundles across ~560 pids. One read per path
    /// for the life of the provider is the whole point of the memo.
    @Test func readsEachBundlePathOnce() {
        var reads = 0
        var cache = BundleMetadataCache(read: { path in
            reads += 1
            return (id: "com.test" + path, name: "Test")
        })
        _ = cache.metadata(forBundlePath: "/Applications/A.app")
        _ = cache.metadata(forBundlePath: "/Applications/A.app")
        _ = cache.metadata(forBundlePath: "/Applications/B.app")
        #expect(reads == 2)
    }

    /// A path with no readable Info.plist (a plain CLI, a deleted bundle) must be memoised
    /// too — otherwise every poll retries the same failing read forever.
    @Test func cachesMissesSoFailuresAreNotRetried() {
        var reads = 0
        var cache = BundleMetadataCache(read: { _ in
            reads += 1
            return (id: nil, name: nil)
        })
        let first = cache.metadata(forBundlePath: "/usr/sbin/cfprefsd")
        let second = cache.metadata(forBundlePath: "/usr/sbin/cfprefsd")
        #expect(reads == 1)
        #expect(first.id == nil && first.name == nil)
        #expect(second.id == nil && second.name == nil)
    }

    @Test func nilOrEmptyPathSkipsTheReadEntirely() {
        var reads = 0
        var cache = BundleMetadataCache(read: { _ in
            reads += 1
            return (id: "x", name: "X")
        })
        _ = cache.metadata(forBundlePath: nil)
        _ = cache.metadata(forBundlePath: "")
        #expect(reads == 0)
    }

    /// Bounded so a menubar app running for weeks can't grow the memo without limit.
    @Test func dropsEverythingWhenCapacityIsExceeded() {
        var reads = 0
        var cache = BundleMetadataCache(read: { _ in
            reads += 1
            return (id: nil, name: nil)
        })
        for i in 0..<BundleMetadataCache.capacity {
            _ = cache.metadata(forBundlePath: "/App\(i).app")
        }
        #expect(reads == BundleMetadataCache.capacity)
        _ = cache.metadata(forBundlePath: "/Overflow.app")   // trips the ceiling → memo cleared
        _ = cache.metadata(forBundlePath: "/App0.app")       // must be re-read, not a stale hit
        #expect(reads == BundleMetadataCache.capacity + 2)
    }

    /// The one call the providers make per pid: resolve the bundle path, read (or reuse) its
    /// plist, and assemble the identity.
    @Test func identityResolvesBundlePathAndPlistTogether() {
        var cache = BundleMetadataCache(read: { _ in
            (id: "com.anthropic.claude-code", name: "Claude Code")
        })
        let identity = cache.identity(
            executablePath: "/Users/me/Library/Application Support/Claude/claude-code/2.1.237/claude.app/Contents/MacOS/claude",
            pid: 7)
        #expect(identity.key == "com.anthropic.claude-code")
        #expect(identity.name == "Claude Code")
        #expect(identity.iconPath
            == "/Users/me/Library/Application Support/Claude/claude-code/2.1.237/claude.app")
    }

    /// The real CoreFoundation read, against the test host bundle (Wattly.app).
    @Test func realReaderParsesAnInfoPlistAndIgnoresNonBundles() {
        let host = bundleMetadata(atBundlePath: Bundle.main.bundlePath)
        #expect(host.id == "dev.jjundev.Wattly")
        #expect(host.name == "Wattly")
        // A plain executable is not a bundle — short-circuits with no I/O.
        let cli = bundleMetadata(atBundlePath: "/usr/sbin/cfprefsd")
        #expect(cli.id == nil && cli.name == nil)
        // A .app path that doesn't exist must not crash or invent values.
        let missing = bundleMetadata(atBundlePath: "/Applications/DoesNotExist.app")
        #expect(missing.id == nil && missing.name == nil)
    }
}
```

`Bundle` comes from Foundation, which `AppIdentityTests.swift` already imports transitively via `@testable import Wattly`; if the compiler disagrees, add `import Foundation` at the top of the test file.

- [ ] **Step 2: Run to verify it fails**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/BundleMetadataCacheTests
```

Expected: build failure — `cannot find 'BundleMetadataCache' in scope` and `cannot find 'bundleMetadata' in scope`.

- [ ] **Step 3: Implement the reader and the memo**

Append to `Wattly/Core/AppIdentity.swift` (after `appDisplayName`):

```swift
// MARK: - Info.plist (this file's only I/O)

/// Read `CFBundleIdentifier` + the display name straight out of a bundle's `Info.plist`.
/// `CFBundleCopyInfoDictionaryForURL` parses the plist WITHOUT instantiating a live
/// `Bundle`/`CFBundle` — no bundle-cache pollution, no code-signature validation — and
/// returns nil for anything unreadable. Non-`.app` paths (plain CLI executables, which are
/// most pids) short-circuit with no I/O at all. Measured ≈0.21 ms per call on an M-series
/// Mac, which is why `BundleMetadataCache` exists.
func bundleMetadata(atBundlePath path: String) -> (id: String?, name: String?) {
    guard path.hasSuffix(".app"),
          let info = CFBundleCopyInfoDictionaryForURL(URL(fileURLWithPath: path) as CFURL)
              as? [String: Any]
    else { return (nil, nil) }
    return (info["CFBundleIdentifier"] as? String,
            (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String))
}

/// Memo for `bundleMetadata`, owned by each provider actor. The Top-N sweeps re-resolve the
/// same few dozen bundle paths every poll (~560 pids for memory); without this, each poll
/// would re-read those plists off disk. Misses are memoised too — a `(nil, nil)` for a CLI or
/// a deleted bundle — so a failing read isn't retried forever.
///
/// A value type with an injected reader, so the caching behaviour is testable with no
/// filesystem. Each provider owns one instance (actor-isolated → no locking), keeping
/// `ProcessList`'s no-shared-mutable-state rule intact.
struct BundleMetadataCache {
    /// Hard ceiling on retained entries — a menubar app runs for weeks and every launched app
    /// adds one. Blown → drop everything and re-warm on the next poll (simpler than an LRU,
    /// and the re-warm costs one sweep).
    static let capacity = 512

    private var memo: [String: (id: String?, name: String?)] = [:]
    private let read: (String) -> (id: String?, name: String?)

    init(read: @escaping (String) -> (id: String?, name: String?) = bundleMetadata(atBundlePath:)) {
        self.read = read
    }

    mutating func metadata(forBundlePath path: String?) -> (id: String?, name: String?) {
        guard let path, !path.isEmpty else { return (nil, nil) }
        if let hit = memo[path] { return hit }
        let value = read(path)
        if memo.count >= Self.capacity { memo.removeAll(keepingCapacity: true) }
        memo[path] = value
        return value
    }

    /// The one call a provider makes per pid: executable path → bundle path → (memoised)
    /// plist values → identity.
    mutating func identity(executablePath: String, pid: Int32) -> AppIdentity {
        let bundlePath = appBundlePath(forExecutable: executablePath)
        let meta = metadata(forBundlePath: bundlePath)
        return appIdentity(bundlePath: bundlePath, pid: pid,
                           bundleID: meta.id, bundleName: meta.name)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/BundleMetadataCacheTests
```

Expected: `TEST SUCCEEDED`, 6 cases passing.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/AppIdentity.swift WattlyTests/AppIdentityTests.swift
git commit -m "feat(core): read CFBundleIdentifier/CFBundleName with a per-provider memo"
```

---

## Task 3: Memory Top-N keys on bundle id — the visible fix

Switches the memory card's expanded list from path-keyed groups to identity-keyed groups. This is the task that turns the reported `claude` row into `Claude Code`.

**Files:**
- Modify: `Wattly/Core/MemoryUsage.swift` (rewrite `topMemoryApps`, lines 77–89)
- Modify: `Wattly/Providers/MemoryProvider.swift` (add the cache property after line 24; rewrite `topMemoryProcesses`, lines 122–134; update its call site at line 40)
- Modify: `WattlyTests/MemoryUsageTests.swift` (rewrite the three `topMemoryApps` cases, lines 125–180; add the regression case)

**Interfaces:**
- Consumes: `AppIdentity`, `appDisplayName(forKey:)` (Task 1); `BundleMetadataCache.identity(executablePath:pid:)` (Task 2).
- Produces: `func topMemoryApps(perProcess: [(identity: AppIdentity, bytes: UInt64)], limit: Int) -> [ProcessUsage]` — the old `[(key: String, bytes: UInt64)]` overload is **replaced**, not kept.

- [ ] **Step 1: Write the failing tests**

In `WattlyTests/MemoryUsageTests.swift`, replace the whole `// MARK: topMemoryApps` section (the three cases at lines 125–180, up to but not including `@Test func memoryProcessLimitClampsToSupportedRange`) with:

```swift
    // MARK: topMemoryApps

    /// Terse identity builder for the ranking tables below: bundle-id key, real display name,
    /// and the `.app` path the row's icon comes from.
    private func app(_ key: String, _ name: String, _ iconPath: String) -> AppIdentity {
        AppIdentity(key: key, name: name, iconPath: iconPath)
    }

    @Test func topMemoryAppsCoalescesHelpersAndUsesAppName() {
        let codex = app("com.openai.codex", "Codex", "/Applications/Codex.app")
        let chrome = app("com.google.Chrome", "Google Chrome", "/Applications/Google Chrome.app")
        let xcode = app("com.apple.dt.Xcode", "Xcode", "/Applications/Xcode.app")

        let top = topMemoryApps(perProcess: [
            (identity: codex, bytes: 50),
            (identity: codex, bytes: 30),
            (identity: chrome, bytes: 70),
            (identity: xcode, bytes: 20),
        ], limit: 7)

        #expect(top.map(\.id) == ["com.openai.codex", "com.google.Chrome", "com.apple.dt.Xcode"])
        #expect(top.map(\.name) == ["Codex", "Google Chrome", "Xcode"])
        #expect(top.map(\.footprintBytes) == [80, 70, 20])
        #expect(top.map(\.iconPath) == [
            "/Applications/Codex.app",
            "/Applications/Google Chrome.app",
            "/Applications/Xcode.app",
        ])
    }

    /// The reported bug (2026-08-22): the list showed "Claude" and "claude" as two rows.
    /// They ARE two different programs (the desktop app and the Claude Code CLI), so two rows
    /// is correct — but the CLI must be labelled from its Info.plist ("Claude Code"), not from
    /// its bundle DIRECTORY name ("claude"). And because the CLI's path carries its version,
    /// two concurrently-running versions (an update lands while older sessions keep running)
    /// must still coalesce into ONE row.
    @Test func claudeDesktopAndClaudeCodeAreDistinctRowsWithRealNames() {
        let desktop = app("com.anthropic.claudefordesktop", "Claude", "/Applications/Claude.app")
        let cli237 = app("com.anthropic.claude-code", "Claude Code",
                         "/Users/me/Library/Application Support/Claude/claude-code/2.1.237/claude.app")
        let cli236 = app("com.anthropic.claude-code", "Claude Code",
                         "/Users/me/Library/Application Support/Claude/claude-code/2.1.236/claude.app")

        let top = topMemoryApps(perProcess: [
            (identity: desktop, bytes: 300),   // main process + helpers
            (identity: desktop, bytes: 200),
            (identity: cli237, bytes: 400),    // several CLI sessions, two versions live
            (identity: cli237, bytes: 300),
            (identity: cli236, bytes: 100),
        ], limit: 3)

        #expect(top.count == 2)
        #expect(top[0].id == "com.anthropic.claude-code")
        #expect(top[0].name == "Claude Code")                 // not "claude"
        #expect(top[0].footprintBytes == 800)                 // both versions in ONE row
        #expect(top[0].iconPath                                // icon from the biggest member
            == "/Users/me/Library/Application Support/Claude/claude-code/2.1.237/claude.app")
        #expect(top[1].id == "com.anthropic.claudefordesktop")
        #expect(top[1].name == "Claude")
        #expect(top[1].footprintBytes == 500)
    }

    @Test func topMemoryAppsRanksBySumThenStableKeyAndCaps() {
        let top = topMemoryApps(perProcess: [
            (identity: app("com.example.b", "B", "/Applications/B.app"), bytes: 40),
            (identity: app("com.example.a", "A", "/Applications/A.app"), bytes: 40),
            (identity: app("com.example.c", "C", "/Applications/C.app"), bytes: 20),
        ], limit: 2)

        // limit 2 clamps up to the 3-row floor; equal sums order by key asc (no poll-to-poll jitter).
        #expect(top.map(\.id) == ["com.example.a", "com.example.b", "com.example.c"])
        #expect(top.map(\.footprintBytes) == [40, 40, 20])
    }

    @Test func topMemoryAppsClampsDirectLimit() {
        let names = ["A", "B", "C", "D", "E", "F", "G", "H"]
        let processes: [(identity: AppIdentity, bytes: UInt64)] = names.enumerated().map { index, name in
            (identity: app("com.example.\(name.lowercased())", name, "/Applications/\(name).app"),
             bytes: UInt64(8 - index))
        }

        #expect(topMemoryApps(perProcess: processes, limit: 1).map(\.name) == ["A", "B", "C"])
        #expect(topMemoryApps(perProcess: processes, limit: 99).map(\.name)
            == ["A", "B", "C", "D", "E", "F", "G"])
    }
```

- [ ] **Step 2: Run to verify it fails**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/MemoryUsageTests
```

Expected: build failure — the calls no longer match `topMemoryApps(perProcess: [(key: String, bytes: UInt64)], limit:)`.

- [ ] **Step 3: Rewrite the pure ranking function**

In `Wattly/Core/MemoryUsage.swift`, replace `topMemoryApps` (lines 77–89) with:

```swift
/// Coalesce per-process footprints into the top-N apps, keyed by `AppIdentity.key` (the app's
/// bundle id when readable — NOT its install path, which can carry a version). The group's
/// row takes its name and icon from its largest member, so two installs of one app (or two
/// versions running side by side) merge into a single, correctly-labelled row.
func topMemoryApps(perProcess: [(identity: AppIdentity, bytes: UInt64)], limit: Int) -> [ProcessUsage] {
    var sums: [String: UInt64] = [:]
    var representative: [String: AppIdentity] = [:]
    // Biggest member first, so the representative is deterministic (tie → icon path asc).
    for member in perProcess.sorted(by: { lhs, rhs in
        lhs.bytes != rhs.bytes
            ? lhs.bytes > rhs.bytes
            : (lhs.identity.iconPath ?? "") < (rhs.identity.iconPath ?? "")
    }) {
        sums[member.identity.key, default: 0] += member.bytes
        if representative[member.identity.key] == nil {
            representative[member.identity.key] = member.identity
        }
    }
    return sums.sorted { lhs, rhs in
        lhs.value > rhs.value || (lhs.value == rhs.value && lhs.key < rhs.key)
    }
    .prefix(memoryProcessLimit(limit))
    .map { key, bytes in
        let rep = representative[key]
        return ProcessUsage(id: key,
                            name: rep?.name ?? appDisplayName(forKey: key),
                            footprintBytes: bytes,
                            iconPath: rep?.iconPath)
    }
}
```

- [ ] **Step 4: Wire the provider**

In `Wattly/Providers/MemoryProvider.swift`, add the cache property immediately after the `enumerating` property (line 24):

```swift
    /// Bundle-identity memo, actor-isolated (one per provider — `ProcessList`'s
    /// no-shared-mutable-state rule). Warms on the first enumerating poll, then costs nothing.
    private var bundleCache = BundleMetadataCache()
```

Replace `topMemoryProcesses` (lines 122–134) with an **instance** method — it now mutates the cache, so it can no longer be `static`:

```swift
    private func topMemoryProcesses(limit: Int) -> [ProcessUsage] {
        // Resolve an application identity for every readable PID before ranking: several
        // helper processes can together outrank a single larger process. Keying by
        // CFBundleIdentifier (not the bundle PATH) keeps an app in ONE row even when its
        // install path carries a version — Claude Code lives at
        // `…/Application Support/Claude/claude-code/<version>/claude.app` — and labels the row
        // with the app's real name instead of its bundle directory name ("claude").
        var perProcess: [(identity: AppIdentity, bytes: UInt64)] = []
        for pid in listPIDs() where pid > 0 {
            guard let bytes = Self.physFootprint(pid) else { continue }
            perProcess.append((identity: bundleCache.identity(executablePath: pidPath(pid), pid: pid),
                               bytes: bytes))
        }
        return topMemoryApps(perProcess: perProcess, limit: limit)
    }
```

At line 40, drop the now-wrong `Self.` qualifier on the call site:

```swift
            procs = topMemoryProcesses(limit: processLimit)
```

Leave `physFootprint` as a `private static func` — `Self.physFootprint(pid)` still resolves from the instance method.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/MemoryUsageTests
```

Expected: `TEST SUCCEEDED`. Then confirm no stale callers of the old signature remain:

```bash
grep -rn "topMemoryApps(perProcess:" Wattly/ WattlyTests/
```

Expected: only the definition in `MemoryUsage.swift` plus the four test call sites.

- [ ] **Step 6: Commit**

```bash
git add Wattly/Core/MemoryUsage.swift Wattly/Providers/MemoryProvider.swift WattlyTests/MemoryUsageTests.swift
git commit -m "fix(memory): group Top-N by bundle id and label rows with the app's real name"
```

---

## Task 4: Power Top-N keys on bundle id

The per-app power list has the identical defect (same helpers, same `appBundlePath` key, same `appDisplayName` label). Same fix, symmetric shape.

**Files:**
- Modify: `Wattly/Core/ProcessPower.swift` (rewrite `topAppPower`, lines 31–43)
- Modify: `Wattly/Providers/PowerProvider.swift` (add the cache property; rewrite the identity map + row mapping inside `processPower`, lines 110–123)
- Modify: `WattlyTests/ProcessPowerTests.swift` (rewrite the three `topAppPower` cases, lines 27–59)

**Interfaces:**
- Consumes: `AppIdentity`, `appDisplayName(forKey:)` (Task 1); `BundleMetadataCache.identity(executablePath:pid:)` (Task 2).
- Produces: `func topAppPower(perPidWatts: [(pid: Int32, watts: Double)], identity: [Int32: AppIdentity], limit: Int) -> [(identity: AppIdentity, watts: Double)]` — replaces the `appKey: [Int32: String]` / `[(key: String, watts: Double)]` shape.

> **Trap:** the old provider code sets `iconPath: group.key.hasPrefix("/") ? group.key : nil`. Bundle-id keys never start with `/`, so leaving that expression in place would blank out **every** icon in the power list. It must be replaced with `group.identity.iconPath`.

- [ ] **Step 1: Write the failing tests**

In `WattlyTests/ProcessPowerTests.swift`, replace the three cases under `// MARK: topAppPower …` (lines 27–59, i.e. `coalescesHelpersSoFragmentedAppOutranksSingleProcess`, `fallbackKeyAndStableTieOrder`, `limitCaps`) with:

```swift
    // MARK: topAppPower — coalesce helper pids into the owning app

    @Test func coalescesHelpersSoFragmentedAppOutranksSingleProcess() {
        // The real-world bug: Claude's draw spread across 3 helpers (Σ 0.346 W) was buried
        // under a single Codex process (0.212 W). Coalesced, Claude must outrank it.
        let claude = AppIdentity(key: "com.anthropic.claudefordesktop", name: "Claude",
                                 iconPath: "/Applications/Claude.app")
        let codex = AppIdentity(key: "com.openai.codex", name: "Codex",
                                iconPath: "/Applications/Codex.app")
        let perPid: [(pid: Int32, watts: Double)] = [
            (1, 0.178), (2, 0.110), (3, 0.058),   // Claude helpers
            (4, 0.212)]                            // Codex single process
        let identity: [Int32: AppIdentity] = [1: claude, 2: claude, 3: claude, 4: codex]

        let top = topAppPower(perPidWatts: perPid, identity: identity, limit: 3)

        #expect(top.count == 2)
        #expect(top[0].identity.key == "com.anthropic.claudefordesktop")   // 0.346 Σ > 0.212
        #expect(top[0].identity.name == "Claude")
        #expect(top[0].identity.iconPath == "/Applications/Claude.app")
        #expect(abs(top[0].watts - 0.346) < 1e-9)
        #expect(top[1].identity.key == "com.openai.codex")
    }

    @Test func fallbackKeyAndStableTieOrder() {
        // No identity for pid 2 (proc_pidpath failed) → per-pid fallback group, no icon.
        // Equal watts order by key asc so rows don't jitter between polls; in ASCII "P" (0x50)
        // sorts before "c" (0x63), so the fallback group leads here.
        let perPid: [(pid: Int32, watts: Double)] = [(1, 0.5), (2, 0.5)]
        let identity: [Int32: AppIdentity] = [
            1: AppIdentity(key: "com.example.b", name: "B", iconPath: "/Applications/B.app")]

        let top = topAppPower(perPidWatts: perPid, identity: identity, limit: 3)

        #expect(top.count == 2)
        #expect(top[0].identity == AppIdentity(key: "PID 2", name: "PID 2", iconPath: nil))
        #expect(top[1].identity.key == "com.example.b")
        #expect(top[1].identity.name == "B")
    }

    @Test func limitCaps() {
        let perPid: [(pid: Int32, watts: Double)] = [(1, 3), (2, 2), (3, 1)]
        let identity: [Int32: AppIdentity] = [
            1: AppIdentity(key: "a", name: "a", iconPath: nil),
            2: AppIdentity(key: "b", name: "b", iconPath: nil),
            3: AppIdentity(key: "c", name: "c", iconPath: nil)]

        #expect(topAppPower(perPidWatts: perPid, identity: identity, limit: 2)
            .map(\.identity.key) == ["a", "b"])
    }
```

- [ ] **Step 2: Run to verify it fails**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/ProcessPowerTests
```

Expected: build failure — no `topAppPower` overload takes an `identity:` argument.

- [ ] **Step 3: Rewrite the pure ranking function**

In `Wattly/Core/ProcessPower.swift`, replace `topAppPower` (lines 31–43) with:

```swift
/// Coalesce per-pid watts into the top-`limit` apps by summed watts, keyed by
/// `AppIdentity.key` (the app's bundle id when readable, else its path, else a per-pid
/// fallback). Stable order: watts desc, then key asc, so equal-watt groups don't jitter
/// between polls. The group carries its largest member's identity, so the row gets the app's
/// real name and icon path.
func topAppPower(perPidWatts: [(pid: Int32, watts: Double)],
                 identity: [Int32: AppIdentity],
                 limit: Int) -> [(identity: AppIdentity, watts: Double)] {
    var sums: [String: Double] = [:]
    var representative: [String: AppIdentity] = [:]
    // Biggest member first, so the representative is deterministic (tie → pid asc).
    for (pid, watts) in perPidWatts.sorted(by: {
        $0.watts != $1.watts ? $0.watts > $1.watts : $0.pid < $1.pid
    }) {
        let member = identity[pid] ?? AppIdentity(key: "PID \(pid)", name: "PID \(pid)", iconPath: nil)
        sums[member.key, default: 0] += watts
        if representative[member.key] == nil { representative[member.key] = member }
    }
    return sums.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
        .prefix(max(0, limit))
        .map { key, watts in
            (identity: representative[key]
                ?? AppIdentity(key: key, name: appDisplayName(forKey: key), iconPath: nil),
             watts: watts)
        }
}
```

- [ ] **Step 4: Wire the provider**

In `Wattly/Providers/PowerProvider.swift`, add the cache property next to the other per-poll state (beside `prevProcEnergy` / `prevProcInstant`):

```swift
    /// Bundle-identity memo, actor-isolated (one per provider — `ProcessList`'s
    /// no-shared-mutable-state rule). Only CONSUMING pids are resolved, so it stays small.
    private var bundleCache = BundleMetadataCache()
```

Then replace the body from `let perPid = processWatts(...)` to the end of `processPower(at:)` (lines 110–123) with:

```swift
        let perPid = processWatts(prev: prevE, curr: curr, dt: dt)
        var identities: [Int32: AppIdentity] = [:]
        identities.reserveCapacity(perPid.count)
        for (pid, _) in perPid {
            identities[pid] = bundleCache.identity(executablePath: pidPath(pid), pid: pid)
        }
        let limit = powerProcessLimit(
            UserDefaults.standard.object(forKey: StorageKey.powerProcessLimit) as? Int)
        return topAppPower(perPidWatts: perPid, identity: identities, limit: limit).map { group in
            ProcessPower(id: group.identity.key,
                         name: group.identity.name,
                         watts: group.watts,
                         iconPath: group.identity.iconPath)
        }
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/ProcessPowerTests
```

Expected: `TEST SUCCEEDED`. Then confirm the icon trap is gone:

```bash
grep -rn "hasPrefix(\"/\")" Wattly/Providers/PowerProvider.swift
```

Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add Wattly/Core/ProcessPower.swift Wattly/Providers/PowerProvider.swift WattlyTests/ProcessPowerTests.swift
git commit -m "fix(power): group per-app power by bundle id and label rows with the app's real name"
```

---

## Task 5: Fake harness alignment, full green, on-device verification

The synthetic rows in `FakeProvider` still carry path-shaped ids, which now contradicts the documented contract on `ProcessUsage.id` ("the coalescing key"). Align them, run everything, then confirm the fix on the real machine — the whole point of this plan is a visual defect, so a green suite is necessary but not sufficient.

**Files:**
- Modify: `Wattly/Providers/FakeProvider.swift` (the synthetic `procs` array, lines 112–119)
- Modify: `Wattly/Models/MetricSample.swift` (doc comments on `ProcessUsage.id` / `ProcessPower.id`, lines 80–87 and 108–113)

**Interfaces:**
- Consumes: everything from Tasks 1–4. Produces: nothing new.

- [ ] **Step 1: Align the fake rows with the new id shape**

In `Wattly/Providers/FakeProvider.swift`, replace the `procs` array (lines 112–119) with:

```swift
            let procs = [
                ProcessUsage(id: "com.google.Chrome", name: "Google Chrome",
                             footprintBytes: UInt64(used * 0.30 * gib), iconPath: "/Applications/Google Chrome.app"),
                ProcessUsage(id: "com.apple.dt.Xcode", name: "Xcode",
                             footprintBytes: UInt64(used * 0.21 * gib), iconPath: "/Applications/Xcode.app"),
                ProcessUsage(id: "com.figma.Desktop", name: "Figma",
                             footprintBytes: UInt64(used * 0.13 * gib), iconPath: "/Applications/Figma.app"),
            ]
```

- [ ] **Step 2: Correct the model doc comments**

In `Wattly/Models/MetricSample.swift`, the `ProcessUsage.iconPath` comment (line 84) and the `ProcessPower.id` comment (lines 105–113) both still describe the id as a bundle path. Update them:

For `ProcessUsage` (replace lines 80–87):

```swift
struct ProcessUsage: Sendable, Equatable, Identifiable {
    /// Coalescing key from `AppIdentity.key` — the app's `CFBundleIdentifier` when readable,
    /// else its bundle/executable path, else `"PID n"`. Bundle-id keyed so an app keeps ONE
    /// row across an update that changes its install path.
    var id: String
    var name: String
    var footprintBytes: UInt64
    /// App-bundle (or executable) path used by `NSWorkspace` for the row icon — no longer the
    /// same value as `id`. A String rather than an `NSImage` so the sample stays Sendable.
    var iconPath: String? = nil
}
```

For `ProcessPower`, replace the two `id`-related comment lines (the tail of the type doc at lines 108–109 and the property comment at lines 111–113) so they read:

```swift
/// not attributed per-process, and only readable apps are counted, so these rows don't sum
/// to the card's Combined headline. `id` is the coalescing key from `AppIdentity.key`.
struct ProcessPower: Sendable, Equatable, Identifiable {
    /// Coalescing key — the app's `CFBundleIdentifier` when readable, else its bundle path,
    /// else `"PID n"`. Stable across polls for SwiftUI diffing; the icon comes from
    /// `iconPath`, which is a separate value.
    var id: String
```

- [ ] **Step 3: Run the whole suite**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
```

Expected: `TEST SUCCEEDED` with zero failures across every test struct (including `SnapshotGeneratorTests`, which builds `ProcessUsage` values directly and is unaffected by the key change).

- [ ] **Step 4: Build and launch the real app**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

```bash
open "$HOME/Library/Developer/Xcode/DerivedData/$(ls -t "$HOME/Library/Developer/Xcode/DerivedData" | grep '^Wattly-' | head -1)/Build/Products/Debug/Wattly.app"
```

- [ ] **Step 5: Verify on-device (the reported defect)**

Open the menubar popover and expand the 메모리 card. Check, against the reference `ps` output below:

1. The Claude Code row is labelled **"Claude Code"** — there is no lowercase **"claude"** row.
2. Claude Code appears **once**, not once per version directory, and its GB figure is the sum of all its sessions.
3. The desktop **"Claude"** row is still separate, with the Claude icon intact.
4. Chrome / other Electron apps still show one row each with their icons (the outermost-`.app` coalescing did not regress).
5. Expand the 전력 card and confirm its app rows also show real names **and still have icons** (the `hasPrefix("/")` trap from Task 4).

Ground truth for what should be on screen:

```bash
ps -axo pid,rss,comm | grep -iE "claude|chrome" | grep -v grep | sort -k2 -rn | head -20
```

- [ ] **Step 6: Commit**

```bash
git add Wattly/Providers/FakeProvider.swift Wattly/Models/MetricSample.swift
git commit -m "chore: align fake rows and model docs with bundle-id coalescing keys"
```

---

## Notes for the reviewer

- **Why not merge Claude Desktop and Claude Code into one row:** they are separate programs with separate bundle ids (`com.anthropic.claudefordesktop` vs `com.anthropic.claude-code`), separate binaries, and separate process trees. Activity Monitor lists them separately too. Merging would require a hand-maintained alias table or a vendor-prefix rule that would also fold together unrelated apps from the same vendor. Decided at the plan's decision checkpoint: keep two rows, fix the labels.
- **Why the Claude Code row keeps a generic gray icon:** its bundle ships no icon resource (no `Resources` directory, no `CFBundleIconFile` — it is a single `Contents/MacOS/claude` executable in an `.app` wrapper), so `NSWorkspace` has nothing to return but the generic executable icon. Decided at the checkpoint: leave it. Once the row is labelled "Claude Code", the generic icon no longer reads as a rendering failure.
- **Behaviour change worth knowing:** two copies of the same app installed in different locations now merge into one row (same bundle id). That matches the "same program = one row" rule this feature exists to serve.
