import Foundation
import Observation
import AppKit

/// The app-side endpoint for the privileged fan-control helper. It transports only a curve
/// configuration and heartbeats; all SMC writes remain exclusively in the helper process.
@MainActor
@Observable final class FanControlClient {
    private let requestHandler: FanControlRequestHandler

    private(set) var status = FanControlServiceStatus(
        mode: .unavailable,
        detail: "도우미에 연결되지 않음",
        updatedAt: 0
    )
    // True while the privileged helper install (admin auth prompt) is running.
    private(set) var isInstallingHelper = false

    // Seed above the previous app process's sequence if its helper is still running. Microseconds
    // leave ample room for local increments while avoiding a persisted client-side counter.
    private var commandGeneration = UInt64(Date().timeIntervalSince1970 * 1_000_000)

    init(requestHandler: FanControlRequestHandler? = nil) {
        self.requestHandler = requestHandler ?? { request in
            switch request {
            case .configure(let data):
                return await Self.request { service, reply in service.configure(data, withReply: reply) }
            case .heartbeat:
                return await Self.request { service, reply in service.heartbeat(withReply: reply) }
            case .release(let data):
                return await Self.request { service, reply in service.release(data, withReply: reply) }
            case .status:
                return await Self.request { service, reply in service.status(withReply: reply) }
            }
        }
    }

    func apply(enabled: Bool, curve: FanCurve) async {
        guard let data = try? FanControlCodec.encode(FanControlConfigurationRequest(
            configuration: .init(enabled: enabled, curve: curve),
            generation: nextCommandGeneration()
        )) else {
            updateUnavailable("팬 커브를 인코딩할 수 없음")
            return
        }
        await send(.configure(data))
    }

    func heartbeat() async {
        await send(.heartbeat)
    }

    /// Reads the helper's current state without changing fan ownership. This is separate from
    /// heartbeat because a menu-bar open must distinguish automatic mode from an active session.
    @discardableResult
    func refreshStatus() async -> FanControlServiceStatus? {
        await send(.status)
    }

    /// Repairs the session that the daemon intentionally released during system sleep. The
    /// caller snapshots its @AppStorage values before awaiting so a settings change cannot alter
    /// the request halfway through this menu-bar-open transaction.
    func reconcileAfterMenuBarOpen(enabled: Bool, curve: FanCurve) async {
        guard enabled else { return }
        guard let refreshedStatus = await refreshStatus(),
              FanControlPolicy.shouldReapplyAfterMenuBarOpen(enabled: enabled,
                                                               mode: refreshedStatus.mode) else {
            return
        }
        await apply(enabled: true, curve: curve)
    }

    func release() async {
        guard let data = try? FanControlCodec.encode(FanControlReleaseRequest(generation: nextCommandGeneration())) else {
            updateUnavailable("팬 제어 해제 요청을 인코딩할 수 없음")
            return
        }
        await send(.release(data))
    }

    /// Installs the privileged helper via one admin-auth prompt, then applies the specified curve to
    /// engage control. If the user cancels the prompt (or it fails), returns false.
    ///
    /// Window-survival: this is an accessory (LSUIElement) app, and the admin-auth dialog
    /// deactivates it long enough (on the success path, while the root script runs) for macOS to
    /// destroy the Settings window — reopening it afterward proved unreliable. So instead we hold a
    /// **regular activation policy for the duration of the install**: a regular app keeps its windows
    /// when deactivated, so the Settings window is never torn down. The menubar-only policy (and its
    /// absent Dock icon) is restored once the window is back up front.
    @discardableResult
    func installAndEngage(curve: FanCurve, window: NSWindow?) async -> Bool {
        isInstallingHelper = true
        defer { isInstallingHelper = false }

        // Hold a regular activation policy across the whole flow: it keeps the Settings window
        // alive through the auth-dialog deactivation AND lets it layer like a normal app's window
        // while we re-raise it (an accessory app's window sinks behind the active app).
        let priorPolicy = NSApp.activationPolicy()
        let raised = priorPolicy != .regular
        if raised { NSApp.setActivationPolicy(.regular) }

        // Keep the Settings window visible UNDER the auth panel for the whole prompt + script run
        // (~seconds): order it front every 0.4s so it doesn't sink behind other apps. Crucially this
        // uses `orderFrontRegardless` only — NOT `activate`, which would steal keyboard focus from the
        // password field. `install()` runs its `osascript` on a background thread, so the main actor
        // is free to run this loop while we await it.
        let keepVisible = Task { @MainActor in
            while !Task.isCancelled {
                window?.orderFrontRegardless()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }

        var installed = true
        do {
            try await FanHelperInstaller.install()
        } catch {
            installed = false
        }
        keepVisible.cancel()

        // Re-raise Settings the INSTANT the auth dialog is gone — before the XPC `apply` below.
        // `apply` connects to the just-started daemon and can stall for several seconds; doing it
        // first was what left the window sunk for ~10s. `activate` only raises the app, so drive the
        // captured window itself with `orderFrontRegardless`.
        raiseFront(window)

        if installed {
            await apply(enabled: true, curve: curve)
        }

        // Drop the transient Dock icon, then re-front once more (restoring `.accessory` while another
        // app is active can sink the window), with a couple of retries to win any late focus steal.
        if raised { NSApp.setActivationPolicy(priorPolicy) }
        for _ in 0..<3 {
            raiseFront(window)
            try? await Task.sleep(for: .milliseconds(300))
        }

        return installed
    }

    private func raiseFront(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    @discardableResult
    private func send(_ request: FanControlClientRequest) async -> FanControlServiceStatus? {
        switch await requestHandler(request) {
        case .success(let value):
            status = value
            return value
        case .failure(let failure):
            updateUnavailable(failure.detail)
            return nil
        }
    }

    /// NSXPC invokes both reply and proxy-error handlers on a private queue. Keep that boundary
    /// nonisolated and resume at most once before returning to this main-actor client.
    private nonisolated static func request(
        _ call: @escaping @Sendable (any FanControlXPCService,
                                     @escaping (Data?, NSError?) -> Void) -> Void
    ) async -> Result<FanControlServiceStatus, FanControlClientRequestFailure> {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: FanControlXPC.machService,
                                             options: .privileged)
            let completion = XPCRequestCompletion(connection: connection, continuation: continuation)
            connection.remoteObjectInterface = NSXPCInterface(with: FanControlXPCService.self)
            connection.resume()

            guard let service = connection.remoteObjectProxyWithErrorHandler({ error in
                completion.finish(.failure(.init(detail: error.localizedDescription)))
            }) as? any FanControlXPCService else {
                completion.finish(.failure(.init(detail: "도우미 연결을 만들 수 없음")))
                return
            }

            call(service) { data, error in
                guard error == nil,
                      let data,
                      let value = try? FanControlCodec.decode(FanControlServiceStatus.self, from: data)
                else {
                    completion.finish(.failure(.init(detail: error?.localizedDescription ?? "도우미 응답 오류")))
                    return
                }
                completion.finish(.success(value))
            }
        }
    }

    private func updateUnavailable(_ detail: String) {
        status = .init(mode: .unavailable,
                       detail: detail,
                       updatedAt: Date().timeIntervalSince1970)
    }

    private func nextCommandGeneration() -> UInt64 {
        commandGeneration &+= 1
        return commandGeneration
    }
}

/// Thread-safe completion gate for the mutually exclusive XPC reply/error callbacks.
private final class XPCRequestCompletion: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let continuation: CheckedContinuation<Result<FanControlServiceStatus, FanControlClientRequestFailure>, Never>
    private let lock = NSLock()
    private var didFinish = false

    init(connection: NSXPCConnection,
         continuation: CheckedContinuation<Result<FanControlServiceStatus, FanControlClientRequestFailure>, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ result: Result<FanControlServiceStatus, FanControlClientRequestFailure>) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()

        connection.invalidate()
        continuation.resume(returning: result)
    }
}

enum FanControlClientRequest: Equatable, Sendable {
    case configure(Data)
    case heartbeat
    case release(Data)
    case status
}

typealias FanControlRequestHandler = @Sendable (FanControlClientRequest) async -> Result<FanControlServiceStatus, FanControlClientRequestFailure>

struct FanControlClientRequestFailure: Error, Sendable {
    let detail: String
}
