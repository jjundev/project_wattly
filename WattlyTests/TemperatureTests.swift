import Testing
import Foundation
@testable import Wattly

/// Issue 08 — temperature. Pure helpers tested directly; the provider's connection /
/// backoff / partial-failure / gating machine tested by injecting a fake transport with
/// hand-advanced instants (no hardware). The fake counts I/O so we can assert that a
/// terminal/disabled/backoff state does ZERO sensor I/O.
struct TemperatureTests {

    // MARK: Pure: profile selection

    @Test func m5ProfileResolvesForMac17_2() {
        #expect(TemperatureProfiles.profile(forModel: "Mac17,2") == TemperatureProfiles.m5)
    }
    @Test func unknownChipHasNoProfile() {
        #expect(TemperatureProfiles.profile(forModel: "Mac99,9") == nil)
        #expect(TemperatureProfiles.profile(forModel: "") == nil)
    }

    // MARK: Pure: hottest aggregation + range filter

    @Test func hottestPicksMaxInRange() {
        #expect(hottestCelsius([60, 85.3, 72], in: 0...120) == 85.3)
    }
    @Test func hottestRejectsOutOfRangeAndNonFinite() {
        // 200 is out of range, NaN/inf rejected → max of the valid {60, 85} is 85.
        #expect(hottestCelsius([200, 60, .nan, .infinity, 85], in: 0...120) == 85)
    }
    @Test func hottestEmptyOrAllInvalidIsNil() {
        #expect(hottestCelsius([], in: 0...120) == nil)
        #expect(hottestCelsius([-10, 999, .nan], in: 0...120) == nil)
    }

    // MARK: Pure: average aggregation (the new headline)

    @Test func averagePicksMeanInRange() {
        #expect(averageCelsius([60, 80], in: 0...120) == 70)
        #expect(averageCelsius([200, 60, .nan, 80], in: 0...120) == 70)   // out-of-range/NaN rejected
    }
    @Test func averageEmptyOrAllInvalidIsNil() {
        #expect(averageCelsius([], in: 0...120) == nil)
        #expect(averageCelsius([-5, 999], in: 0...120) == nil)
    }

    // MARK: Pure: battery decode

    @Test func batteryDecodesCentiCelsius() {
        #expect(batteryCelsius(rawCentiCelsius: 3000, in: 0...80) == 30.0)   // 3072 → 30.72 on-device
    }
    @Test func batteryRejectsImplausible() {
        #expect(batteryCelsius(rawCentiCelsius: 9000, in: 0...80) == nil)    // 90°C → reject
    }

    // MARK: Pure: reconnect backoff ladder (immediate once, then 1·2·4·8·16·30)

    @Test func backoffLadder() {
        #expect(reconnectBackoffSeconds(consecutiveFailures: 0) == 0)
        #expect(reconnectBackoffSeconds(consecutiveFailures: 1) == 0)   // immediate single reconnect
        #expect(reconnectBackoffSeconds(consecutiveFailures: 2) == 1)
        #expect(reconnectBackoffSeconds(consecutiveFailures: 3) == 2)
        #expect(reconnectBackoffSeconds(consecutiveFailures: 4) == 4)
        #expect(reconnectBackoffSeconds(consecutiveFailures: 5) == 8)
        #expect(reconnectBackoffSeconds(consecutiveFailures: 6) == 16)
        #expect(reconnectBackoffSeconds(consecutiveFailures: 7) == 30)
        #expect(reconnectBackoffSeconds(consecutiveFailures: 20) == 30)   // capped
    }

    // MARK: Provider: happy path on a verified chip

    @Test func verifiedChipReadsCpuGpuAndBattery() async {
        let tx = FakeTempTransport(); tx.cpuCelsius = 85; tx.gpuCelsius = 70; tx.battery = .centiCelsius(3000)
        let p = TemperatureProvider(transport: tx, model: "Mac17,2")
        let snap = await readSnapshot(p, at: base)
        #expect(snap.cpu.celsius == 85)   // uniform sensors → average == 85
        #expect(snap.gpu.celsius == 70)
        #expect(snap.battery == .reading(TemperatureReading(celsius: 30)))   // single sensor, no groups
        #expect(tx.openCalls == 1)
    }

    // MARK: Provider: cluster groups carry per-cluster average + hottest

    @Test func buildsClusterGroupsWithAverageAndHottest() async {
        let tx = FakeTempTransport()
        tx.keyValues = ["Tp00": 80, "Tp0X": 90,   // P-코어 → avg 85, hottest 90
                        "Te04": 60, "Te08": 70,   // E-코어 → avg 65, hottest 70
                        "Tg04": 50, "Tg1s": 60]   // GPU   → avg 55, hottest 60
        let p = TemperatureProvider(transport: tx, model: "Mac17,2")
        let snap = await readSnapshot(p, at: base)

        guard case .reading(let cpu) = snap.cpu else { Issue.record("cpu should read"); return }
        #expect(cpu.celsius == 75)            // headline = mean of all CPU sensors (80+90+60+70)/4
        #expect(cpu.groups == [TemperatureGroup(name: "P-코어", average: 85, hottest: 90),
                               TemperatureGroup(name: "E-코어", average: 65, hottest: 70)])

        guard case .reading(let gpu) = snap.gpu else { Issue.record("gpu should read"); return }
        #expect(gpu.celsius == 55)
        #expect(gpu.groups == [TemperatureGroup(name: "GPU", average: 55, hottest: 60)])
    }

    @Test func connectionOpensOnceAcrossPolls() async {
        let tx = FakeTempTransport(); tx.cpuCelsius = 60; tx.gpuCelsius = 55
        let p = TemperatureProvider(transport: tx, model: "Mac17,2")
        _ = await readSnapshot(p, at: base)
        _ = await readSnapshot(p, at: base.advanced(by: .seconds(2)))
        _ = await readSnapshot(p, at: base.advanced(by: .seconds(4)))
        #expect(tx.openCalls == 1)            // lazy one-shot, like Power/Battery providers
    }

    // MARK: Provider: partial failure (CPU ok, GPU unreadable) stays isolated

    @Test func cpuSucceedsWhileGpuFails() async {
        let tx = FakeTempTransport(); tx.cpuCelsius = 78; tx.gpuCelsius = nil   // GPU keys all nil
        let p = TemperatureProvider(transport: tx, model: "Mac17,2")
        let snap = await readSnapshot(p, at: base)
        #expect(snap.cpu.celsius == 78)
        #expect(snap.gpu == .unavailable(.readFailed))
    }

    // MARK: Provider: unverified chip → terminal noVerifiedProfile, ZERO SMC I/O

    @Test func unverifiedChipIsTerminalAndDoesNoSMCIO() async {
        let tx = FakeTempTransport(); tx.cpuCelsius = 99; tx.battery = .centiCelsius(3100)
        let p = TemperatureProvider(transport: tx, model: "Mac99,9")
        for i in 0..<3 {
            let snap = await readSnapshot(p, at: base.advanced(by: .seconds(Double(i * 2))))
            #expect(snap.cpu == .unavailable(.noVerifiedProfile))
            #expect(snap.gpu == .unavailable(.noVerifiedProfile))
            #expect(snap.battery == .reading(TemperatureReading(celsius: 31)))   // battery still works
        }
        #expect(tx.openCalls == 0)            // terminal → never touches the SMC
        #expect(tx.readCalls == 0)
        #expect(tx.batteryCalls == 3)         // battery is independent
    }

    // MARK: Provider: desktop battery temp hidden

    @Test func desktopBatteryTempNotPresent() async {
        let tx = FakeTempTransport(); tx.cpuCelsius = 50; tx.gpuCelsius = 48; tx.battery = .notPresent
        let p = TemperatureProvider(transport: tx, model: "Mac17,2")
        let snap = await readSnapshot(p, at: base)
        if case .notPresent = snap.battery {} else { Issue.record("battery temp should be notPresent on desktop") }
    }

    // MARK: Provider: reconnect backoff — immediate retry, then window skips I/O

    @Test func backoffSkipsIOInsideWindowThenRetries() async {
        let tx = FakeTempTransport(); tx.openDefault = false   // every open() fails
        let p = TemperatureProvider(transport: tx, model: "Mac17,2")

        _ = await readSnapshot(p, at: base)                       // open #1 fail → failures=1, retryAt = base+0
        #expect(tx.openCalls == 1)
        _ = await readSnapshot(p, at: base)                       // retryAt(base) <= base → open #2 fail → failures=2, retryAt=base+1
        #expect(tx.openCalls == 2)
        _ = await readSnapshot(p, at: base.advanced(by: .seconds(0.5)))   // inside window → NO open()
        #expect(tx.openCalls == 2)
        _ = await readSnapshot(p, at: base.advanced(by: .seconds(1.0)))   // window elapsed → open #3
        #expect(tx.openCalls == 3)

        // a failed connection surfaces as retryable connectionFailed (shows "재시도 중")
        let snap = await readSnapshot(p, at: base.advanced(by: .seconds(1.0)))
        #expect(snap.cpu == .unavailable(.connectionFailed))
        #expect(snap.cpu.isRetryableUnavailable)
    }

    // MARK: Provider: wake (large dt) resets backoff

    @Test func wakeResetsBackoff() async {
        let tx = FakeTempTransport(); tx.openDefault = false
        let p = TemperatureProvider(transport: tx, model: "Mac17,2")
        _ = await readSnapshot(p, at: base)                        // fail → failures=1
        _ = await readSnapshot(p, at: base)                        // fail → failures=2, retryAt=base+1
        _ = await readSnapshot(p, at: base.advanced(by: .seconds(0.5)))   // window → no open (openCalls=2)
        #expect(tx.openCalls == 2)
        _ = await readSnapshot(p, at: base.advanced(by: .seconds(40)))    // dt>30 → wake reset → open again
        #expect(tx.openCalls == 3)
    }

    // MARK: Provider: gating — disabled does no SMC I/O, re-enable reconnects

    @Test func disabledSkipsSMCButKeepsBattery() async {
        let tx = FakeTempTransport(); tx.cpuCelsius = 80; tx.gpuCelsius = 70; tx.battery = .centiCelsius(3000)
        let p = TemperatureProvider(transport: tx, model: "Mac17,2")
        await p.setEnabled(false)
        let snap = await readSnapshot(p, at: base)
        #expect(snap.cpu == .unavailable(.connectionFailed))
        #expect(snap.battery == .reading(TemperatureReading(celsius: 30)))   // battery independent of the gate
        #expect(tx.openCalls == 0)
        #expect(tx.readCalls == 0)

        await p.setEnabled(true)
        let snap2 = await readSnapshot(p, at: base.advanced(by: .seconds(2)))
        #expect(snap2.cpu.celsius == 80)
        #expect(tx.openCalls == 1)            // re-enable reconnected
    }

    // MARK: helpers

    private let base = ContinuousClock().now

    private func readSnapshot(_ p: TemperatureProvider, at instant: ContinuousClock.Instant) async -> TemperatureSnapshot {
        guard case .value(.temperature(let snap)) = await p.read(at: instant) else {
            Issue.record("expected a temperature snapshot"); return TemperatureSnapshot(
                cpu: .unavailable(.readFailed), gpu: .unavailable(.readFailed), battery: .unavailable(.readFailed))
        }
        return snap
    }
}

private extension CategoryReading {
    var isRetryableUnavailable: Bool {
        if case .unavailable(let e) = self { return e.isRetryable }
        return false
    }
}

/// In-memory `TemperatureTransport` for tests. Lock-guarded so the test (one isolation)
/// and the provider actor (another) can both touch it; counts I/O so "zero I/O" claims
/// are assertable. `readCelsius` classifies by key prefix (Tp/Te → CPU, Tg → GPU).
final class FakeTempTransport: TemperatureTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _openQueue: [Bool] = []
    private var _openDefault = true
    private var _cpu: Double? = nil
    private var _gpu: Double? = nil
    private var _keyValues: [String: Double] = [:]
    private var _battery: BatterySource = .centiCelsius(3000)
    private var _allUnreadable = false
    private(set) var openCalls = 0
    private(set) var readCalls = 0
    private(set) var batteryCalls = 0
    private(set) var closeCalls = 0

    var openDefault: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _openDefault }
        set { lock.lock(); _openDefault = newValue; lock.unlock() }
    }
    var openQueue: [Bool] {
        get { lock.lock(); defer { lock.unlock() }; return _openQueue }
        set { lock.lock(); _openQueue = newValue; lock.unlock() }
    }
    var cpuCelsius: Double? {
        get { lock.lock(); defer { lock.unlock() }; return _cpu }
        set { lock.lock(); _cpu = newValue; lock.unlock() }
    }
    var gpuCelsius: Double? {
        get { lock.lock(); defer { lock.unlock() }; return _gpu }
        set { lock.lock(); _gpu = newValue; lock.unlock() }
    }
    /// Explicit per-key values (for grouped-output tests). Keys not present fall back to
    /// the per-category cpu/gpu values below.
    var keyValues: [String: Double] {
        get { lock.lock(); defer { lock.unlock() }; return _keyValues }
        set { lock.lock(); _keyValues = newValue; lock.unlock() }
    }
    var battery: BatterySource {
        get { lock.lock(); defer { lock.unlock() }; return _battery }
        set { lock.lock(); _battery = newValue; lock.unlock() }
    }
    var allUnreadable: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _allUnreadable }
        set { lock.lock(); _allUnreadable = newValue; lock.unlock() }
    }

    func open() -> Bool {
        lock.lock(); defer { lock.unlock() }
        openCalls += 1
        return _openQueue.isEmpty ? _openDefault : _openQueue.removeFirst()
    }
    func readCelsius(_ key: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        readCalls += 1
        if _allUnreadable { return nil }
        if let v = _keyValues[key] { return v }
        if key.hasPrefix("Tg") { return _gpu }
        if key.hasPrefix("Tp") || key.hasPrefix("Te") { return _cpu }
        return nil
    }
    func batteryTemperature() -> BatterySource {
        lock.lock(); defer { lock.unlock() }
        batteryCalls += 1
        return _battery
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        closeCalls += 1
    }
}
