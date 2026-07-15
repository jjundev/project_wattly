import AppKit
import Darwin
import Foundation

/// Owns the privileged XPC service and serializes every interaction with the fan engine.
final class FanControlDaemon: NSObject, NSXPCListenerDelegate, FanControlXPCService, @unchecked Sendable {
    private let allowedUID: uid_t
    private let engine: FanControlEngine
    private let listener: NSXPCListener
    private let queue = DispatchQueue(label: "dev.jjundev.WattlyFanDaemon.control")
    private var controlTimer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var sleepObserver: NSObjectProtocol?

    private final class Reply: @unchecked Sendable {
        private let callback: (Data?, NSError?) -> Void

        init(_ callback: @escaping (Data?, NSError?) -> Void) {
            self.callback = callback
        }

        func send(_ result: (Data?, NSError?)) {
            callback(result.0, result.1)
        }
    }

    init(allowedUID: uid_t, hardware: any FanControlHardware) {
        self.allowedUID = allowedUID
        engine = FanControlEngine(hardware: hardware)
        listener = NSXPCListener(machServiceName: FanControlXPC.machService)
        super.init()
    }

    func run() {
        listener.delegate = self
        listener.resume()
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
                let configuration = try FanControlCodec.decode(FanControlConfiguration.self, from: data)
                try engine.configure(configuration, now: now())
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

    func release(withReply reply: @escaping (Data?, NSError?) -> Void) {
        let reply = Reply(reply)
        queue.async { [weak self] in
            guard let self else { return }
            engine.release(now: now(), reason: "앱에서 해제")
            reply.send(statusResult())
        }
    }

    func status(withReply reply: @escaping (Data?, NSError?) -> Void) {
        let reply = Reply(reply)
        queue.async { [weak self] in
            guard let self else { return }
            reply.send(statusResult())
        }
    }

    private func startTimers() {
        controlTimer = makeTimer(interval: FanControlPolicy.controlInterval)
        watchdogTimer = makeTimer(interval: FanControlPolicy.heartbeatCheckInterval)
    }

    private func makeTimer(interval: TimeInterval) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            try? engine.tick(now: now())
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
            self?.releaseSynchronously(reason: "system sleep")
        }
    }

    private func observeTerminationSignals() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                self?.releaseSynchronously(reason: "daemon terminated")
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func releaseSynchronously(reason: String) {
        queue.sync { [self] in
            engine.release(now: now(), reason: reason)
        }
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
