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
