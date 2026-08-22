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
