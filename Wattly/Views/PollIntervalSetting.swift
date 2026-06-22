import SwiftUI

/// The "업데이트 주기" settings control (issue 09 §1/§4) — the 자동/1/2/5 segment plus the
/// prototype's verbatim hint copy. Self-contained: it writes `@AppStorage(pollInterval)`,
/// which `PollPolicyBridge` observes and pushes to the monitor. Temporarily mounted in the
/// skeleton `SettingsView`; issue 13 relocates it into the full settings layout.
struct PollIntervalSetting: View {
    @Environment(\.tokens) private var t
    @AppStorage(StorageKey.pollInterval) private var pollInterval: PollInterval = Defaults.pollInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("업데이트 주기")
                .font(WattlyFont.at(11, weight: .bold))
                .tracking(0.33)
                .foregroundStyle(t.faint)

            VStack(alignment: .leading, spacing: 10) {
                Picker("업데이트 주기", selection: $pollInterval) {
                    ForEach(PollInterval.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                Text("자동: 패널 열림 1–2초, 닫힘 5초(텍스트 ON 시 2초)로 낮춰 배터리를 아낍니다.")
                    .font(WattlyFont.at(11.5, weight: .regular))
                    .foregroundStyle(t.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(t.rowBg))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(t.rowBorder, lineWidth: 1))
        }
    }
}
