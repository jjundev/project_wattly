import Foundation
import IOKit

/// Live per-cluster CPU clock source (plan 21) — reads the IOReport private API's "CPU Stats"
/// group ("CPU Complex Performance States" subgroup) for per-cluster DVFS residency, plus the
/// IORegistry `pmgr` DVFS frequency tables (`voltage-statesN-sram`). Mirrors
/// `IOReportEnergySubscription`: dlopen'd symbols + subscription live only inside this object,
/// touched solely from `CPUProvider`'s actor isolation (hence `@unchecked Sendable`). All
/// arithmetic lives in pure `CPUFrequency`.
final class RealCPUClock: @unchecked Sendable {
    // Two clusters — matches every current Apple Silicon Mac's 2-perflevel topology. A
    // hypothetical 3+-level chip collapses indices ≥1 onto `.efficiency` (acceptable
    // degrade; the rest of the CPU-card code shares the same 2-level assumption).
    private enum Cluster: Hashable { case performance, efficiency }

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

    private let subscription: AnyObject
    private let subbedChannels: CFMutableDictionary
    private let createSamples: CreateSamplesFn
    private let getChannelName: GetStringFn
    private let stateGetCount: StateGetCountFn
    private let stateGetResidency: StateGetResidencyFn

    /// DVFS freq tables (GHz) per cluster, read once from IORegistry.
    private let tables: [Cluster: [Double]]
    /// Previous cumulative residency bins per cluster — nil until the first sample.
    private var prev: [Cluster: [UInt64]] = [:]

    /// nil if the library, any symbol, the "CPU Stats" group, or every DVFS table is
    /// unavailable — graceful degrade (the CPU card then simply shows no clock).
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
            let getRes = sym("IOReportStateGetResidency", as: StateGetResidencyFn.self)
        else { dlclose(handle); return nil }

        // One channel per cluster (ECPU/PCPU) lives in this subgroup.
        guard let channelsU = copyChannels("CPU Stats" as CFString,
                                           "CPU Complex Performance States" as CFString, 0, 0, 0) else {
            dlclose(handle); return nil
        }
        let channels = channelsU.takeRetainedValue()
        var subbedOut: Unmanaged<CFMutableDictionary>?
        guard let subU = createSub(nil, channels, &subbedOut, 0, nil), let subbedU = subbedOut else {
            dlclose(handle); return nil
        }

        // states5-sram = performance cluster, states1-sram = efficiency (asitop/macmon convention,
        // verified on M5). An absent table just means that cluster reports no clock.
        var t: [Cluster: [Double]] = [:]
        if let p = Self.readDVFSTable("voltage-states5-sram") { t[.performance] = p }
        if let e = Self.readDVFSTable("voltage-states1-sram") { t[.efficiency] = e }
        // Self-correct the table↔cluster pairing (needs-you §3): the performance cluster always
        // tops out higher than efficiency, so if a chip decoded reversed, swap — no runtime
        // dependence on the hardcoded states5=P/states1=E convention holding on every SoC.
        if let p = t[.performance], let e = t[.efficiency],
           let pMax = p.max(), let eMax = e.max(), pMax < eMax {
            t[.performance] = e; t[.efficiency] = p
        }
        guard !t.isEmpty else { dlclose(handle); return nil }

        self.subscription = subU.takeRetainedValue()
        self.subbedChannels = subbedU.takeRetainedValue()
        self.createSamples = createSamples
        self.getChannelName = getName
        self.stateGetCount = getCount
        self.stateGetResidency = getRes
        self.tables = t
        // library handle intentionally left open (matches IOReportEnergySubscription).
    }

    /// Per-perf-level active clock (GHz), indexed to `topology` order: element i is the clock
    /// for `topology[i]`. `topology[0]` is the highest-performance level → performance cluster
    /// (PCPU/states5); index 1 → efficiency. nil where unavailable or first-poll baseline.
    func sampleGHz(topology: [PerfLevel]) -> [Double?] {
        guard !topology.isEmpty else { return [] }
        let residencies = currentResidencies()
        defer { for (k, v) in residencies { prev[k] = v } }

        var byCluster: [Cluster: Double?] = [:]
        for (cluster, curr) in residencies {
            guard let table = tables[cluster], let p = prev[cluster] else {
                byCluster[cluster] = Double?.none          // baseline poll → nil
                continue
            }
            byCluster[cluster] = CPUFrequency.activeGHz(tableGHz: table, prev: p, curr: curr)
        }

        return topology.indices.map { i in
            let cluster: Cluster = (i == 0) ? .performance : .efficiency
            return byCluster[cluster] ?? nil
        }
    }

    /// One residency snapshot per cluster, summed across dies of the same kind. Walks the
    /// sample dict's `IOReportChannels` array directly (block-free — same reason as the energy
    /// subscription: no Swift 6 data race on an accumulator).
    private func currentResidencies() -> [Cluster: [UInt64]] {
        guard let samplesU = createSamples(subscription, subbedChannels, nil) else { return [:] }
        let dict = samplesU.takeRetainedValue()
        guard let channels = (dict as NSDictionary)["IOReportChannels"] as? [Any] else { return [:] }
        var out: [Cluster: [UInt64]] = [:]
        for case let ch as NSDictionary in channels {
            let chCF = ch as CFDictionary
            guard let name = getChannelName(chCF)?.takeUnretainedValue() as String? else { continue }
            let cluster: Cluster
            if name.contains("PCPU") { cluster = .performance }
            else if name.contains("ECPU") { cluster = .efficiency }
            else { continue }
            let count = Int(stateGetCount(chCF))
            guard count > 0 else { continue }
            var bins = [UInt64](repeating: 0, count: count)
            for i in 0..<count { bins[i] = UInt64(bitPattern: stateGetResidency(chCF, Int32(i))) }
            if let existing = out[cluster], existing.count == bins.count {
                out[cluster] = zip(existing, bins).map { $0 &+ $1 }   // sum dies of same kind
            } else {
                out[cluster] = bins
            }
        }
        return out
    }

    /// First `AppleARMIODevice` (the `pmgr` node) that carries `key`, decoded to a GHz table.
    private static func readDVFSTable(_ key: String) -> [Double]? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleARMIODevice"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var result: [Double]?
        while true {
            let service = IOIteratorNext(iter)
            if service == 0 { break }
            if result == nil,
               let cf = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let data = cf as? Data {
                let table = CPUFrequency.decodeDVFSTable(data)
                if !table.isEmpty { result = table }
            }
            IOObjectRelease(service)
        }
        return result
    }
}
