import AppKit
import Darwin
import Foundation
import IOKit.ps

/// Owns the privileged XPC service and serializes every interaction with the fan and battery engines.
final class FanControlDaemon: NSObject, NSXPCListenerDelegate, FanControlXPCService, @unchecked Sendable {
    private let allowedUID: uid_t
    private let engine: FanControlEngine
    private let batteryEngine: BatteryControlEngine
    private var lastBatteryGeneration: UInt64 = 0
    private var latestBatteryStatus: BatteryControlServiceStatus
    private var lastPowerReading: (soc: Int, plugged: Bool)?
    private let listener: NSXPCListener
    private let queue = DispatchQueue(label: "dev.jjundev.WattlyFanDaemon.control")
    private var controlTimer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var listenerResumed = false

    private final class Reply: @unchecked Sendable {
        private let callback: (Data?, NSError?) -> Void

        init(_ callback: @escaping (Data?, NSError?) -> Void) {
            self.callback = callback
        }

        func send(_ result: (Data?, NSError?)) {
            callback(result.0, result.1)
        }
    }

    init(
        allowedUID: uid_t,
        hardware: any FanControlHardware,
        batteryHardware: any BatteryControlHardwareProtocol
    ) {
        self.allowedUID = allowedUID
        self.engine = FanControlEngine(hardware: hardware)
        self.batteryEngine = BatteryControlEngine(hardware: batteryHardware)
        self.latestBatteryStatus = BatteryControlServiceStatus(
            mode: .unavailable,
            currentPercentage: 0,
            isPowerAdapterConnected: false,
            detail: "초기화 중",
            updatedAt: 0
        )
        self.listener = NSXPCListener(machServiceName: FanControlXPC.machService)
        super.init()
    }

    func run() {
        listener.delegate = self
        // Do not expose the Mach service until every discovered fan has acknowledged automatic
        // mode. If an acknowledgement fails, the timer below retains and retries that fan.
        queue.sync { [self] in
            engine.resetAllFansToAutomatic(now: now())
            // Startup normalization has to run whatever the gate says: a helper that was SIGKILLed
            // while inhibiting leaves the SMC register latched, and this is what clears it.
            sampleBatteryAndEvaluate(force: true)
            resumeListenerIfSafe()
        }
        startTimers()
        observeSleep()
        observeTerminationSignals()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard isAllowedClient(connection) else { return false }
        connection.exportedInterface = NSXPCInterface(with: FanControlXPCService.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func configure(_ data: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        let reply = Reply(reply)
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let request = try FanControlCodec.decode(FanControlConfigurationRequest.self, from: data)
                try engine.configure(request.configuration, clientGeneration: request.generation, now: now())
                reply.send((try encodedStatus(), nil))
            } catch {
                reply.send((nil, error as NSError))
            }
        }
    }

    func heartbeat(withReply reply: @escaping (Data?, NSError?) -> Void) {
        let reply = Reply(reply)
        queue.async { [weak self] in
            guard let self else { return }
            engine.heartbeat(now: now())
            reply.send(statusResult())
        }
    }

    func release(_ data: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        let reply = Reply(reply)
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let request = try FanControlCodec.decode(FanControlReleaseRequest.self, from: data)
                engine.release(now: now(), reason: "앱에서 해제", clientGeneration: request.generation)
                reply.send(statusResult())
            } catch {
                reply.send((nil, error as NSError))
            }
        }
    }

    func status(withReply reply: @escaping (Data?, NSError?) -> Void) {
        let reply = Reply(reply)
        queue.async { [weak self] in
            guard let self else { return }
            reply.send(statusResult())
        }
    }

    func configureBattery(_ data: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        let reply = Reply(reply)
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let request = try BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
                guard request.generation > lastBatteryGeneration else {
                    reply.send((try BatteryControlCodec.encode(latestBatteryStatus), nil))
                    return
                }
                lastBatteryGeneration = request.generation
                batteryEngine.configure(request.configuration)
                sampleBatteryAndEvaluate(force: true)
                reply.send((try BatteryControlCodec.encode(latestBatteryStatus), nil))
            } catch {
                reply.send((nil, error as NSError))
            }
        }
    }

    func batteryStatus(withReply reply: @escaping (Data?, NSError?) -> Void) {
        let reply = Reply(reply)
        queue.async { [weak self] in
            guard let self else { return }
            sampleBatteryAndEvaluate(force: true)
            do {
                reply.send((try BatteryControlCodec.encode(latestBatteryStatus), nil))
            } catch {
                reply.send((nil, error as NSError))
            }
        }
    }

    /// `force` is for the XPC entry points and startup, where a caller is waiting on a fresh
    /// answer. The timers pass `false` so an idle machine with the limit off does no IOKit work.
    private func sampleBatteryAndEvaluate(force: Bool = false) {
        guard force || batteryEngine.needsSampling else { return }
        // Hold the last good reading rather than falling back to "0 %, unplugged": that reads as
        // "on battery" and would make the engine release a limit it should be holding.
        guard let reading = readPowerSourceState() ?? lastPowerReading else {
            latestBatteryStatus = BatteryControlServiceStatus(
                mode: .unsupported,
                currentPercentage: 0,
                isPowerAdapterConnected: false,
                detail: "전원 소스를 읽을 수 없습니다",
                updatedAt: Date().timeIntervalSince1970
            )
            return
        }
        lastPowerReading = reading
        latestBatteryStatus = batteryEngine.update(currentSoC: reading.soc, isPluggedIn: reading.plugged)
    }

    private func readPowerSourceState() -> (soc: Int, plugged: Bool)? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        let descriptions = list.compactMap {
            IOPSGetPowerSourceDescription(snapshot, $0)?.takeUnretainedValue() as? [String: Any]
        }
        // Prefer the internal battery — "whatever source is listed first" picks up an attached UPS
        // — but fall back to the first source rather than reporting nothing, so a machine that does
        // not tag its type still works exactly as it did before.
        let battery = descriptions.first { ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType }
        guard let desc = battery ?? descriptions.first else { return nil }

        let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maxCap = desc[kIOPSMaxCapacityKey] as? Int ?? 100
        let soc = maxCap > 0 ? Int((Double(current) / Double(maxCap) * 100.0).rounded()) : current
        let isPlugged = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        return (soc, isPlugged)
    }

    private func startTimers() {
        // This drives stateful manual/automatic retries at the policy cadence. The engine
        // independently limits successful target-RPM writes to `controlInterval`.
        controlTimer = makeTimer(interval: FanControlPolicy.modeRetryDelay, samplesBattery: false)
        // The charge limit moves on the order of minutes, so it rides the 5 s watchdog only.
        // Sampling it at the 0.5 s fan cadence meant two IOPS snapshot copies a second in a root
        // daemon, forever, including for users who never enabled the feature.
        watchdogTimer = makeTimer(interval: FanControlPolicy.heartbeatCheckInterval, samplesBattery: true)
    }

    private func makeTimer(interval: TimeInterval, samplesBattery: Bool) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            try? engine.tick(now: now())
            if samplesBattery { sampleBatteryAndEvaluate() }
            resumeListenerIfSafe()
        }
        timer.resume()
        return timer
    }

    private func observeSleep() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Fans MUST go back to automatic before sleep. The charge limit must NOT: dropping the
            // inhibit here is what lets an overnight sleep charge straight to 100 %, which is the
            // exact case this feature exists to prevent. Whether the SMC register itself survives
            // sleep is model-dependent, so the wake handler below re-establishes it rather than
            // trusting it — nothing downstream could detect a register cleared behind our back.
            self?.releaseSynchronously(reason: "system sleep", releaseBattery: false)
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self else { return }
                batteryEngine.reassertHardwareState()
                sampleBatteryAndEvaluate(force: true)
            }
        }
    }

    private func observeTerminationSignals() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                // Do not terminate while a controlled fan lacks a confirmed mode-0 write. A
                // bounded synchronous recovery gives shutdown a fast path; on failure, leave the
                // daemon alive so its normal timer keeps retrying the retained fan ownership.
                if self?.releaseSynchronously(reason: "daemon terminated", releaseBattery: true) == true {
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    @discardableResult
    private func releaseSynchronously(reason: String, releaseBattery: Bool) -> Bool {
        queue.sync { [self] in
            if releaseBattery { batteryEngine.release() }
            engine.release(now: now(), reason: reason)
            let deadline = now() + FanControlPolicy.modeRetryDeadline
            while true {
                if engine.recoverAutomaticSynchronously(now: now()) { return true }
                guard now() < deadline else { return false }
                Thread.sleep(forTimeInterval: FanControlPolicy.modeRetryDelay)
            }
        }
    }

    /// Must run on `queue`. This keeps listener activation ordered after the startup SMC reset.
    private func resumeListenerIfSafe() {
        guard !listenerResumed, engine.isSafeToAcceptClients else { return }
        listener.resume()
        listenerResumed = true
    }

    private func isAllowedClient(_ connection: NSXPCConnection) -> Bool {
        // NSXPCConnection exposes these values from the peer audit token as its supported API.
        guard connection.effectiveUserIdentifier == allowedUID else { return false }

        let pid = connection.processIdentifier
        guard pid > 0 else { return false }

        // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN (4096) but is unavailable to Swift.
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        guard let terminator = path.firstIndex(of: 0) else { return false }
        let executablePath = String(decoding: path[..<terminator].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: executablePath).lastPathComponent == "Wattly"
    }

    private func now() -> TimeInterval {
        Date().timeIntervalSince1970
    }

    private func encodedStatus() throws -> Data {
        try FanControlCodec.encode(engine.status)
    }

    private func statusResult() -> (Data?, NSError?) {
        do {
            return (try encodedStatus(), nil)
        } catch {
            return (nil, error as NSError)
        }
    }
}
