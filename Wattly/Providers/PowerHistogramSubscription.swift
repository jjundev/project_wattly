import Foundation

/// RAII wrapper around the IOReport private API for the `PMP` group / `Energy` subgroup
/// (macOS 27 processor-power migration). Mirrors `RealCPUClock` (`CPUClock.swift`): dlopen'd
/// symbols + one subscription live only inside this object, touched solely from
/// `PowerProvider`'s actor isolation — hence `@unchecked Sendable`. The CF handles are
/// ARC-managed Swift references; the per-poll sample dict is released at scope exit. The
/// library handle is intentionally never `dlclose`d once a subscription exists (releasing the
/// subscription must not race a `dlclose` of its CF finalizer — same rule as
/// `IOReportEnergySubscription`).
///
/// Only the CPU cluster channels (`EACC<n>`/`PACC<n>`, SRAM excluded) are decoded; their bin
/// widths are parsed ONCE here from the first bin's name (`" 0.250W"` → 0.25) and reused every
/// poll, which then reads residency counts only. All arithmetic lives in pure `PowerHistogram`.
final class IOReportPMPEnergySubscription: @unchecked Sendable {
    private typealias CopyChannelsFn =
        @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscriptionFn =
        @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary,
                        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> Unmanaged<AnyObject>?
    private typealias CreateSamplesFn =
        @convention(c) (AnyObject, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias GetStringFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias StateGetCountFn = @convention(c) (CFDictionary) -> Int32
    private typealias StateGetResidencyFn = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias StateGetNameForIndexFn = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?

    private let subscription: AnyObject
    private let subbedChannels: CFMutableDictionary
    private let createSamples: CreateSamplesFn
    private let getChannelName: GetStringFn
    private let stateGetCount: StateGetCountFn
    private let stateGetResidency: StateGetResidencyFn
    /// Cluster channel → bin width (W), resolved once at init.
    private let binWidths: [String: Double]

    /// nil if the library, any symbol, the `PMP`/`Energy` subgroup, or every cluster channel is
    /// unavailable (macOS ≤ 26 or non-Apple silicon) — the provider then runs Energy-Model-only,
    /// exactly as before this migration.
    init?() {
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
            let getCount = sym("IOReportStateGetCount", as: StateGetCountFn.self),
            let getResidency = sym("IOReportStateGetResidency", as: StateGetResidencyFn.self),
            let getNameForIndex = sym("IOReportStateGetNameForIndex", as: StateGetNameForIndexFn.self)
        else { dlclose(handle); return nil }

        guard let channelsU = copyChannels("PMP" as CFString, "Energy" as CFString, 0, 0, 0) else {
            dlclose(handle); return nil
        }
        let channels = channelsU.takeRetainedValue()          // +1 → ARC owns; freed at init end
        var subbedOut: Unmanaged<CFMutableDictionary>?
        guard let subU = createSub(nil, channels, &subbedOut, 0, nil), let subbedU = subbedOut else {
            dlclose(handle); return nil
        }
        let sub = subU.takeRetainedValue()                  // ARC-managed for this object's life
        let subbed = subbedU.takeRetainedValue()

        // Resolve bin widths from one initial sample. From here on the library handle stays
        // open even on the nil path (a live subscription's finalizer must never race dlclose).
        var widths: [String: Double] = [:]
        if let samplesU = createSamples(sub, subbed, nil) {
            let dict = samplesU.takeRetainedValue()
            if let list = (dict as NSDictionary)["IOReportChannels"] as? [Any] {
                for case let ch as NSDictionary in list {
                    let chCF = ch as CFDictionary
                    guard let name = getName(chCF)?.takeUnretainedValue() as String?,
                          isCPUClusterHistogramChannel(name),
                          getCount(chCF) > 0,
                          let first = getNameForIndex(chCF, 0)?.takeUnretainedValue() as String?,
                          let width = histogramBinWidthW(firstBinName: first)
                    else { continue }
                    widths[name] = width
                }
            }
        }
        guard !widths.isEmpty else { return nil }             // no usable cluster channel

        self.subscription = sub
        self.subbedChannels = subbed
        self.createSamples = createSamples
        self.getChannelName = getName
        self.stateGetCount = getCount
        self.stateGetResidency = getResidency
        self.binWidths = widths
    }

    /// One snapshot of every cluster channel's cumulative residency bins. nil on sample failure
    /// or when any channel resolved at init is missing — a partial set would silently under-read
    /// the CPU sum. Walks `IOReportChannels` directly (block-free, same reason as the other
    /// IOReport wrappers: no Swift 6 data race on an accumulator).
    func sample() -> [String: PowerHistogramChannel]? {
        guard let samplesU = createSamples(subscription, subbedChannels, nil) else { return nil }
        let dict = samplesU.takeRetainedValue()               // +1 consumed; released at scope exit
        guard let list = (dict as NSDictionary)["IOReportChannels"] as? [Any] else { return nil }
        var out: [String: PowerHistogramChannel] = [:]
        out.reserveCapacity(binWidths.count)
        for case let ch as NSDictionary in list {
            let chCF = ch as CFDictionary
            guard let name = getChannelName(chCF)?.takeUnretainedValue() as String?,
                  let width = binWidths[name] else { continue }
            let count = Int(stateGetCount(chCF))
            guard count > 0 else { continue }
            var bins = [UInt64](repeating: 0, count: count)
            for i in 0..<count { bins[i] = UInt64(bitPattern: stateGetResidency(chCF, Int32(i))) }
            out[name] = PowerHistogramChannel(binWidthW: width, bins: bins)
        }
        return out.count == binWidths.count ? out : nil
    }
}
