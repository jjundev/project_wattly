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

    /// 데몬에 설정을 내려보내는 유일한 길목.
    ///
    /// `isCalibrationWrite`가 아닌 모든 호출은 데몬이 들고 있는 캘리브레이션을 **되살려서**
    /// 나간다. 활동을 보존하지 않는 호출부가 12곳(스케줄 2·Shortcuts 3·설정 8)이고, 그중
    /// 하나라도 절차 중에 발화하면 기본값 `false`가 실려 나가 10시간짜리 절차를 조용히
    /// 취소하기 때문이다. 12곳을 각각 고치는 대신 여기 한 곳에서 닫는다.
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
        manualDischargeTarget: Int = 80,
        calibrationActive: Bool = false,
        calibrationTargetPercentage: Int = BatteryCalibration.floorPercentage,
        isCalibrationWrite: Bool = false
    ) async -> BatteryControlServiceStatus? {
        commandGeneration &+= 1
        var config = BatteryControlConfiguration(
            enabled: enabled,
            limitPercentage: limitPercentage,
            lowerHysteresisDelta: lowerHysteresisDelta,
            heatProtectionEnabled: heatProtectionEnabled,
            heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
            topUpActive: topUpActive,
            autoDischargeEnabled: autoDischargeEnabled,
            manualDischargeActive: manualDischargeActive,
            manualDischargeTarget: manualDischargeTarget,
            calibrationActive: calibrationActive,
            calibrationTargetPercentage: calibrationTargetPercentage
        )
        // 캐시가 비어 있는 건 "확인 안 됨"이지 "캘리브레이션 없음"이 아니다. Shortcuts/App
        // Intents(BatteryIntentBridge)는 호출마다 새 BatteryControlClient를 만들어 쓰기 전에
        // status를 읽지 않으므로 desiredConfiguration이 항상 nil이다 — 여기서 한 번 읽지
        // 않으면 절차 중 아무 Shortcut 호출에도 되살리기가 조용히 빠진다. 이 읽기 자체가
        // 실패해도(도우미가 죽어 있음) 아래 쓰기는 그대로 나간다 — 상태를 못 읽는 도우미는
        // 쓰기도 못 받을 테니 여기서 멈출 이유가 없다.
        if !isCalibrationWrite, status.desiredConfiguration == nil {
            await refreshStatus()
        }
        if !isCalibrationWrite,
           let daemon = status.desiredConfiguration, daemon.calibrationActive {
            config.calibrationActive = true
            config.calibrationTargetPercentage = daemon.calibrationTargetPercentage
            // 어느 단계인지도 데몬이 안다. 충전 단계를 방전 단계로 바꿔 버리면 안 된다.
            config.topUpActive = daemon.topUpActive
            config.enabled = true
            config.manualDischargeActive = false
        }
        let request = BatteryControlConfigurationRequest(configuration: config, generation: commandGeneration)
        guard let data = try? BatteryControlCodec.encode(request) else {
            updateUnavailable("충전 제한 설정을 인코딩할 수 없음")
            return nil
        }
        return await send(.configure(data))
    }

    /// 캘리브레이션 코디네이터 전용 쓰기. 절차 중 자동 방전을 강제로 끄는 것이 여기다 —
    /// 두 정책이 같은 CHIE를 다투면 방전이 즉시 되돌려진다. 원값은 스냅샷이 들고 있다가
    /// 원복 때 되살린다.
    @discardableResult
    public func applyCalibration(
        primitive: CalibrationPrimitive,
        snapshot: CalibrationSnapshot
    ) async -> BatteryControlServiceStatus? {
        let isRunning = primitive != .restore && primitive != .idle
        let isChargingStep = primitive == .chargeToFull || primitive == .holdAtFull
        return await apply(
            enabled: isRunning ? true : snapshot.limitEnabled,
            limitPercentage: snapshot.limitPercentage,
            lowerHysteresisDelta: snapshot.sailingEnabled ? snapshot.sailingDelta : 2,
            heatProtectionEnabled: snapshot.heatProtectionEnabled,
            heatProtectionThresholdCelsius: snapshot.heatProtectionThresholdCelsius,
            topUpActive: isRunning && isChargingStep,
            autoDischargeEnabled: isRunning ? false : snapshot.autoDischargeEnabled,
            manualDischargeActive: false,
            manualDischargeTarget: snapshot.manualDischargeTarget,
            calibrationActive: isRunning,
            calibrationTargetPercentage: BatteryCalibration.floorPercentage,
            isCalibrationWrite: true)
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
        let isCalibrating = status.desiredConfiguration?.calibrationActive == true
        let calibrationTarget = status.desiredConfiguration?.calibrationTargetPercentage
            ?? BatteryCalibration.floorPercentage
        // 절차 중에는 자동 방전을 세워 둔다. 엔진 우선순위상 이미 무력하지만, 저장된 선호값이
        // 매 분 되살아나면 로그와 status가 "자동 방전 켜짐"으로 보여 진단을 흐린다.
        let effectiveAutoDischarge = isCalibrating ? false : autoDischargeEnabled
        // The caller's task may have been cancelled while that read was in flight, and a reconcile
        // is a WRITE — unlike the fan heartbeat this loop is modelled on. Without this check a
        // straggler iteration would re-enable a limit the user just switched off, carrying a higher
        // generation than the disable that raced it, and nothing would ever repair it.
        let effectiveEnabled = enabled || isTopUp || isManualDischarge || isCalibrating
        let targetConfig = BatteryControlConfiguration(
            enabled: effectiveEnabled,
            limitPercentage: limitPercentage,
            lowerHysteresisDelta: lowerHysteresisDelta,
            heatProtectionEnabled: heatProtectionEnabled,
            heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
            topUpActive: isTopUp,
            autoDischargeEnabled: effectiveAutoDischarge,
            manualDischargeActive: isManualDischarge,
            manualDischargeTarget: dischargeTarget,
            calibrationActive: isCalibrating,
            calibrationTargetPercentage: calibrationTarget
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
        if enabled || heatProtectionEnabled || isTopUp || isManualDischarge || isCalibrating {
            await apply(
                enabled: effectiveEnabled,
                limitPercentage: limitPercentage,
                lowerHysteresisDelta: lowerHysteresisDelta,
                heatProtectionEnabled: heatProtectionEnabled,
                heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
                topUpActive: isTopUp,
                autoDischargeEnabled: effectiveAutoDischarge,
                manualDischargeActive: isManualDischarge,
                manualDischargeTarget: dischargeTarget,
                calibrationActive: isCalibrating,
                calibrationTargetPercentage: calibrationTarget,
                isCalibrationWrite: true)
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
            // Hardware capability is a fact about this Mac, not about the connection — dropping
            // these fields would flicker the settings toggles back to enabled on every transient failure.
            isHardwareSupported: status.isHardwareSupported,
            isDischargeHardwareSupported: status.isDischargeHardwareSupported,
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
