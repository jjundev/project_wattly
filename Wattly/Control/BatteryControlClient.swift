import Foundation
import Observation
import AppKit

@MainActor
@Observable public final class BatteryControlClient {
    public enum BatteryControlClientRequest: Sendable, Equatable {
        case configure(Data)
        case status
    }

    public typealias RequestHandler = @Sendable (BatteryControlClientRequest) async -> (Data?, NSError?)
    typealias InstallHandler = @MainActor (
        NSWindow?, Bool, @escaping @MainActor () async -> Void
    ) async -> Error?

    /// Why enabling the limit did not take. Kept structured rather than pre-rendered: the message
    /// embeds the helper's status, and only the view knows what language to build it in.
    public enum InstallFailure: Error {
        /// The privileged install itself failed or was cancelled. `localizedDescription` is either
        /// a catalog key from `FanHelperInstaller.InstallError` or text macOS already localized.
        case install(any Error)
        /// The helper installed and answered, but would not take the configuration.
        case configureRejected(reason: BatteryControlStatusReason?, detail: String)
    }

    public enum DisableFailure: Error, Equatable {
        case helperUnavailable
        case persistenceRejected
        case releaseUnverified
    }

    private let requestHandler: RequestHandler
    private let installHandler: InstallHandler
    public private(set) var status = BatteryControlServiceStatus(
        mode: .unavailable,
        currentPercentage: 0,
        isPowerAdapterConnected: false,
        detail: "도우미에 연결되지 않음",
        updatedAt: 0
    )
    public private(set) var isInstallingHelper = false
    private var commandGeneration = UInt64(Date().timeIntervalSince1970 * 1_000_000)

    public convenience init(requestHandler: RequestHandler? = nil) {
        self.init(requestHandler: requestHandler, installHandler: nil)
    }

    init(requestHandler: RequestHandler?, installHandler: InstallHandler?) {
        self.requestHandler = requestHandler ?? { req in
            switch req {
            case .configure(let data):
                return await Self.sendXPC { svc, reply in svc.configureBattery(data, withReply: reply) }
            case .status:
                return await Self.sendXPC { svc, reply in svc.batteryStatus(withReply: reply) }
            }
        }
        self.installHandler = installHandler ?? { window, transferringOwnership, postInstall in
            await PrivilegedHelperInstallSession.run(
                window: window,
                transferringOwnership: transferringOwnership,
                postInstall: postInstall)
        }
    }

    @discardableResult
    public func apply(
        enabled: Bool,
        limitPercentage: Int,
        lowerHysteresisDelta: Int = 2
    ) async -> BatteryControlServiceStatus? {
        commandGeneration &+= 1
        let config = BatteryControlConfiguration(enabled: enabled, limitPercentage: limitPercentage, lowerHysteresisDelta: lowerHysteresisDelta)
        let request = BatteryControlConfigurationRequest(configuration: config, generation: commandGeneration)
        guard let data = try? BatteryControlCodec.encode(request) else {
            updateUnavailable("충전 제한 설정을 인코딩할 수 없음")
            return nil
        }
        return await send(.configure(data))
    }

    public func disableAndConfirm(
        limitPercentage: Int = 100,
        lowerHysteresisDelta: Int = 2
    ) async -> DisableFailure? {
        guard let acknowledged = await apply(
            enabled: false,
            limitPercentage: limitPercentage,
            lowerHysteresisDelta: lowerHysteresisDelta) else {
            return .helperUnavailable
        }
        guard acknowledged.desiredConfiguration?.enabled == false else {
            return .persistenceRejected
        }
        let safe = acknowledged.actualGate?.state == .allowed
            || acknowledged.releaseVerdict?.isSafeToRemove == true
        return safe ? nil : .releaseUnverified
    }

    @discardableResult
    public func refreshStatus() async -> BatteryControlServiceStatus? {
        await send(.status)
    }

    /// Repairs a helper that restarted and lost its configuration. Reads the helper's state first,
    /// so a healthy helper costs one status call and no SMC traffic at all.
    public func reconcile(enabled: Bool, limitPercentage: Int, lowerHysteresisDelta: Int = 2) async {
        await refreshStatus()
        // The caller's task may have been cancelled while that read was in flight, and a reconcile
        // is a WRITE — unlike the fan heartbeat this loop is modelled on. Without this check a
        // straggler iteration would re-enable a limit the user just switched off, carrying a higher
        // generation than the disable that raced it, and nothing would ever repair it.
        guard !Task.isCancelled,
              BatteryControlPolicy.shouldReapply(
                configuration: .init(
                    enabled: enabled,
                    limitPercentage: limitPercentage,
                    lowerHysteresisDelta: lowerHysteresisDelta),
                status: status) else { return }
        if enabled {
            await apply(
                enabled: true,
                limitPercentage: limitPercentage,
                lowerHysteresisDelta: lowerHysteresisDelta)
        } else {
            _ = await disableAndConfirm(
                limitPercentage: limitPercentage,
                lowerHysteresisDelta: lowerHysteresisDelta)
        }
    }

    /// Installs the privileged helper with one admin-auth prompt and immediately pushes the user's
    /// configuration — without this the helper would sit at its disabled default while the toggle
    /// reads ON. `enabled` is the caller's real opt-in rather than an assumption, so installing from
    /// a recovery button can never switch the limit on behind the user's back.
    /// Returns `nil` only when both halves landed.
    public func installAndApply(
        enabled: Bool,
        limitPercentage: Int,
        lowerHysteresisDelta: Int = 2,
        transferringOwnership: Bool = false,
        window: NSWindow?
    ) async -> InstallFailure? {
        isInstallingHelper = true
        defer { isInstallingHelper = false }
        if let failure = await installHandler(window, transferringOwnership, {
            await self.apply(enabled: enabled, limitPercentage: limitPercentage, lowerHysteresisDelta: lowerHysteresisDelta)
        }) {
            return .install(failure)
        }
        // Installing is only half of it — the configure push is what actually engages the limit.
        // Reporting success here would leave the toggle ON over a helper that is doing nothing.
        let configuration = BatteryControlConfiguration(
            enabled: enabled,
            limitPercentage: limitPercentage,
            lowerHysteresisDelta: lowerHysteresisDelta)
        guard BatteryControlPolicy.accepted(configuration: configuration, by: status) else {
            return .configureRejected(reason: status.detailReason, detail: status.detail)
        }
        return nil
    }

    @discardableResult
    private func send(_ request: BatteryControlClientRequest) async -> BatteryControlServiceStatus? {
        let (replyData, error) = await requestHandler(request)
        guard error == nil,
              let replyData,
              let decoded = try? BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: replyData) else {
            updateUnavailable(error?.localizedDescription ?? "도우미 응답 오류")
            return nil
        }
        status = decoded
        return decoded
    }

    /// A dropped helper has to be visible: the settings screen gates its install button on
    /// `isLimitOn && mode == .unavailable`, so silently keeping the last good status would hide the
    /// only recovery action the user has.
    private func updateUnavailable(_ detail: String) {
        status = BatteryControlServiceStatus(
            mode: .unavailable,
            currentPercentage: status.currentPercentage,
            isPowerAdapterConnected: status.isPowerAdapterConnected,
            detail: detail,
            updatedAt: Date().timeIntervalSince1970,
            appliedLimitPercentage: nil,
            // Capability is a fact about this Mac, not about the connection — dropping it would
            // flicker the settings toggle back to enabled on every transient failure.
            isHardwareSupported: status.isHardwareSupported,
            capabilities: status.capabilities
        )
    }

    private nonisolated static func sendXPC(
        _ block: @escaping @Sendable (any FanControlXPCService, @escaping (Data?, NSError?) -> Void) -> Void
    ) async -> (Data?, NSError?) {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: FanControlXPC.machService, options: .privileged)
            let completion = XPCRequestCompletion(connection: connection, continuation: continuation)
            connection.remoteObjectInterface = NSXPCInterface(with: FanControlXPCService.self)
            connection.resume()
            guard let service = connection.remoteObjectProxyWithErrorHandler({ error in
                completion.finish(data: nil, error: error as NSError)
            }) as? any FanControlXPCService else {
                completion.finish(data: nil, error: NSError(domain: "Wattly", code: 1, userInfo: [NSLocalizedDescriptionKey: "도우미 연결을 만들 수 없음"]))
                return
            }
            block(service) { data, error in
                completion.finish(data: data, error: error)
            }
        }
    }
}

/// Thread-safe completion gate for the mutually exclusive XPC reply/error callbacks.
private final class XPCRequestCompletion: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let continuation: CheckedContinuation<(Data?, NSError?), Never>
    private let lock = NSLock()
    private var didFinish = false

    init(connection: NSXPCConnection,
         continuation: CheckedContinuation<(Data?, NSError?), Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(data: Data?, error: NSError?) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()

        connection.invalidate()
        continuation.resume(returning: (data, error))
    }
}
