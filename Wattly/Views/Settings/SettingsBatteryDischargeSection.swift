import SwiftUI

/// 설정 › 배터리의 방전 카드 두 장 — 방전 제어와 덮개 방전.
///
/// 충전 제한 카드에서 떼어낸 이유는 두 가지다. `SettingsBatterySection`이 970줄까지 자라
/// 한 화면에 들고 읽기 어려워졌고, 방전은 충전 제한과 다른 하드웨어 축(CHIE,
/// `isDischargeHardwareSupported`)에 걸려 있어 게이팅 조건이 애초에 다르다.
struct SettingsBatteryDischargeSection: View {
    @Environment(\.tokens) private var t
    @Environment(\.locale) private var locale
    let monitor: SystemMonitor
    let batteryControl: BatteryControlClient

    /// 강제 방전이 시작된 벽시계 시각. 4초 EMA가 실제 방전 전력까지 오르는 데 걸리는 구간을
    /// 재기 위한 표시 전용 시계다 — Top Up의 12시간 만료처럼 데몬이 소유해야 하는 판정이
    /// 아니므로 뷰가 들고 있어도 진실의 출처가 갈라지지 않는다.
    @State private var dischargeStartedAt: Date?

    // `SettingsBatterySection`과 같은 키를 읽는다. `@AppStorage`는 같은 저장소를 보므로
    // 두 뷰가 같은 값을 들고 있어도 어긋나지 않는다.
    @AppStorage(StorageKey.batteryLimitEnabled) private var batteryLimitEnabled = Defaults.batteryLimitEnabled
    @AppStorage(StorageKey.batteryHeatProtectionEnabled) private var batteryHeatProtectionEnabled = Defaults.batteryHeatProtectionEnabled
    @AppStorage(StorageKey.batteryAutoDischargeEnabled) private var autoDischargeEnabled = Defaults.batteryAutoDischargeEnabled
    @AppStorage(StorageKey.batteryManualDischargeTarget) private var manualDischargeTarget = Defaults.batteryManualDischargeTarget
    @AppStorage(StorageKey.batteryClamshellDischargeEnabled) private var clamshellDischargeEnabled = Defaults.batteryClamshellDischargeEnabled

    /// 저장된 값이 새 상한(95)을 넘을 수 있다 — 상한을 내리기 전에 100을 저장한 사용자가 있다.
    /// 화면·판정·전송이 서로 다른 숫자를 보면 "100%인데 시작 버튼이 영원히 꺼져 있다"가 되므로
    /// 읽는 쪽을 한 곳으로 모은다. 저장값 자체는 건드리지 않는다 — 렌더링이 사용자의 설정을
    /// 조용히 덮어쓰지 않게 하기 위해서다.
    ///
    /// 클램프 자체는 `BatterySectionPresentation.clampedManualDischargeTarget`에 있다 — 이 파일만
    /// 클램프하던 예전 버전은 `SettingsBatterySection`·`BatteryControlBridge`·
    /// `CardExpandRegion`이 계속 원시값을 데몬에 보내는 사각지대를 남겼다.
    private var dischargeTarget: Int {
        BatterySectionPresentation.clampedManualDischargeTarget(manualDischargeTarget)
    }

    /// `Slider`가 요구하는 `ClosedRange<Double>`로 변환한 `manualDischargeTargetRange` — 슬라이더의
    /// `in:`과 클램프가 같은 정수 상수를 공유하도록 이 한 곳에서만 변환한다.
    private var dischargeSliderRange: ClosedRange<Double> {
        let range = BatterySectionPresentation.manualDischargeTargetRange
        return Double(range.lowerBound)...Double(range.upperBound)
    }

    private var isHardwareUnsupported: Bool {
        batteryControl.status.isHardwareSupported == false
    }

    /// CHIE 강제 방전 미지원. `nil`은 이 필드를 모르는 구버전 헬퍼이며 "미지원"이 아니라
    /// "모름"이므로 차단하지 않는다.
    private var isDischargeUnsupported: Bool {
        batteryControl.status.isDischargeHardwareSupported == false
    }

    /// 목표 슬라이더를 만질 수 있는지 — **하드웨어 두 축만** 본다.
    ///
    /// 시작 버튼의 활성 조건(`BatterySectionPresentation.isManualDischargeActionable`)과 일부러
    /// 다르다. 그쪽은 어댑터 연결과 `현재 잔량 > 목표`까지 요구하는데, 그 조건으로 슬라이더까지
    /// 잠그면 잔량이 목표 이하일 때 목표를 낮춰 빠져나올 방법이 사라진다.
    private var isDischargeHardwareUsable: Bool {
        isToggleEnabled && !isHardwareUnsupported && !isDischargeUnsupported
    }

    private var showsConfigurationControls: Bool {
        BatterySectionPresentation.showsConfigurationControls(
            isHardwareSupported: batteryControl.status.isHardwareSupported)
    }

    private var isToggleEnabled: Bool {
        BatterySectionPresentation.isToggleEnabled(
            isHardwareSupported: batteryControl.status.isHardwareSupported,
            isLimitOn: batteryLimitEnabled,
            isHeatProtectionOn: batteryHeatProtectionEnabled)
    }

    private var isLimitPickerEnabled: Bool {
        BatterySectionPresentation.isLimitPickerEnabled(isLimitOn: batteryLimitEnabled)
    }

    /// 강제 방전을 지금 누가 소유하고 있는지. 판별은 `BatterySectionPresentation`에만 있다 —
    /// 예전에는 이 뷰가 `activity == .discharging`을 직접 읽어서 자동 방전이 "수동 방전
    /// 진행 중" 배너와 "방전 중지" 버튼으로 표시됐고, 그 버튼은 자동 방전을 끄지 못했다.
    private var dischargeOwner: BatterySectionPresentation.DischargeOwner {
        BatterySectionPresentation.dischargeOwner(
            manualDischargeActive: batteryControl.status.desiredConfiguration?.manualDischargeActive,
            reasonKind: batteryControl.status.detailReason?.kind,
            activity: batteryControl.status.activity)
    }

    /// 데몬이 지금 시스템 잠자기를 억제 중인지. `nil`(구버전 헬퍼)은 표시하지 않는다.
    private var isSleepInhibited: Bool {
        batteryControl.status.isSystemSleepInhibited == true
    }

    private var isClamshellToggleEnabled: Bool {
        BatterySectionPresentation.isClamshellDischargeToggleEnabled(
            helperMode: batteryControl.status.mode,
            capabilities: batteryControl.status.capabilities,
            isDischargeHardwareSupported: batteryControl.status.isDischargeHardwareSupported)
    }

    /// 사용자가 연 수동 방전 세션이 열려 있는지 — 목표 도달 후 홀드 구간도 포함한다.
    private var isManualDischargeActive: Bool { dischargeOwner == .manual }

    /// 4초 EMA를 거친 배터리 표본. 표본이 30초 넘게 끊겼다가 재개되면 EMA가 원시값으로
    /// 재시드되므로(`PowerSmoothing.emaStep`의 `maxGap`), 설정 창을 방전 도중에 열었을 때는
    /// 첫 표본부터 곧바로 정확하다.
    private var liveBatterySample: BatterySample? {
        guard case .value(.battery(let s)) = monitor.cardState(.battery, smoothed: true) else {
            return nil
        }
        return s
    }

    private var dischargeElapsedSeconds: Double {
        guard let dischargeStartedAt else { return 0 }
        return Date().timeIntervalSince(dischargeStartedAt)
    }

    /// "예상 완료: 약 34분 후". 표본·용량·워밍업 중 하나라도 없으면 `nil`을 돌려 줄을 통째로
    /// 숨긴다 — 자리를 채우려고 근사치를 지어내지 않는다.
    private func dischargeEstimateText(currentSoC: Int, targetSoC: Int) -> String? {
        guard BatterySectionPresentation.shouldShowDischargeEstimate(
                secondsSinceStart: dischargeElapsedSeconds),
              let sample = liveBatterySample,
              let capacityWh = sample.maxWh,
              let minutes = BatterySectionPresentation.estimatedDischargeTimeMinutes(
                  currentSoC: currentSoC,
                  targetSoC: targetSoC,
                  netWatts: sample.netW,
                  capacityWh: capacityWh)
        else { return nil }
        let duration = BatterySectionPresentation.formatDuration(minutes: minutes, locale: locale)
        return String(format: String(localized: "예상 완료: 약 %@ 후", locale: locale),
                      locale: locale, duration)
    }

    var body: some View {
        if showsConfigurationControls {
            SettingsSection("방전 제어") {
                dischargeControlCard
                clamshellDischargeCard
            }
            .task {
                // 설정 창이 열려 있는 동안만 배터리를 2초로 깨운다. 팝오버가 닫힌 기본 상태에서
                // 배터리 provider는 아예 읽히지 않으므로, 이게 없으면 위 실측값이 묵은 표본이 된다.
                monitor.setBatteryLiveDemand(true)
                // 창을 여는 순간 이미 방전 중이면 EMA는 방금 원시값으로 재시드된 상태다 —
                // 워밍업을 기다릴 이유가 없으므로 게이트를 통과시킨다.
                dischargeStartedAt = isManualDischargeActive ? .distantPast : nil
            }
            .onDisappear { monitor.setBatteryLiveDemand(false) }
            .onChange(of: isManualDischargeActive) { _, active in
                dischargeStartedAt = active ? Date() : nil
            }
        }
    }

    @ViewBuilder
    private var dischargeControlCard: some View {
        SettingsCard {
            SettingsToggleRow(
                isOn: $autoDischargeEnabled,
                divider: true,
                // 게이트 두 축은 `BatterySectionPresentation`이 정의한다. 충전 한도가 꺼져
                // 있으면 데몬이 자동 방전을 돌리지 않아 아무 일도 하지 않는 스위치가 되고,
                // 수동 방전 세션 중에는 자동 방전이 그것을 이어받아 버리므로 잠근다.
                isEnabled: BatterySectionPresentation.isAutoDischargeToggleEnabled(
                    isLimitOn: batteryLimitEnabled,
                    dischargeOwner: dischargeOwner),
                disabledReason: BatterySectionPresentation.autoDischargeToggleDisabledReason(
                    isLimitOn: batteryLimitEnabled,
                    dischargeOwner: dischargeOwner,
                    locale: locale)
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        SettingsRowTitle("자동 방전")
                        // 자동 방전에는 지금까지 자기 표시가 없어서, 진행 중인 것이 수동
                        // 방전 카드의 배너로 잘못 나타났다.
                        if dischargeOwner == .automatic {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Tokens.statusOrange)
                                    .frame(width: 6, height: 6)
                                Text(LocalizedStringKey("자동 방전 진행 중"))
                                    .font(WattlyFont.at(10, weight: .semibold))
                                    .foregroundStyle(Tokens.statusOrange)
                            }
                        }
                        if dischargeOwner == .automatic && isSleepInhibited {
                            Text(verbatim: BatterySectionPresentation.sleepInhibitedText(locale: locale))
                                .font(WattlyFont.at(10, weight: .regular))
                                .foregroundStyle(t.faint)
                        }
                    }
                    Text("충전 한도를 현재 잔량보다 낮게 변경하면 별도 조작 없이 자동으로 한도까지 방전합니다.")
                        .font(WattlyFont.at(10.5, weight: .regular))
                        .foregroundStyle(t.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    SettingsRowTitle("수동 방전")
                    Text("원하는 목표 잔량까지 배터리를 전원 어댑터 연결 상태에서 강제로 방전합니다.")
                        .font(WattlyFont.at(10.5, weight: .regular))
                        .foregroundStyle(t.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 0, trailing: 14))

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("목표 방전 잔량")
                            .font(WattlyFont.at(11.5, weight: .medium))
                            .foregroundStyle(t.sub)
                        Spacer()
                        Text("\(dischargeTarget)%")
                            .font(WattlyFont.at(13, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Tokens.statusOrange)
                    }
                    // 다른 섹션과 같은 방식으로 헤더까지 함께 흐려져야 "지금은 못 만진다"가
                    // 한 덩어리로 읽힌다.
                    .opacity(isDischargeHardwareUsable ? 1 : 0.5)

                    Slider(
                        value: Binding(
                            // 상한을 95로 낮추기 전에 100을 저장한 사용자가 있다. 슬라이더가
                            // 범위 밖 값을 받으면 엄지 위치가 어긋나므로 읽을 때 좁혀 준다.
                            get: { Double(dischargeTarget) },
                            set: { manualDischargeTarget = Int($0.rounded()) }
                        ),
                        // 100%는 `현재 잔량 > 목표`가 성립할 수 없어 영구 비활성이다 —
                        // 고를 수 있는 값은 전부 실행 가능한 값이어야 한다. 리터럴 50...95를
                        // 다시 쓰지 않는다 — `dischargeSliderRange`(→ `manualDischargeTargetRange`)가
                        // 클램프와 공유하는 유일한 출처다.
                        in: dischargeSliderRange,
                        step: 1
                    )
                    .tint(Tokens.statusOrange)
                    .disabled(!isDischargeHardwareUsable)
                    .accessibilityLabel(Text(LocalizedStringKey("목표 방전 잔량")))
                    // 화면에 보이는 헤더와 같은 `dischargeTarget`을 읽는다.
                    // 원시 저장값을 읽으면 상한 이전에 100을 저장한 사용자에게 엄지는 95%,
                    // 눈에 보이는 숫자는 95%인데 VoiceOver만 "100%"라고 말한다.
                    .accessibilityValue(Text(verbatim: "\(dischargeTarget)%"))

                    // 양 끝은 `manualDischargeTargetRange`에서 뽑는다 — 클램프 상·하한이 바뀌면
                    // 눈금도 같이 움직여야 슬라이더 트랙과 어긋나지 않는다. 가운데 세 개
                    // (60/70/80/90)는 그 사이를 고르게 나눈 정지점일 뿐 다른 상수에 매여 있지
                    // 않으므로 리터럴로 둔다 — 억지로 계산식을 만들면 "10% 간격"이라는 읽기
                    // 쉬운 사실을 코드 뒤에 숨기게 된다.
                    HStack {
                        Text(verbatim: "\(BatterySectionPresentation.manualDischargeTargetRange.lowerBound)%")
                        Spacer()
                        Text("60%")
                        Spacer()
                        Text("70%")
                        Spacer()
                        Text("80%")
                        Spacer()
                        Text("90%")
                        Spacer()
                        Text(verbatim: "\(BatterySectionPresentation.manualDischargeTargetRange.upperBound)%")
                    }
                    .font(WattlyFont.at(10, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(t.faint)
                    // 슬라이더 값이 이미 읽히므로 눈금은 VoiceOver 정지점이 될 이유가 없다.
                    .accessibilityHidden(true)
                }
                .padding(EdgeInsets(top: 0, leading: 14, bottom: 8, trailing: 14))

                Rectangle().fill(t.line).frame(height: 1)

                let isPluggedIn = batteryControl.status.isPowerAdapterConnected
                let currentSoC = batteryControl.status.currentPercentage
                // 사유의 부재로 정의한다 — 조건을 여기서 따로 적으면 버튼 활성 여부와 아래
                // 표시되는 사유가 갈라질 수 있고, 팝오버가 실제로 그렇게 갈라져 있었다.
                let canStartDischarge = BatterySectionPresentation.isManualDischargeActionable(
                    isPluggedIn: isPluggedIn,
                    currentSoC: currentSoC,
                    targetSoC: dischargeTarget,
                    isHardwareSupported: !isHardwareUnsupported,
                    isDischargeHardwareSupported: !isDischargeUnsupported,
                    isToggleEnabled: isToggleEnabled,
                    isAutoDischargeEnabled: autoDischargeEnabled)

                if isManualDischargeActive {
                    let target = batteryControl.status.desiredConfiguration?.manualDischargeTarget ?? dischargeTarget
                    VStack(spacing: 8) {
                        HStack {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Tokens.statusOrange)
                                    .frame(width: 7, height: 7)
                                Text(BatterySectionPresentation.dischargeDescription(owner: .manual, target: target, locale: locale))
                                    .font(WattlyFont.at(11.5, weight: .semibold))
                                    .foregroundStyle(Tokens.statusOrange)
                            }
                            Spacer()
                            Button {
                                let preferences = BatteryPreferences(defaults: .standard)
                                Task {
                                    await batteryControl.stopManualDischarge(preferences: preferences)
                                }
                            } label: {
                                Text("방전 중지")
                                    .font(WattlyFont.at(11, weight: .semibold))
                                    .foregroundStyle(Tokens.statusRed)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Tokens.statusRed.opacity(0.15)))
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Tokens.statusRed.opacity(0.35), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }

                        HStack {
                            if let sample = liveBatterySample {
                                Text(verbatim: String(
                                    format: String(localized: "실시간 소모: %@", locale: locale),
                                    locale: locale,
                                    CardPresentation.batteryNetWattText(sample)))
                                    .font(WattlyFont.at(10.5, weight: .regular))
                                    .foregroundStyle(t.sub)
                            }
                            Spacer()
                            if let eta = dischargeEstimateText(currentSoC: currentSoC,
                                                               targetSoC: target) {
                                Text(verbatim: eta)
                                    .font(WattlyFont.at(10.5, weight: .regular))
                                    .foregroundStyle(t.sub)
                            }
                        }

                        if isSleepInhibited {
                            HStack(spacing: 4) {
                                Image(systemName: "moon.zzz")
                                    .font(.system(size: 10))
                                Text(verbatim: BatterySectionPresentation.sleepInhibitedText(locale: locale))
                            }
                            .font(WattlyFont.at(10.5, weight: .regular))
                            .foregroundStyle(t.sub)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Tokens.statusOrange.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(Tokens.statusOrange.opacity(0.28), lineWidth: 1)
                    )
                    .padding(EdgeInsets(top: 0, leading: 14, bottom: 12, trailing: 14))
                } else {
                    let disabledReason = BatterySectionPresentation.manualDischargeDisabledReason(
                        isPluggedIn: isPluggedIn,
                        currentSoC: currentSoC,
                        targetSoC: dischargeTarget,
                        isHardwareSupported: !isHardwareUnsupported,
                        isDischargeHardwareSupported: !isDischargeUnsupported,
                        isToggleEnabled: isToggleEnabled,
                        isAutoDischargeEnabled: autoDischargeEnabled,
                        locale: locale
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            HStack(spacing: 4) {
                                Text("현재 잔량:")
                                    .font(WattlyFont.at(11, weight: .regular))
                                    .foregroundStyle(t.faint)
                                Text("\(currentSoC)%")
                                    .font(WattlyFont.at(11, weight: .semibold))
                                    .foregroundStyle(t.text)
                            }
                            Spacer()
                            Button {
                                let preferences = BatteryPreferences(defaults: .standard)
                                Task {
                                    await batteryControl.startManualDischarge(preferences: preferences)
                                }
                            } label: {
                                Text(verbatim: BatterySectionPresentation.startDischargeButtonText(
                                    targetSoC: dischargeTarget,
                                    locale: locale))
                                    .font(WattlyFont.at(11.5, weight: .semibold))
                                    .foregroundStyle(canStartDischarge ? Tokens.statusOrange : t.faint)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(canStartDischarge ? Tokens.statusOrange.opacity(0.15) : t.segTrack)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(canStartDischarge ? Tokens.statusOrange.opacity(0.35) : t.rowBorder, lineWidth: 1)
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!canStartDischarge)
                            .accessibilityLabel(Text(verbatim: BatterySectionPresentation.startDischargeButtonText(targetSoC: dischargeTarget, locale: locale)))
                            .accessibilityHint(Text(verbatim: disabledReason ?? ""))
                        }
                        // macOS는 disabled 컨트롤에 `.help()` 툴팁을 띄우지 않는다. 사유를
                        // 툴팁에만 걸어 두면 정작 필요한 순간에 보이지 않으므로 본문으로 낸다.
                        if let disabledReason, !canStartDischarge {
                            Text(verbatim: disabledReason)
                                .font(WattlyFont.at(10.5, weight: .regular))
                                .foregroundStyle(t.faint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(EdgeInsets(top: 0, leading: 14, bottom: 14, trailing: 14))
                }
            }
        }
    }

    @ViewBuilder
    private var clamshellDischargeCard: some View {
        SettingsCard {
            SettingsToggleRow(
                isOn: $clamshellDischargeEnabled,
                divider: false,
                isEnabled: isClamshellToggleEnabled,
                disabledReason: BatterySectionPresentation.clamshellDischargeToggleDisabledReason(
                    helperMode: batteryControl.status.mode,
                    capabilities: batteryControl.status.capabilities,
                    isDischargeHardwareSupported: batteryControl.status.isDischargeHardwareSupported,
                    locale: locale)
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    SettingsRowTitle("덮개를 닫아도 방전 계속")
                    Text("외장 디스플레이가 연결된 동안 방전 중에는 Mac이 잠들지 않습니다. Apple 메뉴의 잠자기도 동작하지 않습니다.")
                        .font(WattlyFont.at(10.5, weight: .regular))
                        .foregroundStyle(t.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
