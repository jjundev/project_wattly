import SwiftUI

/// Behavior settings section: Background refresh cadence preset / interval, and Power smoothing toggle.
struct SettingsBehaviorSection: View {
    @Environment(\.tokens) private var t

    @AppStorage(StorageKey.pollInterval) private var pollInterval = Defaults.pollInterval
    @AppStorage(StorageKey.powerMode) private var powerMode = Defaults.powerMode
    @AppStorage(StorageKey.powerSmoothed) private var powerSmoothed = Defaults.powerSmoothed

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            backgroundUpdateSection
            smoothingSection
        }
    }

    // MARK: - 백그라운드 갱신

    private var refreshPresetBinding: Binding<BackgroundRefreshPreset> {
        Binding(
            get: {
                BackgroundRefreshPreset.resolve(interval: pollInterval, mode: powerMode)
            },
            set: { newPreset in
                switch newPreset {
                case .eco:
                    powerMode = .eco
                    pollInterval = .auto
                case .performance:
                    powerMode = .performance
                    pollInterval = .auto
                case .custom:
                    if pollInterval == .auto {
                        pollInterval = .s2
                    }
                }
            }
        )
    }

    private var backgroundUpdateSection: some View {
        SettingsSection(title: "백그라운드 갱신") {
            SettingsCard(padding: Tokens.cardPadding) {
                VStack(alignment: .leading, spacing: 10) {
                    WattlySegment(selection: refreshPresetBinding, options: [
                        (.eco, BackgroundRefreshPreset.eco.label),
                        (.performance, BackgroundRefreshPreset.performance.label),
                        (.custom, BackgroundRefreshPreset.custom.label),
                    ])

                    if pollInterval != .auto {
                        Rectangle().fill(t.line).frame(height: 1)
                        Text("갱신 주기")
                            .font(WattlyFont.at(11.5, weight: .regular))
                            .foregroundStyle(t.faint)
                        WattlySegment(selection: $pollInterval,
                                      options: PollInterval.allCases.filter { $0 != .auto }.map { ($0, $0.label) },
                                      pillVPadding: 6)
                    }

                    Text(pollingDescription(for: pollInterval, mode: powerMode))
                        .font(WattlyFont.at(11.5, weight: .regular))
                        .foregroundStyle(t.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 전력 표시

    private var smoothingSection: some View {
        SettingsSection(title: "전력 표시") {
            SettingsCard {
                SettingsToggleRow(isOn: $powerSmoothed, divider: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        SettingsRowTitle("전력 표시 안정화")
                        Text("순간적인 변동을 줄여 지속적인 전력 사용량을 보기 쉽게 표시합니다. 측정 방식은 바뀌지 않습니다.")
                            .font(WattlyFont.at(11.5, weight: .regular))
                            .foregroundStyle(t.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
