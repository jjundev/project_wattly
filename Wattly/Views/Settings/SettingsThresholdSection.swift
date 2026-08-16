import SwiftUI

/// Threshold settings section: CPU/GPU utilization and CPU/GPU temperature warning/critical sliders.
struct SettingsThresholdSection: View {
    @Environment(\.tokens) private var t
    @AppStorage(StorageKey.thresholds) private var thresholds = Defaults.thresholds

    var body: some View {
        SettingsSection(title: "상태 경고 기준") {
            SettingsCard(padding: Tokens.cardPadding) {
                VStack(alignment: .leading, spacing: 16) {
                    thresholdBlock(title: "CPU 사용률 (%)", keyPath: \.cpu,
                                   warnRange: 10...95, critRange: 20...100, suffix: "%")
                    thresholdDivider
                    gpuThresholdBlock
                    thresholdDivider
                    thresholdBlock(title: "CPU · GPU 온도 (°C)", keyPath: \.temp,
                                   warnRange: 40...100, critRange: 50...110, suffix: "°")
                }
            }
        }
    }

    private var gpuThresholdBlock: some View {
        let isEnabled = thresholds.gpu != nil
        let gpuToggleBinding = Binding(
            get: { thresholds.gpu != nil },
            set: { on in
                if on {
                    thresholds.gpu = ThresholdPair(warn: 85, crit: 95)
                } else {
                    thresholds.gpu = nil
                }
            }
        )

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("GPU 사용률 (%)")
                        .font(WattlyFont.at(12.5, weight: .semibold))
                        .foregroundStyle(t.text)
                    Text("그래픽 렌더링 및 연산 시 사용률이 높아지는 것은 정상 동작입니다. 알림이 필요할 때만 켜세요.")
                        .font(WattlyFont.at(10.5, weight: .regular))
                        .foregroundStyle(t.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                WattlyToggle(isOn: gpuToggleBinding, isEnabled: true)
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("GPU 사용률 상태 경고")
            .accessibilityValue(isEnabled ? "켜짐" : "꺼짐")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                gpuToggleBinding.wrappedValue.toggle()
            }

            if isEnabled {
                VStack(spacing: 8) {
                    thresholdRow(
                        dot: Tokens.statusOrange,
                        label: "주의",
                        binding: Binding(
                            get: { thresholds.gpu?.warn ?? 85 },
                            set: { v in
                                if let pair = thresholds.gpu {
                                    thresholds.gpu = pair.setting(.warn, to: v)
                                }
                            }
                        ),
                        range: 10...95,
                        suffix: "%"
                    )
                    thresholdRow(
                        dot: Tokens.statusRed,
                        label: "위험",
                        binding: Binding(
                            get: { thresholds.gpu?.crit ?? 95 },
                            set: { v in
                                if let pair = thresholds.gpu {
                                    thresholds.gpu = pair.setting(.crit, to: v)
                                }
                            }
                        ),
                        range: 20...100,
                        suffix: "%"
                    )
                }
                .padding(.top, 4)
            }
        }
    }

    private var thresholdDivider: some View {
        Rectangle().fill(t.line).frame(height: 1)
    }

    private func thresholdBlock(title: String, keyPath: WritableKeyPath<Thresholds, ThresholdPair>,
                                warnRange: ClosedRange<Double>, critRange: ClosedRange<Double>,
                                suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(LocalizedStringKey(title))
                .font(WattlyFont.at(12.5, weight: .semibold))
                .foregroundStyle(t.text)
            thresholdRow(dot: Tokens.statusOrange, label: "주의",
                         binding: thresholdBinding(keyPath, .warn), range: warnRange, suffix: suffix)
            thresholdRow(dot: Tokens.statusRed, label: "위험",
                         binding: thresholdBinding(keyPath, .crit), range: critRange, suffix: suffix)
        }
    }

    private func thresholdRow(dot: Color, label: String, binding: Binding<Double>,
                              range: ClosedRange<Double>, suffix: String) -> some View {
        HStack(spacing: 9) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(LocalizedStringKey(label))
                .font(WattlyFont.at(12, weight: .regular))
                .foregroundStyle(t.sub)
                .frame(width: 30, alignment: .leading)
            Slider(value: binding, in: range, step: 1).tint(dot)
            Text("\(Int(binding.wrappedValue))\(suffix)")
                .font(WattlyFont.at(12, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(t.text)
                .frame(width: 40, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    /// Clamping `Double` binding into one (metric, control); `ThresholdPair.setting` rounds and
    /// clamps (warn ≤ crit, edited control wins). Reassigns the whole `thresholds` so the
    /// `@AppStorage` re-encodes (issue 10 seam).
    private func thresholdBinding(_ keyPath: WritableKeyPath<Thresholds, ThresholdPair>,
                                  _ control: ThresholdPair.Control) -> Binding<Double> {
        Binding(
            get: {
                let pair = thresholds[keyPath: keyPath]
                return control == .warn ? pair.warn : pair.crit
            },
            set: { newValue in
                var next = thresholds
                next[keyPath: keyPath] = next[keyPath: keyPath].setting(control, to: newValue)
                thresholds = next
            }
        )
    }
}
