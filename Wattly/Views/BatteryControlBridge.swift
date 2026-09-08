import SwiftUI
import AppKit

struct BatteryControlBridge: View {
    enum WakeAction: Equatable {
        case refreshStatus
        case apply
        case disableAndConfirm
    }

    enum PushAction: Equatable {
        case none
        case apply
        case disable
    }

    /// 슬라이더 드래그 한 번이 XPC 쓰기 수십 번이 되지 않게 하는 간격. 마지막 변경 후 이만큼 조용하면 한 번 민다.
    static let pushDebounceMilliseconds = 250

    let client: BatteryControlClient
    var monitor: SystemMonitor? = nil
    var scheduleCoordinator: BatteryScheduleCoordinator? = nil

    @AppStorage(StorageKey.batteryLimitEnabled) private var enabled = Defaults.batteryLimitEnabled
    @AppStorage(StorageKey.batteryLimitPercentage) private var limit = Defaults.batteryLimitPercentage
    @AppStorage(StorageKey.batterySailingEnabled) private var sailingEnabled = Defaults.batterySailingEnabled
    @AppStorage(StorageKey.batterySailingDelta) private var sailingDelta = Defaults.batterySailingDelta
    @AppStorage(StorageKey.batteryHeatProtectionEnabled) private var heatProtectionEnabled = Defaults.batteryHeatProtectionEnabled
    @AppStorage(StorageKey.batteryHeatProtectionThreshold) private var heatProtectionThreshold = Defaults.batteryHeatProtectionThreshold
    @AppStorage(StorageKey.batteryAutoDischargeEnabled) private var autoDischargeEnabled = Defaults.batteryAutoDischargeEnabled
    @AppStorage(StorageKey.batteryManualDischargeTarget) private var manualDischargeTarget = Defaults.batteryManualDischargeTarget
    @AppStorage(StorageKey.batteryClamshellDischargeEnabled) private var clamshellDischargeEnabled = Defaults.batteryClamshellDischargeEnabled
    /// 외장 디스플레이 존재 여부의 마지막 관측값. `handleInitialTask`가 첫 값을 읽고, 그 뒤로는
    /// 화면 구성 변경 알림에서만 갱신한다. 프로퍼티 초기값에서 읽지 않는 이유: `NSScreen`은
    /// `@MainActor`이고 SwiftUI View의 저장 프로퍼티 초기화는 nonisolated라 Swift 6가 거부한다.
    @State private var hasExternalDisplay = false
    @State private var pushTask: Task<Void, Never>?
    /// 지금 열려 있는 디바운스 창이 시작될 때의 선호값. 창이 닫힐 때의 결정은 이 값과 그때의
    /// 선호값 **한 쌍**에서만 나온다. `nil`이면 열린 창이 없다는 뜻이다.
    @State private var pushBaseline: BatteryPreferences?

    @State private var topUpDetector = BatteryTopUpTransitionDetector()
    @State private var topUpExpiryDetector = BatteryTopUpExpiryDetector()
    @State private var dischargeDetector = BatteryDischargeTransitionDetector()

    /// 아홉 개 `@AppStorage`를 하나의 값으로. `.onChange(of:)`와 `.task(id:)`가 이 값 하나만 본다.
    private var preferences: BatteryPreferences {
        BatteryPreferences(
            limitEnabled: enabled, limitPercentage: limit,
            sailingEnabled: sailingEnabled, sailingDelta: sailingDelta,
            heatProtectionEnabled: heatProtectionEnabled, heatProtectionThresholdCelsius: heatProtectionThreshold,
            autoDischargeEnabled: autoDischargeEnabled, manualDischargeTarget: manualDischargeTarget,
            clamshellDischargeEnabled: clamshellDischargeEnabled)
    }

    /// 브리지가 데몬에 보내는 허용값. 클라이언트의 길목이 같은 출처로 다시 계산하지만, 여기서도
    /// 넣어야 `shouldReapply`의 비교 대상이 데몬 값과 일치해 매분 재적용이 나지 않는다.
    private var clamshellDischargeAllowed: Bool {
        clamshellDischargeEnabled && hasExternalDisplay
    }

    private var configuration: BatteryControlConfiguration {
        preferences.configuration(clamshellDischargeAllowed: clamshellDischargeAllowed)
    }

    /// 어떤 변경이 어떤 쓰기가 되는지. 순수라서 테스트가 경계를 고정한다.
    /// - 설정으로 변환했을 때 같으면 아무것도 안 한다(Sailing 꺼진 채 delta만 바뀐 경우 등).
    /// - 한도나 열 보호가 켜져 있으면 `apply`.
    /// - 둘 다 꺼졌더라도 방전 쪽(자동 방전·클램쉘·수동 목표)만 바뀐 것이면 `apply` — 진행 중인 수동 방전을
    ///   `disable`로 취소하지 않기 위해서다(예전 `applyRequested` 직행 경로).
    /// - 그 외(한도를 껐다)는 `disable`.
    static func pushAction(
        from old: BatteryPreferences, to new: BatteryPreferences, hasExternalDisplay: Bool
    ) -> PushAction {
        let oldConfig = old.configuration(clamshellDischargeAllowed: old.clamshellDischargeEnabled && hasExternalDisplay)
        let newConfig = new.configuration(clamshellDischargeAllowed: new.clamshellDischargeEnabled && hasExternalDisplay)
        guard oldConfig != newConfig else { return .none }
        if new.limitEnabled || new.heatProtectionEnabled { return .apply }
        var dischargeSideOnly = old
        dischargeSideOnly.autoDischargeEnabled = new.autoDischargeEnabled
        dischargeSideOnly.clamshellDischargeEnabled = new.clamshellDischargeEnabled
        dischargeSideOnly.manualDischargeTarget = new.manualDischargeTarget
        return dischargeSideOnly == new ? .apply : .disable
    }

    /// 디바운스 창 하나가 만들어 내는 쓰기 전부.
    struct WindowPush: Equatable {
        var action: PushAction
        /// 이 창 **안에서 새로 켜진** 옵트인인지. 하드웨어에 충전 레지스터가 없다고 판명됐을 때
        /// 되돌려도 되는 것은 이것뿐이다.
        var limitOptInStarted: Bool
        var heatOptInStarted: Bool
    }

    /// 디바운스 창이 닫힐 때의 결정. 창의 **기준점**(창이 열릴 때의 값)과 창이 닫히는 시점의 값,
    /// 두 개만 본다.
    ///
    /// 창 안에서 값이 두 번 바뀌었을 때 마지막 `old→new` 쌍으로 결정하면 안 된다: 열 보호를
    /// 250 ms 안에 껐다 켜면(A→B→A) 마지막 쌍만 보고 `.disable`이 나가 돌고 있던 수동 방전이
    /// 취소된다. 실제로 바뀐 것이 없으므로 답은 `.none`이어야 하고, 기준점에서 재면 그렇게 된다.
    ///
    /// `limitOptInStarted`/`heatOptInStarted`도 같은 이유로 **전이**다. 하드웨어 미지원 되돌림은
    /// 이번에 켠 옵트인만 건드려야 한다 — 지원되는 Mac에서 이미 켜져 있던 한도를, SMC 프로브가
    /// 일시적으로 실패한 순간에 슬라이더를 만졌다는 이유로 꺼 버리면 스위치가 스스로 OFF가 되고
    /// reconcile 루프는 (저장된 선호값 쪽으로 맞추므로) 그것을 되돌리지 못한다.
    static func windowPush(
        from baseline: BatteryPreferences, to current: BatteryPreferences, hasExternalDisplay: Bool
    ) -> WindowPush {
        WindowPush(
            action: pushAction(from: baseline, to: current, hasExternalDisplay: hasExternalDisplay),
            limitOptInStarted: current.limitEnabled && !baseline.limitEnabled,
            heatOptInStarted: current.heatProtectionEnabled && !baseline.heatProtectionEnabled)
    }

    /// Folds the daemon's transient activity into a configuration built from stored preferences.
    /// `topUpActive` and `manualDischargeActive` describe what the helper is *doing*, not what the
    /// user chose, so a push driven by a preference change must carry them forward or it cancels
    /// them as a side effect. A running manual discharge also owns its target — the stored
    /// preference must not yank a discharge in progress to a different number. `nil` means the
    /// helper has not answered, and then the request stands exactly as built.
    ///
    /// Unlike `BatteryControlClient.reconcile`, this does NOT compute
    /// `effectiveEnabled = enabled || isTopUp || isManualDischarge` — a caller here forwards
    /// `requested.enabled` as-is. If a Top Up or manual discharge is running while the user's
    /// stored `enabled` preference is off, the two diverge for at most one `reconcileInterval`
    /// tick, which self-corrects through `reconcile`'s own `effectiveEnabled` the next time the
    /// loop runs. Don't re-import that coupling here without re-checking why it was left out.
    static func preservingActivity(
        _ requested: BatteryControlConfiguration,
        daemon desired: BatteryControlConfiguration?
    ) -> BatteryControlConfiguration {
        guard let desired else { return requested }
        var merged = requested
        // 데몬의 활동을 끌어올린다. `topUpActive`를 여기서 떨어뜨리면 진행 중인 充전 단계가
        // 방전 단계로 뒤집힌다. 캘리브레이션은 그 플래그를 "지금이 充전 단계인지"로 빌려 쓴다.
        merged.topUpActive = desired.topUpActive
        merged.manualDischargeActive = desired.manualDischargeActive
        if desired.manualDischargeActive {
            merged.manualDischargeTarget = desired.manualDischargeTarget
        }
        merged.calibrationActive = desired.calibrationActive
        if desired.calibrationActive {
            merged.calibrationTargetPercentage = desired.calibrationTargetPercentage
            merged.manualDischargeActive = false
            merged.enabled = true
            merged.autoDischargeEnabled = false
        }
        return merged
    }

    private func syncMonitorTarget() {
        let isTopUp = client.status.desiredConfiguration?.topUpActive == true || client.status.activity == .topUp
        monitor?.setBatteryChargeTarget(enabled: enabled, limitPercentage: limit, topUpActive: isTopUp)
    }

    /// Pure so it can be tested outside the loop, and separate from the loop so it stays that way:
    /// the reconcile loop is the only thing that repairs divergence between stored preferences and
    /// the daemon's policy, nothing restarts it, and it must never `return` on unsupported
    /// hardware — only back off. An earlier version of this loop did exit on `.unsupported`, which
    /// killed all repair for the process lifetime; keeping the streak decision here, isolated and
    /// tested, is what stops that regression from silently coming back inline. `nil` hardware
    /// support means "the helper hasn't answered", not "unsupported", so it must not count.
    static func unsupportedStreak(
        _ current: Int,
        mode: BatteryControlServiceMode,
        isHardwareSupported: Bool?
    ) -> Int {
        let isUnsupported = mode == .unsupported || isHardwareSupported == false
        return isUnsupported ? current + 1 : 0
    }

    static func wakeAction(
        configuration: BatteryControlConfiguration,
        status: BatteryControlServiceStatus
    ) -> WakeAction {
        if BatteryControlPolicy.supportsPersistentPolicy(status: status) {
            return .refreshStatus
        }
        return configuration.isActive ? .apply : .disableAndConfirm
    }

    /// Whether a detected Top Up expiry should actually be announced.
    ///
    /// 캘리브레이션은 충전 단계에서 `topUpActive`를 빌려 쓴다. 데몬이 절차 중 만료를 막지만,
    /// 절차 직전에 끝난 Top Up이 남긴 유지보수 레코드가 감지기의 300초 신선도 창 안에서
    /// 뒤늦게 뜰 수 있다. 감지기는 항상 돌려 레코드를 소비시키고, 알림만 건너뛴다.
    static func shouldAnnounceTopUpExpiry(
        didExpire: Bool,
        daemon: BatteryControlConfiguration?
    ) -> Bool {
        didExpire && daemon?.calibrationActive != true
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task {
                await handleInitialTask()
            }
            // 저장된 선호값을 데몬으로 미는 **유일한** 경로. 아홉 개의 `.onChange`가 각자 열두 개
            // 인자로 설정을 다시 조립하던 자리다 — 그 중복이 선호값 하나를 흘리는 통로였고, 슬라이더
            // 드래그 한 번을 XPC 쓰기 수십 번으로 만들었다. Settings 화면의 경쟁 쓰기도 함께
            // 없앴으므로(이 브리지가 단일 쓰기자), 토글 하나에 두 개의 순서 없는 쓰기가 얽히는 일도
            // 더는 없다.
            .onChange(of: preferences) { old, _ in
                syncMonitorTarget()
                schedulePush(windowOpenedAt: old)
            }
            // 뚜껑을 닫은 채 외장 모니터를 뽑으면 화면이 하나도 남지 않는다. 그 순간 false를
            // 내려보내야 데몬이 잠자기 차단을 풀고 Mac이 정상적으로 잠든다. 60초 reconcile을
            // 기다리지 않는다. 디바운스를 거치지 않고 `applyRequested`를 직접 부르는 이유는
            // `preservingActivity`가 진행 중 활동을 되살려 방전은 그대로 두고 잠자기 차단만
            // 바꾸기 때문이다 — `disable` 경로였다면 방전 자체가 취소된다.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                let detected = ExternalDisplayDetector.hasExternalDisplay()
                guard detected != hasExternalDisplay else { return }
                hasExternalDisplay = detected
                guard clamshellDischargeEnabled else { return }
                let requested = preferences.configuration(clamshellDischargeAllowed: detected)
                Task {
                    await applyRequested(requested, reason: "display-change")
                }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                Task {
                    await handleWake()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in
                Task {
                    if let scheduleCoordinator {
                        await scheduleCoordinator.evaluateSchedules(at: Date(), isWake: false)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                Task {
                    if let scheduleCoordinator {
                        await scheduleCoordinator.evaluateSchedules(at: Date(), isWake: false)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                Task {
                    if let scheduleCoordinator {
                        await scheduleCoordinator.evaluateSchedules(at: Date(), isWake: false)
                    }
                }
            }
            // The loop body reads the `self` captured when the task started, so every preference
            // it forwards must appear here — otherwise it reconciles stale values forever. That is
            // exactly `preferences`, and `hasExternalDisplay` is deliberately NOT folded in: the
            // loop's only write is `client.reconcile(...)`, which takes no clamshell argument, the
            // display-change handler above pushes `applyRequested` directly rather than waiting for
            // a tick, and the daemon-facing allowance is re-derived from a live `NSScreen` read by
            // the client's own `clamshellAllowance()` on every write.
            .task(id: preferences) {
                await handleReconcileLoop()
            }
            .onChange(of: client.status) { _, newStatus in
                syncMonitorTarget()
                if topUpDetector.update(reasonKind: newStatus.detailReason?.kind) {
                    BatteryNotificationManager.postTopUpCompleteNotification()
                }
                // 헬퍼가 스스로 Top Up을 끝낸 경우에만 참이 된다. 사용자가 버튼으로 취소한
                // 경우와 만료 후 상태가 동일하기 때문에 유지보수 레코드로 구분한다.
                let didExpire = topUpExpiryDetector.update(
                    record: newStatus.lastMaintenance,
                    now: Date().timeIntervalSince1970)
                if Self.shouldAnnounceTopUpExpiry(
                    didExpire: didExpire,
                    daemon: newStatus.desiredConfiguration) {
                    BatteryNotificationManager.postTopUpExpiredNotification()
                }
                // 수동 방전이 목표에 도달한 순간에만 값이 나온다. 자동 방전과 사용자 중지는
                // 디텍터가 걸러낸다. 이 배선이 없어서 "방전 완료" 알림은 만들어져 있는데
                // 한 번도 뜨지 않았다.
                if let target = dischargeDetector.update(status: newStatus) {
                    BatteryNotificationManager.notifyDischargeCompleted(target: target)
                }
            }
    }

    /// 디바운스된 단일 쓰기 경로. 마지막 변경 시점의 `configuration`을 다시 읽어 보내므로 드래그 도중 값은 버려진다.
    ///
    /// 결정(`windowPush`)과 실을 값(`configuration`)을 **둘 다** 잠에서 깬 뒤에 읽는다. 결정만
    /// 변경 시점에 굳혀 두면 창 안에서 값이 또 바뀌었을 때 서로 다른 두 상태에서 뽑은 결정과
    /// 페이로드가 짝지어진다.
    ///
    /// 이 경로는 `client.reconcile`을 **일부러** 쓰지 않는다: 그쪽은 `BatteryControlPolicy.shouldReapply`가
    /// 동의할 때만 쓰는데, "데몬이 이미 같다"고 판단하는 수리용 술어는 배경 패스에는 맞고 사용자가
    /// 누른 버튼에는 틀리다 — 누름이 아무 표시도 없이 사라진다. 쓰기 경로가 하나로 합쳐진 지금
    /// "중복 쓰기를 줄이자"며 여기를 `reconcile`로 돌리고 싶어지겠지만, 그게 바로 이 문단이 막는 변경이다.
    private func schedulePush(windowOpenedAt old: BatteryPreferences) {
        // 살아 있는 창이 없을 때만 기준점을 새로 잡는다. 250 ms 안에 두 번째 변경이 오면 그 창의
        // 기준점은 여전히 첫 번째 `old`다 — 그래야 A→B→A가 `.none`으로 상쇄된다.
        if pushTask == nil { pushBaseline = old }
        let baseline = pushBaseline ?? old
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(for: .milliseconds(Self.pushDebounceMilliseconds))
            guard !Task.isCancelled else { return }
            // 창은 여기서 닫힌다. 이 뒤에 오는 변경은 새 기준점으로 새 창을 연다.
            pushTask = nil
            pushBaseline = nil
            let decision = Self.windowPush(
                from: baseline, to: preferences, hasExternalDisplay: hasExternalDisplay)
            let requested = configuration
            switch decision.action {
            case .apply:
                await applyRequested(requested, reason: "preference-change")
                // 이 Mac에 충전 레지스터가 없다고 도우미가 답했으면 이번에 켠 옵트인을 되돌린다 —
                // 아니면 스위치가 ON인 채로 스스로 비활성화돼 되돌릴 길이 없다(예전 SettingsBatterySection의 규칙).
                // 되돌리는 것은 이 창에서 켠 값뿐이다: 지원되는 Mac에서 넘어온 `true`는 건드리지 않는다.
                if client.status.isHardwareSupported == false {
                    if decision.limitOptInStarted { enabled = false }
                    if decision.heatOptInStarted { heatProtectionEnabled = false }
                }
            case .disable:
                await disableRequested(requested, reason: "preference-change")
            case .none:
                break
            }
        }
    }

    private func handleInitialTask() async {
        hasExternalDisplay = ExternalDisplayDetector.hasExternalDisplay()
        syncMonitorTarget()
        await client.refreshStatus()
        syncMonitorTarget()
        let requested = configuration
        let shouldReapply = BatteryControlPolicy.shouldReapply(
            configuration: requested, status: client.status)
        BatteryControlLog.battery.notice(
            "initial task verdict: shouldReapply=\(shouldReapply) requestedAutoDischarge=\(requested.autoDischargeEnabled)")
        guard shouldReapply else { return }
        await push(requested, reason: "initial")
    }

    private func handleWake() async {
        let requested = configuration
        switch Self.wakeAction(configuration: requested, status: client.status) {
        case .refreshStatus:
            await client.refreshStatus()
        case .apply:
            await applyRequested(requested, reason: "wake")
        case .disableAndConfirm:
            await disableRequested(requested, reason: "wake")
        }
        if let scheduleCoordinator {
            await scheduleCoordinator.evaluateSchedules(at: Date(), isWake: true)
        }
    }

    private func handleReconcileLoop() async {
        var consecutiveUnsupported = 0
        BatteryControlLog.battery.notice("reconcile loop started")
        while !Task.isCancelled {
            try? await Task.sleep(
                for: .seconds(BatteryControlPolicy.reconcileInterval(
                    consecutiveUnsupported: consecutiveUnsupported))
            )
            guard !Task.isCancelled else {
                BatteryControlLog.battery.notice("reconcile loop cancelled")
                return
            }
            let requested = configuration
            BatteryControlLog.battery.notice(
                """
                reconcile tick: enabled=\(requested.enabled) limit=\(requested.limitPercentage) \
                autoDischarge=\(requested.autoDischargeEnabled) \
                manualTarget=\(requested.manualDischargeTarget) \
                mode=\(String(describing: client.status.mode), privacy: .public) \
                unsupportedStreak=\(consecutiveUnsupported)
                """)
            await client.reconcile(
                enabled: requested.enabled,
                limitPercentage: requested.limitPercentage,
                lowerHysteresisDelta: requested.lowerHysteresisDelta,
                heatProtectionEnabled: requested.heatProtectionEnabled,
                heatProtectionThresholdCelsius: requested.heatProtectionThresholdCelsius,
                autoDischargeEnabled: requested.autoDischargeEnabled,
                manualDischargeTarget: requested.manualDischargeTarget)
            // `isHardwareSupported == false` also feeds the backoff counter below: a daemon that
            // relaunches with a transiently failing SMC probe must not kill this loop for the
            // process lifetime — that leaves a divergence (e.g. the user's auto-discharge opt-in)
            // unrepaired forever, even after the daemon comes back healthy. Back off instead of
            // exiting, same as the `.unsupported` mode case. See `unsupportedStreak` for why this
            // decision lives in a pure, tested function rather than inline here.
            consecutiveUnsupported = Self.unsupportedStreak(
                consecutiveUnsupported,
                mode: client.status.mode,
                isHardwareSupported: client.status.isHardwareSupported)
            if client.status.isHardwareSupported == false {
                BatteryControlLog.battery.notice(
                    "reconcile loop backing off: hardware unsupported, streak=\(consecutiveUnsupported)")
            }
        }
        BatteryControlLog.battery.notice("reconcile loop ended: task cancelled")
    }

    /// The one place a bridge-built configuration turns into a daemon write. An inactive policy
    /// still carries the discharge preferences: the helper persists them, so the user's target
    /// survives the limit being switched off and back on. `reason` identifies the caller in the
    /// OSLog trail and is simply forwarded — see `applyRequested`.
    private func push(_ requested: BatteryControlConfiguration, reason: StaticString) async {
        if requested.enabled || requested.heatProtectionEnabled {
            await applyRequested(requested, reason: reason)
        } else {
            await disableRequested(requested, reason: reason)
        }
    }

    /// Reads the daemon's current status and folds its transient activity into `requested` before
    /// writing, via `preservingActivity` — without this, any push through here (a limit edit, a
    /// wake-triggered apply, the auto-discharge toggle) would default `topUpActive` and
    /// `manualDischargeActive` to `false` and silently cancel a Top Up or manual discharge in
    /// progress. Forwards every `BatteryControlConfiguration` field `client.apply` accepts as a
    /// parameter so nothing the merge produced is dropped on the way there — except
    /// `clamshellDischargeAllowed`, which is deliberately NOT one of `apply`'s parameters and so
    /// is never threaded through here. That field is owned and recomputed by the client's own
    /// chokepoint (`BatteryControlClient.revivedConfiguration`, via `clamshellAllowance()`), which
    /// reads `NSScreen` live and is therefore fresher than this bridge's `@State` mirror of
    /// `merged`. Do not "fix" this by adding a `clamshellDischargeAllowed` parameter here — that
    /// reintroduces the twelve-call-site default-`false` hazard the chokepoint exists to prevent.
    /// The client's own chokepoint independently re-derives `calibrationActive` and
    /// `calibrationTargetPercentage` from daemon status too, so this forwarding is belt-and-braces
    /// protection rather than the sole safeguard.
    ///
    /// `reason` names the call site in the log line so a field log can identify which of the
    /// several paths that share this function — a toggle, a limit edit, a wake — actually wrote to
    /// the daemon. `StaticString` because it is always a source-literal label, never user data, so
    /// it needs no `privacy:` annotation and cannot leak anything even if one is omitted.
    private func applyRequested(_ requested: BatteryControlConfiguration, reason: StaticString) async {
        await client.refreshStatus()
        let merged = Self.preservingActivity(
            requested, daemon: client.status.desiredConfiguration)
        BatteryControlLog.battery.notice(
            "applyRequested push: reason=\(reason, privacy: .public) autoDischarge=\(merged.autoDischargeEnabled) topUp=\(merged.topUpActive) manualActive=\(merged.manualDischargeActive)")
        let result = await client.apply(
            enabled: merged.enabled,
            limitPercentage: merged.limitPercentage,
            lowerHysteresisDelta: merged.lowerHysteresisDelta,
            heatProtectionEnabled: merged.heatProtectionEnabled,
            heatProtectionThresholdCelsius: merged.heatProtectionThresholdCelsius,
            topUpActive: merged.topUpActive,
            autoDischargeEnabled: merged.autoDischargeEnabled,
            manualDischargeActive: merged.manualDischargeActive,
            manualDischargeTarget: merged.manualDischargeTarget,
            calibrationActive: merged.calibrationActive,
            calibrationTargetPercentage: merged.calibrationTargetPercentage)
        BatteryControlLog.battery.notice(
            "applyRequested result: reason=\(reason, privacy: .public) accepted=\(result != nil)")
    }

    /// Same caller-identity treatment as `applyRequested`: this is reached from more than one
    /// place (`push`, and directly from `handleWake`'s `.disableAndConfirm` case), so the disable
    /// path needs to be just as identifiable in the log trail.
    private func disableRequested(_ requested: BatteryControlConfiguration, reason: StaticString) async {
        BatteryControlLog.battery.notice(
            "disableRequested push: reason=\(reason, privacy: .public) limit=\(requested.limitPercentage) autoDischarge=\(requested.autoDischargeEnabled)")
        let result = await client.disableAndConfirm(
            limitPercentage: requested.limitPercentage,
            lowerHysteresisDelta: requested.lowerHysteresisDelta,
            autoDischargeEnabled: requested.autoDischargeEnabled,
            manualDischargeTarget: requested.manualDischargeTarget)
        BatteryControlLog.battery.notice(
            "disableRequested result: reason=\(reason, privacy: .public) accepted=\(result != nil)")
    }
}
