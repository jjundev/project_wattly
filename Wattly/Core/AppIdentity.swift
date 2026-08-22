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
    // `idx >= 1` guards the slice: a RELATIVE path whose first component is the bundle would
    // form an invalid `1...0` range and trap. `proc_pidpath` only ever yields absolute paths,
    // but this function now lives in a general-purpose home where a caller can't know that.
    if let idx = parts.firstIndex(where: { $0.hasSuffix(".app") }), idx >= 1 {
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

// MARK: - Info.plist (this file's only I/O)

/// Read `CFBundleIdentifier` + the display name straight out of a bundle's `Info.plist`.
/// `CFBundleCopyInfoDictionaryForURL` parses the plist WITHOUT instantiating a live
/// `Bundle`/`CFBundle` — no bundle-cache pollution, no code-signature validation — and
/// returns nil for anything unreadable. The values are whatever the bundle declares —
/// unvalidated and unsigned, so an app can claim another's id or any display name; they are
/// display-only text here (the view renders `name` via `Text(_: String)`, which does no
/// markdown or localization lookup). Non-`.app` paths (plain CLI executables, which are
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
/// same bundle paths every poll (~560 pids for memory); without this, each poll would re-read
/// those plists off disk. Only `.app` paths are memoised: non-bundle executables outnumber
/// real bundles roughly 6:1 (measured 294 vs 69 on a working Mac) and already cost zero I/O in
/// `bundleMetadata`, so caching them would spend the whole ceiling on entries worth nothing.
/// Misses among the `.app` paths ARE memoised — a `(nil, nil)` for a deleted or unreadable
/// bundle — so a failing read isn't retried forever. Entries never expire, so an app replaced
/// in place under the same path keeps its old label until Wattly restarts (cosmetic, and
/// self-healing).
///
/// A value type with an injected reader, so the caching behaviour is testable with no
/// filesystem. Each provider owns one instance (actor-isolated → no locking), keeping
/// `ProcessList`'s no-shared-mutable-state rule intact.
struct BundleMetadataCache {
    /// Hard ceiling on retained entries — a menubar app runs for weeks and every launched app
    /// adds one. Only `.app` bundles land here (~70 on a working Mac), so this is deep
    /// headroom rather than a working limit. Blown → drop everything and re-warm on the next
    /// sweep (simpler than an LRU).
    static let capacity = 512

    private var memo: [String: (id: String?, name: String?)] = [:]
    /// Deliberately NOT `@Sendable`, unlike `PowerProvider.now`: that closure is injected from
    /// outside the actor and must cross an isolation boundary, while this one never does (each
    /// provider builds its cache inline from the default argument). Keeping it non-`@Sendable`
    /// also keeps `BundleMetadataCache` non-`Sendable`, so the compiler rejects any attempt to
    /// share one cache between the two provider actors.
    private let read: (String) -> (id: String?, name: String?)

    init(read: @escaping (String) -> (id: String?, name: String?) = bundleMetadata(atBundlePath:)) {
        self.read = read
    }

    mutating func metadata(forBundlePath path: String?) -> (id: String?, name: String?) {
        // Only bundles get a memo slot. A non-`.app` path resolves for free in `bundleMetadata`
        // (it short-circuits before any I/O), so memoising one buys nothing and burns a slot —
        // and there are ~6 of them for every real bundle. This subsumes the nil/empty check.
        guard let path, path.hasSuffix(".app") else { return (nil, nil) }
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
