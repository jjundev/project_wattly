import Foundation

/// 설정 › 배터리 충전 제어 섹션의 순수 표시 판단. SwiftUI도 I/O도 없다 —
/// `CardPresentation` / `Accessibility` / `BatteryControlPolicy`와 같은 방식으로,
/// 뷰가 내리던 결정을 테이블 테스트가 가능한 함수로 옮겨둔 것이다.
///
/// 배경: 예전에는 하위 항목 전체가 `batteryLimitEnabled` 뒤에 숨어 있어서, 토글을 켜기 전에는
/// 이 기능이 무엇을 하는지 볼 수 없었다. 이제 하위 항목은 항상 보이고, **조작할 수 없는 부분만**
/// 비활성으로 표시한다.
enum BatterySectionPresentation {

    enum Tone: String, Equatable {
        case green, orange, red, faint
    }

    enum MaintenanceAction: Equatable {
        case retry
        case updateHelper
        case transferOwnership
    }

    struct MaintenanceStatus: Equatable {
        let tone: Tone
        let text: String
        let action: MaintenanceAction?
    }

    enum Indicator: String, Equatable, CaseIterable {
        case installing
        case stale
        case inactive
        case chargingToLimit
        case holdingAtLimit
        case onBatteryPower
        case sailing
        case heatProtection
        case topUp
        case discharging
        case calibration
        case unavailable
        case hardwareUnsupported
        case failure

        var symbolName: String {
            switch self {
            case .installing: return "arrow.down.circle.fill"
            case .stale: return "clock.fill"
            case .inactive, .holdingAtLimit: return "pause.circle.fill"
            case .chargingToLimit: return "bolt.circle.fill"
            case .onBatteryPower: return "battery.100"
            case .sailing: return "arrow.left.and.right.circle.fill"
            case .heatProtection: return "thermometer"
            case .topUp: return "arrow.up.circle.fill"
            case .discharging: return "arrow.down.circle.fill"
            case .calibration: return "arrow.triangle.2.circlepath"
            case .hardwareUnsupported: return "nosign"
            case .unavailable, .failure: return "exclamationmark.triangle.fill"
            }
        }

        var tone: Tone {
            switch self {
            case .inactive, .stale: return .faint
            case .chargingToLimit, .onBatteryPower, .topUp: return .green
            case .installing, .holdingAtLimit, .sailing, .heatProtection,
                 .discharging, .calibration, .failure:
                return .orange
            case .unavailable, .hardwareUnsupported: return .red
            }
        }
    }

    struct Status: Equatable {
        let indicator: Indicator
        let text: String
    }

    static let staleAfter = 15.0

    static func maintenanceStatus(
        ownership: FanHelperInstaller.InstalledOwnership,
        currentUID: UInt32,
        capabilities: [BatteryControlCapability]?,
        record: BatteryMaintenanceRecord?,
        locale: Locale,
        timestampText: ((Date) -> String)? = nil
    ) -> MaintenanceStatus? {
        switch ownership {
        case .owner(let ownerUID) where ownerUID != currentUID:
            return MaintenanceStatus(
                tone: .red,
                text: String(localized: "유지보수: 다른 사용자가 이 Mac의 충전 정책을 관리하고 있습니다", locale: locale),
                action: .transferOwnership)
        case .invalidMetadata:
            return MaintenanceStatus(
                tone: .red,
                text: String(localized: "유지보수: 설치된 도우미의 소유자 정보를 확인할 수 없습니다.", locale: locale),
                action: .transferOwnership)
        case .notInstalled, .owner:
            break
        }
        let requiredCapabilities: [BatteryControlCapability] = [
            .persistedPolicyV1,
            .hardwareGateReadbackV1,
            .systemPowerEventsV1,
        ]
        guard requiredCapabilities.allSatisfy({ capabilities?.contains($0) == true }) else {
            return MaintenanceStatus(
                tone: .orange,
                text: String(localized: "유지보수: 앱 종료·Sleep 유지를 사용하려면 도우미 업데이트가 필요합니다.", locale: locale),
                action: .updateHelper)
        }
        if let record,
           record.result == .failed || record.result == .skipped || record.result == .unrecognized {
            return MaintenanceStatus(
                tone: .red,
                text: maintenanceFailureText(reason: record.reason, locale: locale),
                action: .retry)
        }
        guard let record else {
            return MaintenanceStatus(
                tone: .faint,
                text: String(localized: "유지보수: 충전 정책 확인 전", locale: locale),
                action: nil)
        }
        let trigger = maintenanceTriggerText(record.trigger, locale: locale)
        let resolvedTimestampText = timestampText ?? { defaultMaintenanceTimestamp($0, locale: locale) }
        let timestamp = resolvedTimestampText(Date(timeIntervalSince1970: record.occurredAt))
        return MaintenanceStatus(
            tone: .faint,
            text: String(format: String(localized: "유지보수: 마지막 확인: %@ · 성공 · %@", locale: locale),
                         locale: locale, trigger, timestamp),
            action: nil)
    }

    static func maintenancePopoverText(_ maintenance: MaintenanceStatus?, locale: Locale) -> String {
        maintenance?.text ?? String(localized: "유지보수: 충전 정책 확인 전", locale: locale)
    }

    private static func maintenanceFailureText(reason: BatteryControlStatusReason?, locale: Locale) -> String {
        switch reason?.kind {
        case .persistenceReadFailed:
            String(localized: "유지보수: 저장된 충전 정책을 읽지 못해 충전 허용 상태로 복구합니다", locale: locale)
        case .persistenceWriteFailed:
            String(localized: "유지보수: 충전 정책을 안전하게 저장하지 못했습니다", locale: locale)
        case .policyOwnerMismatch:
            String(localized: "유지보수: 다른 사용자가 이 Mac의 충전 정책을 관리하고 있습니다", locale: locale)
        case .hardwareReadbackFailed:
            String(localized: "유지보수: 충전 제어 하드웨어 상태를 확인하지 못했습니다", locale: locale)
        case .none, .some:
            BatteryStatusText.text(reason: reason,
                                   detail: String(localized: "유지보수: 알 수 없음", locale: locale),
                                   locale: locale)
        }
    }

    private static func maintenanceTriggerText(_ trigger: BatteryMaintenanceTrigger,
                                               locale: Locale) -> String {
        switch trigger {
        case .startup: String(localized: "유지보수: 앱 시작", locale: locale)
        case .wake: String(localized: "유지보수: 절전 해제", locale: locale)
        case .clientConfiguration: String(localized: "유지보수: 설정 변경", locale: locale)
        case .adapterTransition: String(localized: "유지보수: 전원 전환", locale: locale)
        case .termination: String(localized: "유지보수: 앱 종료", locale: locale)
        case .topUpExpired: String(localized: "유지보수: 완충 자동 해제", locale: locale)
        case .unrecognized: String(localized: "유지보수: 알 수 없음", locale: locale)
        }
    }

    /// 설정 화면의 "한 번만 완충" 설명. 종료 조건이 두 개(어댑터 분리 / 시간 만료)가 되었으므로
    /// 둘 다 문장에 나온다. 시간 수를 인자로 받는 이유는 `BatteryTopUpExpiry.duration`이 바뀌어도
    /// 문구가 따로 놀지 않게 하기 위해서다.
    static func topUpDescription(hours: Int, locale: Locale) -> String {
        String(format: String(localized: "다음 외출이나 출장을 위해 배터리를 일회성으로 100%%까지 완전 충전합니다. 어댑터를 분리하거나 완충 후 %lld시간이 지나면 기존 충전 제한으로 자동 복귀합니다.", locale: locale),
               locale: locale, Int64(hours))
    }

    static func maintenanceActionLabel(_ action: MaintenanceAction, locale: Locale) -> String {
        switch action {
        case .retry: String(localized: "유지보수: 다시 확인", locale: locale)
        case .updateHelper: String(localized: "유지보수: 도우미 업데이트", locale: locale)
        case .transferOwnership: String(localized: "유지보수: 소유권 이전", locale: locale)
        }
    }

    private static func defaultMaintenanceTimestamp(_ date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// 구버전 도우미가 activity와 인식 가능한 reason을 모두 보내지 않은 경우에만 쓰는 꺼짐 문구.
    static func disabledStatusText(locale: Locale) -> String {
        BatteryStatusText.text(reason: .init(kind: .limitDisabled), detail: "", locale: locale)
    }

    /// 한도 선택기와 안내 배너를 그릴지 여부. 상태 줄은 항상 보인다.
    ///
    /// 명시적인 `false`만 숨긴다. `nil`은 "도우미가 아직 답하지 않았다"이며, 답이 없다는 이유로
    /// Mac을 불가능하다고 단정하면 정상 하드웨어에서 UI가 사라진다.
    static func showsConfigurationControls(isHardwareSupported: Bool?) -> Bool {
        isHardwareSupported != false
    }

    /// 토글을 조작할 수 있는지.
    ///
    /// 불가능한 하드웨어에서는 켤 수 없다. 그러나 **이미 켜져 있는 값은 끌 수 있어야 한다.** 충전
    /// 제어 레지스터는 기종이 아니라 펌웨어를 따라가므로(`BatteryControlKeys` 참고), 오늘 잘 쓰던
    /// Mac이 macOS 업데이트 한 번으로 지원 대상에서 빠질 수 있다. 그때 저장된 `true`는 그대로 남아
    /// 토글은 켜짐으로 표시된 채 조작 불가가 되고, 사용자에게는 전체 설정 초기화 말고 빠져나갈
    /// 길이 없어진다.
    ///
    /// 렌더링이 저장값을 대신 꺼주지 않는 것은 의도다(`SettingsBatterySection` 상단 주석): 같은
    /// 환경설정이 이 기능을 지원하는 Mac에 도달하는 순간 그 값은 틀린 값이 된다. 그래서 끄는 행위는
    /// 사용자에게 남기고, 이 함수는 그 길만 열어 둔다.
    static func isToggleEnabled(
        isHardwareSupported: Bool?,
        isLimitOn: Bool,
        isHeatProtectionOn: Bool = false
    ) -> Bool {
        showsConfigurationControls(isHardwareSupported: isHardwareSupported) || isLimitOn || isHeatProtectionOn
    }

    /// 한도 선택기를 조작할 수 있는지. 꺼짐 상태에서는 보이되 만질 수 없다.
    static func isLimitPickerEnabled(isLimitOn: Bool) -> Bool {
        isLimitOn
    }

    /// 비활성 상태의 사유 문구 (VoiceOver 힌트로도 쓰인다). 활성일 때는 `nil`.
    static func limitPickerDisabledReason(isLimitOn: Bool) -> String? {
        isLimitOn ? nil : "충전 제한을 켜면 한도를 조절할 수 있습니다."
    }

    // MARK: - Sailing Mode Helpers

    static let sailingDeltaPresets: [Int] = [2, 5, 10]

    static func resumePercentage(limit: Int, delta: Int) -> Int {
        max(45, limit - delta)
    }

    static func sailingRangeDescription(target: Int, resume: Int, locale: Locale) -> String {
        let target64 = Int64(target)
        let resume64 = Int64(resume)
        return String(format: String(localized: "%lld%% 도달 시 충전 정지, %lld%%에서 재충전", locale: locale),
                      locale: locale, target64, resume64)
    }

    static func sailingRangeDescription(limit: Int, delta: Int, locale: Locale) -> String {
        let resume = resumePercentage(limit: limit, delta: delta)
        return sailingRangeDescription(target: limit, resume: resume, locale: locale)
    }

    /// 상태 아이콘 + 문구. 설치 → 오류/미지원 → stale → 검증된 activity → 로컬 fallback 순이다.
    static func status(isLimitOn: Bool,
                       isHeatProtectionOn: Bool = false,
                       isInstalling: Bool,
                       mode: BatteryControlServiceMode,
                       reason: BatteryControlStatusReason?,
                       detail: String,
                       locale: Locale,
                       activity: BatteryControlActivity? = nil,
                       isHardwareSupported: Bool? = nil,
                       updatedAt: TimeInterval = 0,
                       now: TimeInterval = 0) -> Status {
        let effectiveReason = BatteryStatusText.resolve(reason: reason, detail: detail)
        let resolvedText = BatteryStatusText.text(resolvedReason: effectiveReason,
                                                  detail: detail,
                                                  locale: locale)

        if isInstalling {
            return Status(indicator: .installing,
                          text: String(localized: "도우미 설치 중…", locale: locale))
        }

        // Connection and hardware errors outrank freshness, verified activity, and the local
        // toggle. `.unavailable` is a current local connection result, not an old remote sample.
        switch mode {
        case .unavailable:
            return Status(indicator: .unavailable, text: resolvedText)
        case .unsupported:
            return Status(indicator: effectiveReason?.kind == .hardwareUnsupported
                          ? .hardwareUnsupported : .failure,
                          text: resolvedText)
        case .charging, .inhibited:
            break
        }

        // A zero timestamp is the client's initial state and means "no remote sample". Exactly
        // three polling intervals stays current; only a strictly older sample becomes stale.
        if shouldPollStatus(isLimitOn: isLimitOn,
                            isHeatProtectionOn: isHeatProtectionOn,
                            mode: mode,
                            isHardwareSupported: isHardwareSupported),
           updatedAt > 0,
           now >= updatedAt,
           now - updatedAt > staleAfter {
            return Status(indicator: .stale,
                          text: String(localized: "확인 중...", locale: locale))
        }

        if let resolvedActivity = BatteryControlActivity.resolved(explicit: activity,
                                                                  reason: effectiveReason) {
            return Status(indicator: indicator(for: resolvedActivity), text: resolvedText)
        }

        // The local toggle is the least authoritative input. It is used only when an old helper
        // sent neither activity nor a recognized reason and the mode carries no finer meaning.
        if !isLimitOn && !isHeatProtectionOn {
            return Status(indicator: .inactive, text: disabledStatusText(locale: locale))
        }

        return Status(indicator: mode == .inhibited ? .holdingAtLimit : .chargingToLimit,
                      text: resolvedText)
    }

    private static func indicator(for activity: BatteryControlActivity) -> Indicator {
        switch activity {
        case .inactive: return .inactive
        case .chargingToLimit: return .chargingToLimit
        case .holdingAtLimit: return .holdingAtLimit
        case .onBatteryPower: return .onBatteryPower
        case .sailing: return .sailing
        case .heatProtection: return .heatProtection
        case .topUp: return .topUp
        case .discharging: return .discharging
        case .calibration: return .calibration
        case .unrecognized:
            // `BatteryControlActivity.resolved` never returns this. Keep a total switch so a future
            // caller cannot turn an unknown token into a confident normal activity.
            return .failure
        }
    }

    /// "도우미 설치" 복구 버튼을 띄울지 여부. 이 버튼은 관리자 암호 프롬프트를 띄우므로,
    /// 사용자가 켜지도 않은 기능 때문에 암호를 묻지 않는다. 토글을 켜는 경로가 이미 설치를
    /// 수행하니 잃는 기능도 없다.
    static func isInstallButtonVisible(
        isLimitOn: Bool,
        isHeatProtectionOn: Bool = false,
        mode: BatteryControlServiceMode
    ) -> Bool {
        (isLimitOn || isHeatProtectionOn) && mode == .unavailable
    }

    /// 설정 화면이 상태를 주기적으로 다시 읽어야 하는지.
    ///
    /// 도우미가 "이 Mac은 불가능하다"고 명시적으로 답했다면 다시 묻지 않는다. 그 답은 영구적인
    /// 사실이라 재질문으로 바뀔 수 없고, 그 상태에서는 설정 컨트롤도 숨겨진다. 이 확인이 없으면
    /// 제한이 켜진 채로 지원되지 않는 Mac에 남은 사용자는 5초마다
    /// XPC 왕복과 루트 데몬의 전원 소스 읽기를 영원히 유발한다.
    ///
    /// 켜져 있으면 항상 읽는다 — 관심 있는 순간(한도 도달)이 창을 연 뒤 몇 분 뒤에 온다.
    ///
    /// 꺼져 있을 때는 문구가 바뀔 수 있는 상태에서만 읽는다. `.charging`은 정상적으로 꺼진 상태라
    /// 문구가 상수이고, `.unavailable`은 도우미가 없어 다시 물어봐야 답할 주체가 없다 — 둘 다
    /// 폴링해봐야 `batteryStatus` XPC → 데몬의 IOKit 전원 소스 읽기만 유발한다. 반대로
    /// `.inhibited`/`.unsupported`는 "껐는데 하드웨어가 아직 물고 있다"이고, 데몬이 스스로
    /// 재시도해 풀어내는 상태다. 여기서 읽지 않으면 사용자가 안내대로 어댑터를 다시 꽂아 실제로
    /// 복구된 뒤에도 화면은 실패 문구에 멈춰 있게 된다. `.unsupported`가 두 가지(레지스터 없음 /
    /// 쓰기 실패)를 함께 뜻하기 때문에, 영구적인 쪽을 걸러내는 일은 위의 `isHardwareSupported`
    /// 확인이 맡는다.
    static func shouldPollStatus(isLimitOn: Bool,
                                 isHeatProtectionOn: Bool = false,
                                 isTopUpOn: Bool = false,
                                 isDischargeOn: Bool = false,
                                 mode: BatteryControlServiceMode,
                                 isHardwareSupported: Bool?) -> Bool {
        if isHardwareSupported == false { return false }
        if isLimitOn || isHeatProtectionOn || isTopUpOn || isDischargeOn { return true }
        switch mode {
        case .inhibited, .unsupported: return true
        case .charging, .unavailable: return false
        }
    }

    // MARK: - Upcoming Schedule Presentation

    public static func upcomingScheduleText(
        schedule: BatteryChargingSchedule?,
        triggerDate: Date?
    ) -> String? {
        guard let schedule, let triggerDate else { return nil }
        let timeStr = schedule.time.formattedText
        return "다음: \(timeStr) \(schedule.action.summary)"
    }

    // MARK: - Discharge & Power Flow Presentation

    /// Format duration in minutes into localized string (e.g. "34분", "1시간 10분", "34 min", "1 hr 10 min")
    static func formatDuration(minutes: Int, locale: Locale = Locale(identifier: "ko")) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 {
            return String(format: String(localized: "%@분", locale: locale), locale: locale, "\(m)")
        } else if m == 0 {
            return String(format: String(localized: "%@시간", locale: locale), locale: locale, "\(h)")
        } else {
            return String(format: String(localized: "%@시간 %@분", locale: locale), locale: locale, "\(h)", "\(m)")
        }
    }

    /// Calculate estimated discharge remaining time in minutes
    static func estimatedDischargeTimeMinutes(
        currentSoC: Int,
        targetSoC: Int,
        netWatts: Double,
        capacityWh: Double
    ) -> Int? {
        guard currentSoC > targetSoC, capacityWh > 0 else { return nil }
        let rate = abs(netWatts)
        guard rate >= 0.5 else { return nil }
        let deltaSoC = Double(currentSoC - targetSoC) / 100.0
        let energyToDischargeWh = capacityWh * deltaSoC
        let hours = energyToDischargeWh / rate
        let minutes = Int((hours * 60.0).rounded())
        return max(1, minutes)
    }

    /// Format estimated discharge remaining time string (e.g. "약 34분 남음", "About 34 min remaining")
    static func estimatedDischargeTime(
        currentSoC: Int,
        targetSoC: Int,
        netWatts: Double,
        capacityWh: Double,
        locale: Locale = Locale(identifier: "ko")
    ) -> String? {
        guard let minutes = estimatedDischargeTimeMinutes(
            currentSoC: currentSoC,
            targetSoC: targetSoC,
            netWatts: netWatts,
            capacityWh: capacityWh
        ) else {
            return nil
        }
        let duration = formatDuration(minutes: minutes, locale: locale)
        return String(format: String(localized: "약 %@ 남음", locale: locale), locale: locale, duration)
    }

    /// Format discharge status description (e.g. "수동 방전 진행 중", "Manual discharge in progress")
    static func dischargeDescription(
        target _: Int = 0,
        currentSoC _: Int = 0,
        watts _: Double = 0,
        locale: Locale = Locale(identifier: "ko")
    ) -> String {
        String(localized: "수동 방전 진행 중", locale: locale)
    }

    /// Blocked adapter power text during forced discharge (e.g. "0.0 W (차단됨)", "0.0 W (Blocked)")
    static func adapterPowerBlockedText(locale: Locale = Locale(identifier: "ko")) -> String {
        String(localized: "0.0 W (차단됨)", locale: locale)
    }

    /// Top-up hold status text (e.g. "완충 완료 (어댑터 전원 구동)", "Top-Up Complete (Adapter Power)")
    static func topUpHoldText(locale: Locale = Locale(identifier: "ko")) -> String {
        String(localized: "완충 완료 (어댑터 전원 구동)", locale: locale)
    }

    /// Forced discharge label (e.g. "배터리 (수동 방전 중)", "Battery (Manual Discharge)")
    static func forcedDischargeText(locale: Locale = Locale(identifier: "ko")) -> String {
        String(localized: "배터리 (수동 방전 중)", locale: locale)
    }

    /// Start discharge button label (e.g. "방전 시작", "Start Discharge")
    static func startDischargeButtonText(targetSoC _: Int, locale: Locale = Locale(identifier: "ko")) -> String {
        String(localized: "방전 시작", locale: locale)
    }

    /// Reason why manual discharge cannot be started, or nil if discharge is available.
    static func manualDischargeDisabledReason(
        isPluggedIn: Bool,
        currentSoC: Int,
        targetSoC: Int,
        isHardwareSupported: Bool = true,
        isToggleEnabled: Bool = true,
        locale: Locale = Locale(identifier: "ko")
    ) -> String? {
        guard isHardwareSupported && isToggleEnabled else {
            let isKo = locale.language.languageCode?.identifier == "ko"
            return isKo ? "배터리 충전 제어가 꺼져 있습니다." : "Battery charge control is disabled."
        }
        guard isPluggedIn else {
            let isKo = locale.language.languageCode?.identifier == "ko"
            return isKo ? "전원 어댑터가 연결되어 있어야 방전할 수 있습니다." : "Connect power adapter to start discharge."
        }
        guard currentSoC > targetSoC else {
            let isKo = locale.language.languageCode?.identifier == "ko"
            return isKo ? "현재 배터리 잔량이 목표 잔량 이하입니다." : "Battery level is already at or below target."
        }
        return nil
    }

    /// Gate for showing the Power Supply section in the expanded battery card.
    /// Returns true if power flow exists and either external power is connected or active discharge is underway.
    static func shouldShowPowerSupplySection(
        sampleExternalConnected: Bool,
        serviceAdapterConnected: Bool,
        activity: BatteryControlActivity?,
        manualDischargeActive: Bool,
        powerFlowScenario: PowerFlowScenario?
    ) -> Bool {
        guard let powerFlowScenario else { return false }
        return sampleExternalConnected
            || serviceAdapterConnected
            || activity == .discharging
            || manualDischargeActive
            || powerFlowScenario == .activeDischarge
    }

    /// Gate for showing battery control rows (Top-up, Discharge) in the expanded battery card.
    /// Returns true if power adapter is connected or active discharge/top-up is underway/requested.
    static func shouldShowBatteryControlRows(
        sampleCharging: Bool,
        sampleExternalConnected: Bool,
        serviceAdapterConnected: Bool,
        activity: BatteryControlActivity?,
        manualDischargeActive: Bool
    ) -> Bool {
        sampleCharging
            || sampleExternalConnected
            || serviceAdapterConnected
            || activity == .discharging
            || activity == .topUp
            || manualDischargeActive
    }

    /// Determines whether the "한 번만 완충 (Top-Up)" row should be visible in the expanded battery card.
    /// Returns true if enabled by user settings, or if top-up is currently active.
    static func shouldShowTopUpRow(
        showSetting: Bool,
        isTopUpActive: Bool
    ) -> Bool {
        showSetting || isTopUpActive
    }

    /// Determines whether the "수동 방전 (Manual Discharge)" row should be visible in the expanded battery card.
    /// Returns true if currently discharging (safety override), or if enabled by settings and current SoC exceeds target.
    static func shouldShowManualDischargeRow(
        showSetting: Bool,
        isDischarging: Bool,
        currentSoC: Int,
        targetSoC: Int
    ) -> Bool {
        if isDischarging { return true }
        guard showSetting else { return false }
        return currentSoC > targetSoC
    }

    /// Determines whether the battery control section container and divider should be rendered.
    static func shouldShowBatteryControlSection(
        showControlRows: Bool,
        willShowTopUp: Bool,
        willShowDischarge: Bool
    ) -> Bool {
        showControlRows && (willShowTopUp || willShowDischarge)
    }
}

