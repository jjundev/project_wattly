import SwiftUI

/// The "그래프 임곗값" settings control (issue 10 §7) — warn/crit sliders for CPU·메모리·온도
/// (temperature is the one shared pair for CPU/GPU/battery). Self-contained: it writes
/// `@AppStorage(thresholds)`, which `PopoverContentView` reads to color the sparklines, so a
/// drag recolors the panel live. The clamp (edited control authoritative, integer step)
/// lives in the pure `ThresholdPair.setting`. Temporarily mounted in the skeleton
/// `SettingsView` (the `PollIntervalSetting` pattern); issue 13 relocates it into the full
/// settings layout, adds the pixel chrome, and wires "기본값으로 되돌리기".
struct ThresholdSettings: View {
    @Environment(\.tokens) private var t
    @AppStorage(StorageKey.thresholds) private var thresholds = Defaults.thresholds

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("그래프 임곗값")
                .font(WattlyFont.at(11, weight: .bold))
                .tracking(0.33)
                .foregroundStyle(t.faint)

            VStack(alignment: .leading, spacing: 16) {
                block(title: "CPU 사용률 (%)", keyPath: \.cpu,
                      warnRange: 10...95, critRange: 20...100, suffix: "%")
                divider
                block(title: "메모리 (%)", keyPath: \.mem,
                      warnRange: 10...95, critRange: 20...100, suffix: "%")
                divider
                block(title: "온도 · CPU·GPU·배터리 (°C)", keyPath: \.temp,
                      warnRange: 40...100, critRange: 50...110, suffix: "°")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(t.rowBg))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(t.rowBorder, lineWidth: 1))
        }
    }

    private var divider: some View {
        Rectangle().fill(t.line).frame(height: 1)
    }

    // One metric block: title + 주의(warn, orange) and 위험(crit, red) slider rows.
    private func block(title: String, keyPath: WritableKeyPath<Thresholds, ThresholdPair>,
                       warnRange: ClosedRange<Double>, critRange: ClosedRange<Double>,
                       suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(WattlyFont.at(12.5, weight: .semibold))
                .foregroundStyle(t.text)
            sliderRow(dot: Tokens.statusOrange, label: "주의",
                      binding: binding(keyPath, .warn), range: warnRange, suffix: suffix)
            sliderRow(dot: Tokens.statusRed, label: "위험",
                      binding: binding(keyPath, .crit), range: critRange, suffix: suffix)
        }
    }

    private func sliderRow(dot: Color, label: String, binding: Binding<Double>,
                           range: ClosedRange<Double>, suffix: String) -> some View {
        HStack(spacing: 9) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(label)
                .font(WattlyFont.at(12, weight: .regular))
                .foregroundStyle(t.sub)
                .frame(width: 30, alignment: .leading)
            Slider(value: binding, in: range, step: 1)
                .tint(dot)
            Text("\(Int(binding.wrappedValue))\(suffix)")
                .font(WattlyFont.at(12, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(t.text)
                .frame(width: 40, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    // A clamping `Double` binding into one (metric, control). The setter reassigns the whole
    // `thresholds` so the `@AppStorage` (RawRepresentable) re-encodes; `ThresholdPair.setting`
    // rounds and clamps (warn ≤ crit, edited control wins).
    private func binding(_ keyPath: WritableKeyPath<Thresholds, ThresholdPair>,
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
