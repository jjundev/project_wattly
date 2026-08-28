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
        lowerHysteresisDelta: Int = 2,
        heatProtectionEnabled: Bool = false,
        heatProtectionThresholdCelsius: Int = 35,
        topUpActive: Bool = false,
        autoDischargeEnabled: Bool = false,
        manualDischargeActive: Bool = false,
        manualDischargeTarget: Int = 80
    ) async -> BatteryControlServiceStatus? {
        commandGeneration &+= 1
        let config = BatteryControlConfiguration(
            enabled: enabled,
            limitPercentage: limitPercentage,
            lowerHysteresisDelta: lowerHysteresisDelta,
            heatProtectionEnabled: heatProtectionEnabled,
            heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
            topUpActive: topUpActive,
            autoDischargeEnabled: autoDischargeEnabled,
            manualDischargeActive: manualDischargeActive,
            manualDischargeTarget: manualDischargeTarget
        )
        let request = BatteryControlConfigurationRequest(configuration: config, generation: commandGeneration)
        guard let data = try? BatteryControlCodec.encode(request) else {
            updateUnavailable("충전 제한 설정을 인코딩할 수 없음")
            return nil
        }
        return await send(.configure(data))
    }

    @discardableResult
    public func startTopUp(
        limitPercentage: Int,
        lowerHysteresisDelta: Int = 2,
        heatProtectionEnabled: Bool = false,
        heatProtectionThresholdCelsius: Int = 35,
        autoDischargeEnabled: Bool = false,
        manualDischargeTarget: Int = 80
    ) async -> BatteryControlServiceStatus? {
        BatteryNotificationManager.requestAuthorization()
        return await apply(
            enabled: true,
            limitPercentage: limitPercentage,
            lowerHysteresisDelta: lowerHysteresisDelta,
            heatProtectionEnabled: heatProtectionEnabled,
            heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
            topUpActive: true,
            autoDischargeEnabled: autoDischargeEnabled,
            manualDischargeActive: false,
            manualDischargeTarget: manualDischargeTarget
        )
    }

    @discardableResult
    public func cancelTopUp(
        limitPercentage: Int,
        lowerHysteresisDelta: Int = 2,
        heatProtectionEnabled: Bool = false,
        heatProtectionThresholdCelsius: Int = 35,
        autoDischargeEnabled: Bool = false,
        manualDischargeTarget: Int = 80
    ) async -> BatteryControlServiceStatus? {
        await apply(
            enabled: true,
            limitPercentage: limitPercentage,
            lowerHysteresisDelta: lowerHysteresisDelta,
            heatProtectionEnabled: heatProtectionEnabled,
            heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
            topUpActive: false,
            autoDischargeEnabled: autoDischargeEnabled,
            manualDischargeActive: false,
            manualDischargeTarget: manualDischargeTarget
        )
    }

    @discardableResult
    public func startManualDischarge(
        target: Int,
        limitPercentage: Int = 80,
        lowerHysteresisDelta: Int = 2,
        heatProtectionEnabled: Bool = false,
        heatProtectionThresholdCelsius: Int = 35,
        autoDischargeEnabled: Bool = false
    ) async -> BatteryControlServiceStatus? {
        BatteryNotificationManager.requestAuthorization()
        return await apply(
            enabled: true,
            limitPercentage: limitPercentage,
            lowerHysteresisDelta: lowerHysteresisDelta,
            heatProtectionEnabled: heatProtectionEnabled,
            heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
            topUpActive: false,
            autoDischargeEnabled: autoDischargeEnabled,
            manualDischargeActive: true,
            manualDischargeTarget: target
        )
    }

    @discardableResult
    public func stopManualDischarge(
        limitPercentage: Int = 80,
        lowerHysteresisDelta: Int = 2,
        heatProtectionEnabled: Bool = false,
        heatProtectionThresholdCelsius: Int = 35,
        autoDischargeEnabled: Bool = false,
        manualDischargeTarget: Int = 80
    ) async -> BatteryControlServiceStatus? {
        await apply(
            enabled: true,
            limitPercentage: limitPercentage,
            lowerHysteresisDelta: lowerHysteresisDelta,
            heatProtectionEnabled: heatProtectionEnabled,
            heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
            topUpActive: false,
            autoDischargeEnabled: autoDischargeEnabled,
            manualDischargeActive: false,
            manualDischargeTarget: manualDischargeTarget
        )
    }

    @discardableResult
    public func setAutoDischarge(
        enabled: Bool,
        limitPercentage: Int = 80,
        lowerHysteresisDelta: Int = 2,
        heatProtectionEnabled: Bool = false,
        heatProtectionThresholdCelsius: Int = 35,
        limitEnabled: Bool = true,
        manualDischargeTarget: Int = 80
    ) async -> BatteryControlServiceStatus? {
        await apply(
            enabled: limitEnabled,
            limitPercentage: limitPercentage,
            lowerHysteresisDelta: lowerHysteresisDelta,
            heatProtectionEnabled: heatProtectionEnabled,
            heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
            topUpActive: false,
            autoDischargeEnabled: enabled,
            manualDischargeActive: false,
            manualDischargeTarget: manualDischargeTarget
        )
    }

    public func disableAndConfirm(
        limitPercentage: Int = 100,
        lowerHysteresisDelta: Int = 2,
        autoDischargeEnabled: Bool = false,
        manualDischargeTarget: Int = 80
    ) async -> DisableFailure? {
        guard let acknowledged = await apply(
            enabled: false,
            limitPercentage: limitPercentage,
            lowerHysteresisDelta: lowerHysteresisDelta,
            heatProtectionEnabled: false,
            heatProtectionThresholdCelsius: 35,
            topUpActive: false,
            autoDischargeEnabled: autoDischargeEnabled,
            manualDischargeActive: false,
            manualDischargeTarget: manualDischargeTarget) else {
            return .helperUnavailable
        }
        guard acknowledged.desiredConfiguration?.enabled == false else {
            return .persistenceRejected
        }
        let safe = acknowledged.actualGate?.state == .allowed
            || acknowledged.releaseVerification?.isSafeToRemove == true
        return safe ? nil : .releaseUnverified
    }

    /// Full uninstall is the one explicit flow allowed to replace a legacy or missing helper.
    /// A healthy persistent helper is left in place until its confirmed release succeeds; a
    /// foreign helper remains blocked by the non-transfer install path.
    public func prepareForRemoval(window: NSWindow?) async -> DisableFailure? {
        await refreshStatus()
        if !BatteryControlPolicy.supportsPersistentPolicy(status: status) {
            if await installAndApply(
                enabled: false,
                limitPercentage: 100,
                lowerHysteresisDelta: 2,
                heatProtectionEnabled: false,
                heatProtectionThresholdCelsius: 35,
                autoDischargeEnabled: false,
                manualDischargeActive: false,
                manualDischargeTarget: 80,
                transferringOwnership: false,
                window: window) != nil {
                return .helperUnavailable
            }
        }
        return await disableAndConfirm()
    }

    @discardableResult
    public func refreshStatus() async -> BatteryControlServiceStatus? {
        await send(.status)
    }

    /// Repairs a helper that restarted and lost its configuration. Reads the helper's state first,
    /// so a healthy helper costs one status call and no SMC traffic at all.
    public func reconcile(
        enabled: Bool,
        limitPercentage: Int,
        lowerHysteresisDelta: Int = 2,
        heatProtectionEnabled: Bool = false,
        heatProtectionThresholdCelsius: Int = 35,
        autoDischargeEnabled: Bool = false,
        manualDischargeActive: Bool = false,
        manualDischargeTarget: Int = 80
    ) async {
        await refreshStatus()
        let isTopUp = status.desiredConfiguration?.topUpActive == true
        let isManualDischarge = manualDischargeActive || (status.desiredConfiguration?.manualDischargeActive == true)
        let dischargeTarget = isManualDischarge ? (status.desiredConfiguration?.manualDischargeTarget ?? manualDischargeTarget) : manualDischargeTarget
        // The caller's task may have been cancelled while that read was in flight, and a reconcile
        // is a WRITE — unlike the fan heartbeat this loop is modelled on. Without this check a
        // straggler iteration would re-enable a limit the user just switched off, carrying a higher
        // generation than the disable that raced it, and nothing would ever repair it.
        let effectiveEnabled = enabled || isTopUp || isManualDischarge
        let targetConfig = BatteryControlConfiguration(
            enabled: effectiveEnabled,
            limitPercentage: limitPercentage,
            lowerHysteresisDelta: lowerHysteresisDelta,
            heatProtectionEnabled: heatProtectionEnabled,
            heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
            topUpActive: isTopUp,
            autoDischargeEnabled: autoDischargeEnabled,
            manualDischargeActive: isManualDischarge,
            manualDischargeTarget: dischargeTarget
        )
        let willReapply = BatteryControlPolicy.shouldReapply(
            configuration: targetConfig, status: status)
        BatteryControlLog.battery.notice(
            """
            reconcile verdict: willReapply=\(willReapply) cancelled=\(Task.isCancelled) \
            mode=\(String(describing: self.status.mode), privacy: .public) \
            hardwareSupported=\(String(describing: self.status.isHardwareSupported), privacy: .public) \
            capabilities=\(self.status.capabilities?.map(\.rawValue).joined(separator: ",") ?? "nil", privacy: .public) \
            requestedAutoDischarge=\(targetConfig.autoDischargeEnabled) \
            desiredAutoDischarge=\(String(describing: self.status.desiredConfiguration?.autoDischargeEnabled), privacy: .public)
            """)
        guard !Task.isCancelled, willReapply else { return }
        if enabled || heatProtectionEnabled || isTopUp || isManualDischarge {
            await apply(
                enabled: effectiveEnabled,
                limitPercentage: limitPercentage,
                lowerHysteresisDelta: lowerHysteresisDelta,
                heatProtectionEnabled: heatProtectionEnabled,
                heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
                topUpActive: isTopUp,
                autoDischargeEnabled: autoDischargeEnabled,
                manualDischargeActive: isManualDischarge,
                manualDischargeTarget: dischargeTarget)
        } else {
            _ = await disableAndConfirm(
                limitPercentage: limitPercentage,
                lowerHysteresisDelta: lowerHysteresisDelta,
                autoDischargeEnabled: autoDischargeEnabled,
                manualDischargeTarget: dischargeTarget)
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
        heatProtectionEnabled: Bool = false,
        heatProtectionThresholdCelsius: Int = 35,
        autoDischargeEnabled: Bool = true,
        manualDischargeActive: Bool = false,
        manualDischargeTarget: Int = 80,
        transferringOwnership: Bool = false,
        window: NSWindow?
    ) async -> InstallFailure? {
        isInstallingHelper = true
        defer { isInstallingHelper = false }
        if let failure = await installHandler(window, transferringOwnership, {
            await self.apply(
                enabled: enabled,
                limitPercentage: limitPercentage,
                lowerHysteresisDelta: lowerHysteresisDelta,
                heatProtectionEnabled: heatProtectionEnabled,
                heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
                topUpActive: false,
                autoDischargeEnabled: autoDischargeEnabled,
                manualDischargeActive: manualDischargeActive,
                manualDischargeTarget: manualDischargeTarget)
        }) {
            return .install(failure)
        }
        // Installing is only half of it — the configure push is what actually engages the limit.
        // Reporting success here would leave the toggle ON over a helper that is doing nothing.
        let configuration = BatteryControlConfiguration(
            enabled: enabled,
            limitPercentage: limitPercentage,
            lowerHysteresisDelta: lowerHysteresisDelta,
            heatProtectionEnabled: heatProtectionEnabled,
            heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
            topUpActive: false,
            autoDischargeEnabled: autoDischargeEnabled,
            manualDischargeActive: manualDischargeActive,
            manualDischargeTarget: manualDischargeTarget)
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
