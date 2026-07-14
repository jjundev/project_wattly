import Testing
import Foundation
@testable import Wattly

/// Phase A — fan provider. The connection / fanless / backoff / partial-failure machine
/// is tested by injecting a fake transport with hand-advanced instants (no hardware). The
/// fake counts I/O so we can assert a fanless/terminal state does ZERO further SMC I/O.
struct FanProviderTests {

    private let base = ContinuousClock().now

    private func readReading(_ p: FanProvider, at instant: ContinuousClock.Instant) async -> ProviderReading {
        await p.read(at: instant)
    }

    @Test func readsTwoFansAndAverages() async {
        let tx = FakeFanTransport()
        tx.count = 2
        tx.fans = [0: RawFan(actual: 2000, min: 1200, max: 6000, target: 2200),
                   1: RawFan(actual: 4000, min: 1200, max: 6000, target: 4200)]
        let p = FanProvider(transport: tx)
        guard case .value(.fan(let s)) = await readReading(p, at: base) else {
            Issue.record("expected a fan sample"); return
        }
        #expect(s.fans.count == 2)
        #expect(averageRPM(s.fans) == 3000)
        #expect(tx.openCalls == 1)
    }

    @Test func fanlessIsNotPresentAndDoesNoFurtherIO() async {
        let tx = FakeFanTransport()
        tx.count = 0   // FNum == 0 → fanless (MacBook Air)
        let p = FanProvider(transport: tx)
        for i in 0..<3 {
            let r = await readReading(p, at: base.advanced(by: .seconds(Double(i * 2))))
            guard case .unavailable(.notPresent(let msg)) = r else {
                Issue.record("expected notPresent, got \(r)"); return
            }
            #expect(msg == "팬 없음 — 팬리스 Mac")
        }
        // Terminal after the first detection: FNum read once, individual fans never read.
        #expect(tx.readFanCalls == 0)
        #expect(tx.fanCountCalls == 1)
    }

    @Test func openFailureIsRetryableChannelUnreadable() async {
        let tx = FakeFanTransport(); tx.openDefault = false
        let p = FanProvider(transport: tx)
        let r = await readReading(p, at: base)
        guard case .unavailable(.channelUnreadable) = r else {
            Issue.record("expected channelUnreadable, got \(r)"); return
        }
    }

    @Test func allFansUnreadableClosesAndBacksOff() async {
        let tx = FakeFanTransport(); tx.count = 2; tx.fans = [:]   // count OK, every fan read nil
        let p = FanProvider(transport: tx)
        let r = await readReading(p, at: base)
        guard case .unavailable(.channelUnreadable) = r else {
            Issue.record("expected channelUnreadable, got \(r)"); return
        }
        #expect(tx.closeCalls == 1)   // stale connection dropped
    }

    @Test func connectionOpensOnceAcrossPolls() async {
        let tx = FakeFanTransport(); tx.count = 1
        tx.fans = [0: RawFan(actual: 2400, min: 1200, max: 6000, target: 2500)]
        let p = FanProvider(transport: tx)
        _ = await readReading(p, at: base)
        _ = await readReading(p, at: base.advanced(by: .seconds(5)))
        _ = await readReading(p, at: base.advanced(by: .seconds(10)))
        #expect(tx.openCalls == 1)
    }

    @Test func implausibleFanCountIsRejectedWithoutReadingAnyFan() async {
        let tx = FakeFanTransport(); tx.count = 200   // corrupt/garbage FNum byte, way past any real Mac
        let p = FanProvider(transport: tx)
        let r = await readReading(p, at: base)
        guard case .unavailable(.channelUnreadable) = r else {
            Issue.record("expected channelUnreadable, got \(r)"); return
        }
        // Never trusted as a loop bound: not one `readFan` call was made.
        #expect(tx.readFanCalls == 0)
        #expect(tx.closeCalls == 1)   // connection dropped, same as any other bad read
    }

    @Test func wakeResetsConnection() async {
        let tx = FakeFanTransport(); tx.count = 1
        tx.fans = [0: RawFan(actual: 2400, min: 1200, max: 6000, target: 2500)]
        let p = FanProvider(transport: tx)
        _ = await readReading(p, at: base)
        #expect(tx.openCalls == 1)
        _ = await readReading(p, at: base.advanced(by: .seconds(40)))   // dt > 30 → wake reset → reopen
        #expect(tx.openCalls == 2)
    }
}

/// In-memory `FanTransport` for tests. Lock-guarded so the test isolation and the provider
/// actor can both touch it; counts I/O so "zero further I/O" claims are assertable.
final class FakeFanTransport: FanTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _openDefault = true
    private var _count: Int? = 1
    private var _fans: [Int: RawFan] = [:]
    private(set) var openCalls = 0
    private(set) var fanCountCalls = 0
    private(set) var readFanCalls = 0
    private(set) var closeCalls = 0

    var openDefault: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _openDefault }
        set { lock.lock(); _openDefault = newValue; lock.unlock() }
    }
    var count: Int? {
        get { lock.lock(); defer { lock.unlock() }; return _count }
        set { lock.lock(); _count = newValue; lock.unlock() }
    }
    var fans: [Int: RawFan] {
        get { lock.lock(); defer { lock.unlock() }; return _fans }
        set { lock.lock(); _fans = newValue; lock.unlock() }
    }

    func open() -> Bool { lock.lock(); defer { lock.unlock() }; openCalls += 1; return _openDefault }
    func fanCount() -> Int? { lock.lock(); defer { lock.unlock() }; fanCountCalls += 1; return _count }
    func readFan(_ index: Int) -> RawFan? {
        lock.lock(); defer { lock.unlock() }; readFanCalls += 1; return _fans[index]
    }
    func close() { lock.lock(); defer { lock.unlock() }; closeCalls += 1 }
}
