import Foundation
import IOKit

/// What the fan provider reads through — the single read-only seam under which the real
/// SMC I/O lives (mirrors `TemperatureTransport`). The provider knows only this protocol,
/// so the connection / fanless / backoff machine is tested with a fake transport (no
/// hardware) and the `io_connect_t` never leaves the live implementation.
protocol FanTransport: Sendable {
    /// Open the SMC connection. `false` ⇒ retryable failure (→ backoff).
    func open() -> Bool
    /// `FNum` (fan count). `0` ⇒ fanless (MacBook Air). `nil` ⇒ unreadable (stale/failed).
    func fanCount() -> Int?
    /// One fan's RPM fields, or `nil` if its actual-RPM key is unreadable.
    func readFan(_ index: Int) -> RawFan?
    /// Release the SMC connection (terminal / stale-after-wake).
    func close()
}

/// One fan's raw decoded RPM fields (actual/min/max/target). `min`/`max`/`target` default
/// to 0 in the live transport when their key is absent — only `actual` gates readability.
struct RawFan: Sendable, Equatable {
    var actual: Double
    var min: Double
    var max: Double
    var target: Double
}

/// Real fan provider (Phase A) — no entitlements, read-only SMC. Fans come from the standard
/// `FNum` / `F{n}Ac|Mn|Mx|Tg` keys; unlike temperature there is no per-chip verified profile
/// (these keys are universal), so the provider probes `FNum` at runtime. `FNum == 0` is the
/// fanless (MacBook Air) path → `.notPresent`, which hides the card exactly like the desktop
/// battery. All arithmetic is in pure `Fan`; this actor only orchestrates I/O and lifecycle.
///
/// `actor` is required: `read` is awaited from the `@MainActor` `SystemMonitor`, so the
/// synchronous IOKit calls run off the main thread (like `TemperatureProvider`).
actor FanProvider: MetricProvider {
    let kind: ProviderKind = .fan

    static let fanlessMessage = "팬 없음 — 팬리스 Mac"
    static let unreadableMessage = "팬 센서에 연결할 수 없음 — 재시도 중"
    /// Plausibility band (RPM). A finite reading outside this is rejected as bogus.
    private static let rpmRange = 0.0...12000.0
    /// Elapsed beyond this ⇒ a gap (missed poll / sleep-wake) → reset backoff + reconnect
    /// (mirrors `TemperatureProvider.maxPlausibleDt`).
    private static let maxPlausibleDt = 30.0

    private let transport: any FanTransport

    private var smcOpen = false
    /// Terminal once `FNum` reads 0 — a fanless Mac never grows a fan, so we short-circuit
    /// with zero further I/O (mirrors temperature's `noVerifiedProfile` terminal).
    private var fanless = false
    private var consecutiveFailures = 0
    private var retryAt: ContinuousClock.Instant?
    private var lastInstant: ContinuousClock.Instant?

    init(transport: any FanTransport = SMCFanTransport()) {
        self.transport = transport
    }

    func read(at instant: ContinuousClock.Instant) async -> ProviderReading {
        // Sleep/wake or a long gap → the io_connect_t may be stale: reset and reconnect.
        if let last = lastInstant, Self.seconds(from: last, to: instant) > Self.maxPlausibleDt {
            resetConnection()
        }
        defer { lastInstant = instant }

        if fanless { return .unavailable(.notPresent(Self.fanlessMessage)) }   // terminal, zero I/O

        if !smcOpen {
            if let retryAt, instant < retryAt {
                return .unavailable(.channelUnreadable(Self.unreadableMessage))  // in backoff window
            }
            if transport.open() {
                smcOpen = true
                consecutiveFailures = 0
                retryAt = nil
            } else {
                registerFailure(at: instant)
                return .unavailable(.channelUnreadable(Self.unreadableMessage))
            }
        }

        guard let count = transport.fanCount() else {
            transport.close(); smcOpen = false
            registerFailure(at: instant)
            return .unavailable(.channelUnreadable(Self.unreadableMessage))
        }

        if count == 0 {
            fanless = true
            transport.close(); smcOpen = false
            return .unavailable(.notPresent(Self.fanlessMessage))
        }

        var fans: [FanReading] = []
        for i in 0..<count {
            guard let raw = transport.readFan(i),
                  raw.actual.isFinite, Self.rpmRange.contains(raw.actual) else { continue }
            fans.append(FanReading(index: i, actualRPM: raw.actual,
                                   minRPM: raw.min, maxRPM: raw.max, targetRPM: raw.target))
        }

        if fans.isEmpty {
            // Count > 0 but not one fan readable ⇒ connection went stale → invalidate + back off.
            transport.close(); smcOpen = false
            registerFailure(at: instant)
            return .unavailable(.channelUnreadable(Self.unreadableMessage))
        }

        return .value(.fan(FanSample(fans: fans)))
    }

    private func registerFailure(at instant: ContinuousClock.Instant) {
        consecutiveFailures += 1
        let wait = reconnectBackoffSeconds(consecutiveFailures: consecutiveFailures)
        retryAt = instant.advanced(by: .seconds(wait))
    }

    private func resetConnection() {
        consecutiveFailures = 0
        retryAt = nil
        if smcOpen { transport.close(); smcOpen = false }
    }

    private static func seconds(from a: ContinuousClock.Instant, to b: ContinuousClock.Instant) -> Double {
        let d = a.duration(to: b)
        return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }
}

// MARK: - Live transport

/// Live `FanTransport`: SMC (`SMCConnection`) for the `FNum` / `F{n}Ac|Mn|Mx|Tg` keys. Only
/// ever touched inside `FanProvider`'s actor isolation, so `@unchecked Sendable` (same basis
/// as `SMCTemperatureTransport`). Fan RPM keys are `flt ` on Apple silicon; `smcDouble`
/// decodes both `flt ` and the integer `FNum`.
final class SMCFanTransport: FanTransport, @unchecked Sendable {
    private var smc: SMCConnection?

    func open() -> Bool {
        if smc != nil { return true }
        smc = SMCConnection()
        return smc != nil
    }

    func fanCount() -> Int? {
        guard let smc, let r = smc.read("FNum") else { return nil }
        let v = smcDouble(r.bytes, type: r.type)
        return v.isFinite ? Int(v) : nil
    }

    func readFan(_ index: Int) -> RawFan? {
        guard let smc else { return nil }
        func rpm(_ suffix: String) -> Double? {
            guard let r = smc.read("F\(index)\(suffix)") else { return nil }
            let v = smcDouble(r.bytes, type: r.type)
            return v.isFinite ? v : nil
        }
        guard let actual = rpm("Ac") else { return nil }
        return RawFan(actual: actual, min: rpm("Mn") ?? 0, max: rpm("Mx") ?? 0, target: rpm("Tg") ?? 0)
    }

    func close() { smc = nil }   // SMCConnection.deinit closes the io_connect_t
}

#if DEBUG
/// DEBUG on-device verification probe (Phase A Phase-0). Run headless to dump live fan
/// readings from the REAL provider + live transport, then exit — for confirming the `FNum` /
/// `F0Ac` keys read plausible RPM on this Mac before trusting the card:
///   `Wattly.app/Contents/MacOS/Wattly -WattlyFanProbe`
/// Excluded from Release. Detached so it runs off the (blocked) main thread.
enum FanProbe {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("-WattlyFanProbe") else { return }
        let provider = FanProvider()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let clock = ContinuousClock()
            for i in 0..<3 {
                let reading = await provider.read(at: clock.now)
                print("[fan-probe] sample \(i): \(describe(reading))")
                try? await Task.sleep(for: .seconds(1))
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }

    private static func describe(_ r: ProviderReading) -> String {
        switch r {
        case .value(.fan(let s)):
            let fans = s.fans.map { "팬\($0.index) \(Int($0.actualRPM))rpm(목표 \(Int($0.targetRPM)), \(Int($0.minRPM))–\(Int($0.maxRPM)))" }
                .joined(separator: ", ")
            return "avg \(averageRPM(s.fans).map { Int($0) } ?? 0) rpm [\(fans)]"
        case .unavailable(let reason): return "unavailable(\(reason.message))"
        default: return "\(r)"
        }
    }
}
#endif
