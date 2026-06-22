import Foundation

/// Real SoC-power provider (issue 06) — no entitlements. Reads the IOReport private
/// API's "Energy Model" group (CPU/GPU/NPU/DRAM/… energy), diffs absolute energy
/// across polls, and divides by elapsed time → watts. Works on battery, AC, and
/// desktop Macs alike (SoC-level, not battery-derived). Only the Sendable
/// `PowerSample` crosses the actor boundary; the IOReport handles never leave the
/// `IOReportEnergySubscription` wrapper. All arithmetic lives in pure `PowerEnergy`.
actor PowerProvider: MetricProvider, ProcessEnumerating {
    let kind: ProviderKind = .power

    /// One-shot lazy setup (like `CPUProvider`'s topology). A nil subscription after
    /// the attempt is terminal — we don't re-`dlopen` every poll.
    private var setupAttempted = false
    private var subscription: IOReportEnergySubscription?
    /// Previous absolute energies (joules) + the instant they were sampled, held as
    /// plain Sendable values — no Core Foundation object lives across polls.
    private var prev: [String: Double]?
    private var prevInstant: ContinuousClock.Instant?

    /// Per-app power (issue 16 follow-up). Swept ONLY while the power card's expand is
    /// on-screen (gated like `MemoryProvider`'s Top-3), so the routine poll stays cheap.
    /// Prev per-pid energy snapshot (nanojoules) + its instant; nil ⇒ baseline only.
    private var enumerating = false
    private var prevProcEnergy: [Int32: UInt64]?
    private var prevProcInstant: ContinuousClock.Instant?

    /// Above this the reading is implausible (unit-decode error or a transient
    /// spike) → re-baseline rather than emit. Generous enough never to reject a real
    /// Apple-silicon SoC figure (highest parts draw well under this), tight enough to
    /// catch an order-of-magnitude units mistake.
    private static let sanityCeilingW = 500.0
    /// Elapsed time beyond which the interval is treated as a gap (missed poll, or
    /// sleep/wake — `ContinuousClock` advances through sleep) → re-baseline.
    private static let maxPlausibleDt = 30.0

    /// Matches the existing copy in `MetricState`/`FakeProvider` (the orange card).
    static let unreadableMessage =
        "Energy Model 그룹을 읽을 수 없음 — 이 macOS에서 채널이 바뀌었을 수 있습니다."

    /// Gate the per-app power sweep to when the power card's expand is visible (issue 16
    /// follow-up). Clearing the baseline on disable means a re-open re-baselines cleanly.
    func setEnumerating(_ enabled: Bool) {
        enumerating = enabled
        if !enabled { prevProcEnergy = nil; prevProcInstant = nil }
    }

    func read(at instant: ContinuousClock.Instant) async -> ProviderReading {
        if !setupAttempted {
            setupAttempted = true
            subscription = IOReportEnergySubscription()
        }
        guard let subscription else {
            return .unavailable(.channelUnreadable(Self.unreadableMessage))
        }
        guard let curr = subscription.sample(), !curr.isEmpty else {
            return .unavailable(.channelUnreadable(Self.unreadableMessage))
        }
        defer { prev = curr; prevInstant = instant }       // re-baseline on every kept path

        guard let prev, let prevInstant else { return .pending }   // first sample: baseline only
        let dt = Self.seconds(from: prevInstant, to: instant)
        if dt <= 0 || dt > Self.maxPlausibleDt || hasCounterReset(prev: prev, curr: curr) {
            return .pending                                  // anomaly → drop interval, re-baseline
        }
        var sample = powerSample(prev: prev, curr: curr, dt: dt)
        guard sample.totalW.isFinite, sample.totalW <= Self.sanityCeilingW else {
            return .pending                                  // implausible → re-baseline
        }
        sample.processes = enumerating ? processPower(at: instant) : nil
        return .value(.power(sample))
    }

    private static func seconds(from a: ContinuousClock.Instant, to b: ContinuousClock.Instant) -> Double {
        let d = a.duration(to: b)
        return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }

    // MARK: Per-app power (issue 16 follow-up) — gated per-pid energy sweep

    /// Top-3 power-consuming APPS, or nil when not yet measurable (the first sweep after
    /// enable has no delta, or a dt anomaly → re-baseline + "측정 중…"). `[]` = measured but
    /// nothing readable consuming. Per-pid watts are coalesced into the owning `.app` so an
    /// Electron app's helpers (Claude, Chrome, …) sum into one row instead of each being
    /// buried. The executable path is resolved only for CONSUMING pids (positive delta —
    /// dozens, not all ~560), keeping the per-poll cost bounded.
    private func processPower(at instant: ContinuousClock.Instant) -> [ProcessPower]? {
        let curr = Self.currentProcessEnergies()
        defer { prevProcEnergy = curr; prevProcInstant = instant }
        guard let prevE = prevProcEnergy, let prevI = prevProcInstant else { return nil }
        let dt = Self.seconds(from: prevI, to: instant)
        guard dt > 0, dt <= Self.maxPlausibleDt else { return nil }   // gap → re-baseline

        let perPid = processWatts(prev: prevE, curr: curr, dt: dt)
        var appKey: [Int32: String] = [:]
        appKey.reserveCapacity(perPid.count)
        for (pid, _) in perPid {
            appKey[pid] = appBundlePath(forExecutable: pidPath(pid)) ?? "PID \(pid)"
        }
        return topAppPower(perPidWatts: perPid, appKey: appKey, limit: 3).map { group in
            ProcessPower(id: group.key,
                         name: appDisplayName(forKey: group.key),
                         watts: group.watts,
                         iconPath: group.key.hasPrefix("/") ? group.key : nil)
        }
    }

    /// Absolute per-pid energy (nanojoules) for every readable pid, from `ri_energy_nj`.
    /// Own-user pids only — others return a nonzero rc and are skipped (≈75% readable).
    private static func currentProcessEnergies() -> [Int32: UInt64] {
        let pids = listPIDs()
        var out: [Int32: UInt64] = [:]
        out.reserveCapacity(pids.count)
        for pid in pids where pid > 0 {
            if let nj = procEnergyNanojoules(pid) { out[pid] = nj }
        }
        return out
    }

    private static func procEnergyNanojoules(_ pid: Int32) -> UInt64? {
        var info = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        return rc == 0 ? info.ri_energy_nj : nil
    }
}

/// RAII wrapper around the IOReport private API. Owns the dlopen'd symbols and the
/// subscription; only ever touched from inside `PowerProvider`'s actor isolation, so
/// access is serialised without a lock — hence `@unchecked Sendable` (same basis as
/// `ManualClock`, minus the lock). The CF handles are ARC-managed Swift references,
/// so the per-poll sample dict is released at scope exit (no per-poll leak) and the
/// subscription is released when this object deinits. The library handle is left
/// open for the process lifetime (one mapping; releasing the subscription must not
/// race a `dlclose` of its CF finalizer).
final class IOReportEnergySubscription: @unchecked Sendable {
    private typealias CopyChannelsFn =
        @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscriptionFn =
        @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary,
                        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> Unmanaged<AnyObject>?
    private typealias CreateSamplesFn =
        @convention(c) (AnyObject, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias GetStringFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias GetIntegerFn = @convention(c) (CFDictionary, Int32) -> Int64

    private let subscription: AnyObject
    private let subbedChannels: CFMutableDictionary
    private let createSamples: CreateSamplesFn
    private let getChannelName: GetStringFn
    private let getUnitLabel: GetStringFn
    private let getIntegerValue: GetIntegerFn

    /// nil if the library, any symbol, or the "Energy Model" group is unavailable —
    /// graceful degrade (the provider then shows the orange "channel unreadable" card).
    init?() {
        // leaf name only: the `IOReport.framework/...` path is absent on disk; only
        // the dyld shared-cache leaf opens.
        guard let handle = dlopen("libIOReport.dylib", RTLD_LAZY) else { return nil }
        func sym<T>(_ name: String, as type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard
            let copyChannels = sym("IOReportCopyChannelsInGroup", as: CopyChannelsFn.self),
            let createSub = sym("IOReportCreateSubscription", as: CreateSubscriptionFn.self),
            let createSamples = sym("IOReportCreateSamples", as: CreateSamplesFn.self),
            let getName = sym("IOReportChannelGetChannelName", as: GetStringFn.self),
            let getUnit = sym("IOReportChannelGetUnitLabel", as: GetStringFn.self),
            let getInt = sym("IOReportSimpleGetIntegerValue", as: GetIntegerFn.self)
        else { dlclose(handle); return nil }

        guard let channelsU = copyChannels("Energy Model" as CFString, nil, 0, 0, 0) else {
            dlclose(handle); return nil
        }
        let channels = channelsU.takeRetainedValue()          // +1 → ARC owns; freed at init end
        var subbedOut: Unmanaged<CFMutableDictionary>?
        guard let subU = createSub(nil, channels, &subbedOut, 0, nil),
              let subbedU = subbedOut else {
            dlclose(handle); return nil
        }
        self.subscription = subU.takeRetainedValue()          // ARC-managed for this object's life
        self.subbedChannels = subbedU.takeRetainedValue()
        self.createSamples = createSamples
        self.getChannelName = getName
        self.getUnitLabel = getUnit
        self.getIntegerValue = getInt
        // `channels` released here; the library handle is intentionally not dlclosed.
    }

    /// One snapshot: every channel decoded to absolute joules (name → joules). nil on
    /// sample failure. Walks the sample dict's `IOReportChannels` array directly —
    /// no Objective-C block (avoids a Swift 6 data-race on the accumulator), the
    /// block-free style `CPUProvider` uses for the same reason.
    func sample() -> [String: Double]? {
        guard let samplesU = createSamples(subscription, subbedChannels, nil) else { return nil }
        let dict = samplesU.takeRetainedValue()               // +1 consumed; released at scope exit
        guard let channels = (dict as NSDictionary)["IOReportChannels"] as? [Any] else { return nil }
        var out: [String: Double] = [:]
        out.reserveCapacity(channels.count)
        for case let ch as NSDictionary in channels {
            let chCF = ch as CFDictionary
            guard let name = getChannelName(chCF)?.takeUnretainedValue() as String? else { continue }
            let unit = getUnitLabel(chCF)?.takeUnretainedValue() as String?
            let raw = getIntegerValue(chCF, 0)
            out[name, default: 0] += Double(raw) * unitScale(unit)
        }
        return out
    }
}
