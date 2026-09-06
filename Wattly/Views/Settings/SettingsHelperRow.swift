import SwiftUI
import AppKit

struct SettingsHelperRow: View {
    @Environment(\.tokens) private var t
    @Environment(\.locale) private var locale

    let coordinator: HelperHealthCoordinator
    var hasFan: Bool = true
    let onReapplySettings: @MainActor () async -> Void

    @State private var isDiagnosticsPopoverPresented = false
    @State private var isReinstallConfirmPresented = false
    @State private var isOwnershipTransferConfirmPresented = false
    @State private var errorMessage: String?

    init(
        coordinator: HelperHealthCoordinator,
        hasFan: Bool = true,
        onReapplySettings: @escaping @MainActor () async -> Void
    ) {
        self.coordinator = coordinator
        self.hasFan = hasFan
        self.onReapplySettings = onReapplySettings
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                SettingsRowTitle("시스템 도우미")
                HStack(spacing: 6) {
                    statusSymbol
                    statusLabel
                    infoButton
                }
            }

            Spacer(minLength: 8)

            actionButton
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .task {
            await coordinator.checkHealth()
        }
        .alert("시스템 도우미 재설치", isPresented: $isReinstallConfirmPresented) {
            Button("재설치", role: .none) {
                triggerReinstall(transferringOwnership: false)
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("시스템 도우미를 재설치하고 서비스를 다시 시작합니다. 관리자 암호 입력이 필요합니다.")
        }
        .alert("소유권 이전 및 재설치", isPresented: $isOwnershipTransferConfirmPresented) {
            Button("소유권 이전", role: .destructive) {
                triggerReinstall(transferringOwnership: true)
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("다른 사용자가 설치한 시스템 도우미를 현재 사용자로 이전하고 재설치합니다.")
        }
        .alert("도우미 작업 실패", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Status Badge & Labels

    @ViewBuilder
    private var statusSymbol: some View {
        switch coordinator.state {
        case .checking, .installing:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 10, height: 10)
        case .running:
            Circle().fill(Tokens.statusGreen).frame(width: 7, height: 7)
        case .updateAvailable:
            Circle().fill(Tokens.accent).frame(width: 7, height: 7)
        case .ownershipMismatch:
            Circle().fill(Tokens.statusOrange).frame(width: 7, height: 7)
        case .notInstalled, .unavailable:
            Circle().fill(Tokens.statusRed).frame(width: 7, height: 7)
        }
    }

    private var statusLabel: some View {
        Text(statusText)
            .font(WattlyFont.at(11.5, weight: .regular))
            .foregroundStyle(t.faint)
    }

    private var statusText: String {
        switch coordinator.state {
        case .checking:
            String(localized: "확인 중…")
        case .installing:
            String(localized: "도우미 설치 중…")
        case .running:
            String(localized: "정상 작동 중")
        case .updateAvailable:
            String(localized: "업데이트 필요")
        case .notInstalled:
            String(localized: "미설치")
        case .unavailable:
            String(localized: "응답 없음")
        case .ownershipMismatch:
            String(localized: "다른 사용자 소유")
        }
    }

    private var infoButton: some View {
        Button {
            isDiagnosticsPopoverPresented = true
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(t.faint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey("도우미 진단 세부 정보 보기")))
        .popover(isPresented: $isDiagnosticsPopoverPresented, arrowEdge: .bottom) {
            diagnosticsPopover
        }
    }

    // MARK: - Action Button

    @ViewBuilder
    private var actionButton: some View {
        switch coordinator.state {
        case .installing, .checking:
            EmptyView()

        case .running:
            Button {
                isReinstallConfirmPresented = true
            } label: {
                Text("재설치…")
                    .font(WattlyFont.at(12, weight: .medium))
                    .foregroundStyle(t.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.segTrack))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.rowBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)

        case .updateAvailable:
            Button {
                triggerReinstall(transferringOwnership: false)
            } label: {
                Text("도우미 업데이트")
                    .font(WattlyFont.at(12, weight: .medium))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.accent))
            }
            .buttonStyle(.plain)

        case .notInstalled:
            Button {
                triggerReinstall(transferringOwnership: false)
            } label: {
                Text("도우미 설치")
                    .font(WattlyFont.at(12, weight: .medium))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.accent))
            }
            .buttonStyle(.plain)

        case .unavailable:
            Button {
                triggerReinstall(transferringOwnership: false)
            } label: {
                Text("도우미 복구")
                    .font(WattlyFont.at(12, weight: .medium))
                    .foregroundStyle(t.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.segTrack))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.rowBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)

        case .ownershipMismatch:
            Button {
                isOwnershipTransferConfirmPresented = true
            } label: {
                Text("소유권 가져오기")
                    .font(WattlyFont.at(12, weight: .medium))
                    .foregroundStyle(t.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.segTrack))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.rowBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Diagnostics Popover

    private var diagnosticsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("시스템 도우미 진단 정보")
                .font(WattlyFont.at(13, weight: .semibold))
                .foregroundStyle(t.text)

            VStack(alignment: .leading, spacing: 6) {
                diagnosticLine(label: "Mach 서비스", value: FanControlXPC.machService)
                diagnosticLine(label: "도우미 경로", value: FanControlXPC.daemonPath)
                diagnosticLine(
                    label: "LaunchDaemon 소유자",
                    value: ownershipDescription(coordinator.diagnostics.installedOwnership)
                )
                diagnosticLine(
                    label: "배터리 XPC 상태",
                    value: coordinator.diagnostics.batteryMode.rawValue
                )
                diagnosticLine(
                    label: "팬 XPC 상태",
                    value: hasFan ? coordinator.diagnostics.fanMode.rawValue : String(localized: "미지원 (팬 없음)")
                )
                diagnosticLine(
                    label: "바이너리 일치",
                    value: binaryMatchDescription(coordinator.diagnostics.binaryMatch)
                )
            }
            .font(WattlyFont.at(11, weight: .regular))

            Divider()

            HStack(spacing: 4) {
                Text("확인 시각:")
                    .font(WattlyFont.at(10, weight: .regular))
                    .foregroundStyle(t.faint)
                Text(formattedDate(coordinator.diagnostics.checkedAt))
                    .font(WattlyFont.at(10, weight: .regular))
                    .foregroundStyle(t.faint)
                Spacer()
                Button {
                    Task { await coordinator.checkHealth() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.clockwise")
                        Text("새로고침")
                    }
                    .font(WattlyFont.at(10.5, weight: .medium))
                    .foregroundStyle(t.sub)
                }
                .buttonStyle(.plain)
                .disabled(coordinator.state == .installing)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func diagnosticLine(label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .foregroundStyle(t.faint)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .foregroundStyle(t.text)
                .textSelection(.enabled)
        }
    }

    private func ownershipDescription(_ ownership: FanHelperInstaller.InstalledOwnership) -> String {
        switch ownership {
        case .notInstalled: return String(localized: "미설치")
        case .owner(let uid): return "UID \(uid) (\(String(localized: "현재:")) \(coordinator.diagnostics.currentUID))"
        case .invalidMetadata: return String(localized: "메타데이터 오류")
        }
    }

    private func binaryMatchDescription(_ match: Bool?) -> String {
        switch match {
        case true: return String(localized: "최신 바이너리와 일치")
        case false: return String(localized: "업데이트 필요 (불일치)")
        case nil: return String(localized: "확인 불가")
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = locale
        df.timeStyle = .medium
        df.dateStyle = .none
        return df.string(from: date)
    }

    private var targetWindow: NSWindow? {
        if let keyWindow = NSApp.keyWindow {
            return keyWindow.sheetParent ?? keyWindow
        }
        return NSApp.windows.first(where: { $0.canBecomeKey && $0.isVisible })
    }

    private func isCancellation(_ error: Error) -> Bool {
        if let installError = error as? FanHelperInstaller.InstallError, installError.isCancellation {
            return true
        }
        let desc = error.localizedDescription
        return desc.contains("-128") || desc.localizedCaseInsensitiveContains("canceled") || desc.localizedCaseInsensitiveContains("cancelled")
    }

    private func triggerReinstall(transferringOwnership: Bool) {
        let window = targetWindow
        Task {
            do {
                try await coordinator.reinstall(
                    transferringOwnership: transferringOwnership,
                    window: window,
                    reapplySettings: onReapplySettings
                )
            } catch {
                if isCancellation(error) {
                    return
                }
                errorMessage = error.localizedDescription
            }
        }
    }
}
