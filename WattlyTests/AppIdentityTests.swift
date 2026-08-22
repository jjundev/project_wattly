import Foundation
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
        // Relative path whose FIRST component is the bundle → no enclosing `.app` we can
        // anchor, so the path itself. Must not trap on the slice.
        #expect(appBundlePath(forExecutable: "claude.app/Contents/MacOS/claude")
            == "claude.app/Contents/MacOS/claude")
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

    /// Half a plist: the two fields fall back independently. A readable id with no usable name
    /// must still label the row from the path — never with the raw bundle id.
    @Test func identityFallsBackPerFieldOnPartialPlist() {
        let noName = appIdentity(bundlePath: "/Applications/Broken.app", pid: 6,
                                 bundleID: "com.example.broken", bundleName: "")
        #expect(noName.key == "com.example.broken")
        #expect(noName.name == "Broken")

        let noID = appIdentity(bundlePath: "/Applications/Broken.app", pid: 7,
                               bundleID: nil, bundleName: "Broken App")
        #expect(noID.key == "/Applications/Broken.app")
        #expect(noID.name == "Broken App")
    }
}

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

    /// An `.app` with no readable Info.plist (deleted, or malformed) must be memoised too —
    /// otherwise every poll retries the same failing read forever.
    @Test func cachesMissesSoFailuresAreNotRetried() {
        var reads = 0
        var cache = BundleMetadataCache(read: { _ in
            reads += 1
            return (id: nil, name: nil)
        })
        let first = cache.metadata(forBundlePath: "/Applications/Deleted.app")
        let second = cache.metadata(forBundlePath: "/Applications/Deleted.app")
        #expect(reads == 1)
        #expect(first.id == nil && first.name == nil)
        #expect(second.id == nil && second.name == nil)
    }

    /// Non-bundle executables — most pids — must never reach the reader or take a memo slot.
    @Test func nonBundlePathsAreNeverMemoised() {
        var reads = 0
        var cache = BundleMetadataCache(read: { _ in
            reads += 1
            return (id: "x", name: "X")
        })
        let cli = cache.metadata(forBundlePath: "/usr/sbin/cfprefsd")
        #expect(reads == 0)
        #expect(cli.id == nil && cli.name == nil)
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
        // The entry that tripped the ceiling is inserted AFTER the clear, so it must be a hit.
        _ = cache.metadata(forBundlePath: "/Overflow.app")
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
