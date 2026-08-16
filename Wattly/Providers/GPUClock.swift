import Foundation
import IOKit

/// Live GPU clock source — reads IOReport's "GPU Stats" group ("GPU Performance States" subgroup)
/// for DVFS residency and maps against IORegistry `pmgr` DVFS frequency table (`voltage-states9-sram` / `voltage-states8`).
/// Preserves full table alignment (including bin 0 offset) matching `RealCPUClock`.
/// Gracefully degrades to `nil` if private symbols or tables are unavailable.
final class RealGPUClock: @unchecked Sendable {
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

    private let tableGHz: [Double]
    private var prev: [UInt64]?

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

        // Read GPU DVFS frequency table from pmgr (voltage-states9-sram, fallback to voltage-states8/9)
        guard let table = Self.readDVFSTable("voltage-states9-sram") ??
                          Self.readDVFSTable("voltage-states8") ??
                          Self.readDVFSTable("voltage-states9"),
              !table.isEmpty else {
            dlclose(handle); return nil
        }

        // Keep every entry to preserve 1:1 residency bin alignment
        self.tableGHz = table

        guard let channelsU = copyChannels("GPU Stats" as CFString,
                                           "GPU Performance States" as CFString, 0, 0, 0) else {
            dlclose(handle); return nil
        }
        let channels = channelsU.takeRetainedValue()
        var subbedOut: Unmanaged<CFMutableDictionary>?
        guard let subU = createSub(nil, channels, &subbedOut, 0, nil), let subbedU = subbedOut else {
            dlclose(handle); return nil
        }

        self.subscription = subU.takeRetainedValue()
        self.subbedChannels = subbedU.takeRetainedValue()
        self.createSamples = createSamples
        self.getChannelName = getName
        self.stateGetCount = getCount
        self.stateGetResidency = getRes
    }

    /// Sample current active clock in GHz. Returns nil on first sample (baseline) or when idle.
    func sampleGHz() -> Double? {
        guard let curr = currentResidency() else { return nil }
        defer { prev = curr }
        guard let prev else { return nil }
        return CPUFrequency.activeGHz(tableGHz: tableGHz, prev: prev, curr: curr)
    }

    private func currentResidency() -> [UInt64]? {
        guard let samplesU = createSamples(subscription, subbedChannels, nil) else { return nil }
        let dict = samplesU.takeRetainedValue()
        guard let channels = (dict as NSDictionary)["IOReportChannels"] as? [Any] else { return nil }
        for case let ch as NSDictionary in channels {
            let chCF = ch as CFDictionary
            guard let name = getChannelName(chCF)?.takeUnretainedValue() as String?,
                  name == "GPUPH" || name.contains("GPU") else { continue }
            let count = Int(stateGetCount(chCF))
            guard count > 0 else { continue }
            var bins = [UInt64](repeating: 0, count: count)
            for i in 0..<count {
                bins[i] = UInt64(bitPattern: stateGetResidency(chCF, Int32(i)))
            }
            return bins
        }
        return nil
    }

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
