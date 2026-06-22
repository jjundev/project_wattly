import Foundation

/// The injected source of Wattly's own cumulative energy counter (issue 16). A seam so
/// the self-power math (`SelfPower`) and `SystemMonitor`'s sampling stay deterministically
/// testable — production reads libproc, tests inject a scripted fake. Mirrors the
/// `MonotonicClock` seam.
protocol SelfEnergySampling: Sendable {
    /// Our process's absolute energy draw since launch, in nanojoules, or nil if the
    /// counter is unreadable. Monotonic within one process lifetime.
    func energyNanojoules() -> UInt64?
}

/// Live reader: `proc_pid_rusage(getpid(), RUSAGE_INFO_V6).ri_energy_nj`. Public,
/// no entitlement — the exact libproc idiom `MemoryProvider` uses for `ri_phys_footprint`
/// (`RUSAGE_INFO_V2`), bumped to V6 for the energy field. The own-process call does not
/// fail in practice; a nonzero `rc` (or an OS that doesn't populate the field) returns nil
/// → the footer stays "—" rather than reading a bogus value.
struct LiveSelfEnergy: SelfEnergySampling {
    func energyNanojoules() -> UInt64? {
        var info = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0)
            }
        }
        return rc == 0 ? info.ri_energy_nj : nil
    }
}
