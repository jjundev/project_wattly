import SwiftUI

/// Empty skeleton — the real seven-section settings window is issue 13. Present
/// here only so the `Settings` scene and `openSettings()` wiring exist.
struct SettingsView: View {
    @Environment(\.tokens) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Wattly 설정")
                .font(WattlyFont.at(13, weight: .semibold))
                .foregroundStyle(t.text)
            Text("설정 UI는 이슈 13에서 구현됩니다 (업데이트 주기는 이슈 09에서 먼저 제공).")
                .font(WattlyFont.at(12, weight: .regular))
                .foregroundStyle(t.sub)
            PollIntervalSetting()
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 440, height: 280, alignment: .topLeading)
        .background(t.settingsBg)
    }
}
