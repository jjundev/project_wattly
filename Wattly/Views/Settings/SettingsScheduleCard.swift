import SwiftUI

struct SettingsScheduleCard: View {
    @Environment(\.tokens) private var t
    @Environment(\.locale) private var locale

    @Bindable var coordinator: BatteryScheduleCoordinator
    @AppStorage(StorageKey.batteryScheduleNotificationsEnabled) private var notificationsEnabled = Defaults.batteryScheduleNotificationsEnabled

    @State private var isEditorPresented = false
    @State private var editingSchedule: BatteryChargingSchedule? = nil
    @State private var isHistoryPresented = false

    var body: some View {
        SettingsCard {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    SettingsRowTitle("예약 충전")
                    Text(LocalizedStringKey("지정한 시각과 요일에 맞춰 충전 한도 변경 또는 100% 완충을 자동 실행합니다."))
                        .font(WattlyFont.at(10.5, weight: .regular))
                        .foregroundStyle(t.faint)
                }
                Spacer()
                Button {
                    editingSchedule = nil
                    isEditorPresented = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                        Text(LocalizedStringKey("일정 추가"))
                            .font(WattlyFont.at(11.5, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.segTrack))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.rowBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(14)

            if coordinator.schedules.isEmpty {
                Text(LocalizedStringKey("등록된 예약 충전 일정이 없습니다."))
                    .font(WattlyFont.at(11, weight: .regular))
                    .foregroundStyle(t.faint)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            } else {
                VStack(spacing: 0) {
                    ForEach(coordinator.schedules) { schedule in
                        Rectangle().fill(t.line).frame(height: 1)
                        scheduleRow(schedule)
                    }
                }
            }

            Rectangle().fill(t.line).frame(height: 1)

            HStack {
                Toggle(isOn: $notificationsEnabled) {
                    Text(LocalizedStringKey("예약 실행 완료 시 알림"))
                        .font(WattlyFont.at(11.5, weight: .regular))
                        .foregroundStyle(t.sub)
                }
                .toggleStyle(.checkbox)

                Spacer()

                Button {
                    isHistoryPresented = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10, weight: .medium))
                        Text(String(format: String(localized: "실행 이력 (%lld)", locale: locale), locale: locale, Int64(coordinator.history.count)))
                            .font(WattlyFont.at(11, weight: .medium))
                    }
                    .foregroundStyle(t.faint)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isHistoryPresented, arrowEdge: .bottom) {
                    historyPopover
                }
            }
            .padding(12)
        }
        .sheet(isPresented: $isEditorPresented) {
            ScheduleEditorSheet(initialSchedule: editingSchedule) { saved in
                if editingSchedule != nil {
                    coordinator.updateSchedule(saved)
                } else {
                    coordinator.addSchedule(saved)
                }
            }
        }
    }

    private func scheduleRow(_ schedule: BatteryChargingSchedule) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { schedule.isEnabled },
                set: { coordinator.toggleSchedule(id: schedule.id, isEnabled: $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .scaleEffect(0.7)
            .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(schedule.time.formattedText)
                        .font(WattlyFont.at(14, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(schedule.isEnabled ? t.text : t.faint)

                    Text(schedule.action.summary(locale: locale))
                        .font(WattlyFont.at(11.5, weight: .semibold))
                        .foregroundStyle(schedule.isEnabled ? Tokens.accent : t.faint)
                }

                HStack(spacing: 6) {
                    if !schedule.name.isEmpty {
                        Text(schedule.name)
                            .font(WattlyFont.at(10.5, weight: .medium))
                            .foregroundStyle(t.sub)
                    }
                    Text("•")
                        .font(WattlyFont.at(10, weight: .regular))
                        .foregroundStyle(t.faint)
                    Text(repeatSummary(schedule.repeatRule, locale: locale))
                        .font(WattlyFont.at(10.5, weight: .regular))
                        .foregroundStyle(t.faint)
                }
            }

            Spacer()

            Button {
                editingSchedule = schedule
                isEditorPresented = true
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(t.faint)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)

            Button {
                coordinator.deleteSchedule(id: schedule.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var historyPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(LocalizedStringKey("예약 충전 실행 이력"))
                    .font(WattlyFont.at(12.5, weight: .bold))
                    .foregroundStyle(t.text)
                Spacer()
                if !coordinator.history.isEmpty {
                    Button {
                        coordinator.clearHistory()
                    } label: {
                        Text(LocalizedStringKey("기록 지우기"))
                    }
                    .font(WattlyFont.at(10.5, weight: .medium))
                    .foregroundStyle(t.faint)
                    .buttonStyle(.plain)
                }
            }

            if coordinator.history.isEmpty {
                Text(LocalizedStringKey("최근 실행된 이력이 없습니다."))
                    .font(WattlyFont.at(11, weight: .regular))
                    .foregroundStyle(t.faint)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(coordinator.history) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(entry.scheduleName)
                                        .font(WattlyFont.at(11, weight: .semibold))
                                        .foregroundStyle(t.text)
                                    Spacer()
                                    statusBadge(entry.status)
                                }
                                HStack {
                                    Text(entry.actionSummary)
                                        .font(WattlyFont.at(10.5, weight: .regular))
                                        .foregroundStyle(t.sub)
                                    Spacer()
                                    Text(entry.timestamp, style: .time)
                                        .font(WattlyFont.at(10, weight: .regular))
                                        .foregroundStyle(t.faint)
                                }
                            }
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 4).fill(t.segTrack))
                        }
                    }
                }
                .frame(height: 180)
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(t.cardBg)
    }

    @ViewBuilder
    private func statusBadge(_ status: BatteryScheduleLogEntry.Status) -> some View {
        switch status {
        case .success:
            Text(status.localizedDescription)
                .font(WattlyFont.at(9.5, weight: .semibold))
                .foregroundStyle(Tokens.statusGreen)
        case .skipped(let reason):
            Text(reason.localizedDescription)
                .font(WattlyFont.at(9.5, weight: .medium))
                .foregroundStyle(Tokens.statusOrange)
        case .failed(let err):
            Text(String(format: String(localized: "실패: %@", locale: locale), locale: locale, err))
                .font(WattlyFont.at(9.5, weight: .medium))
                .foregroundStyle(.red)
        }
    }

    private func repeatSummary(_ rule: ScheduleRepeatRule, locale: Locale = Locale(identifier: "ko")) -> String {
        switch rule {
        case .once: return String(localized: "1회", locale: locale)
        case .daily: return String(localized: "매일", locale: locale)
        case .weekdays: return String(localized: "평일", locale: locale)
        case .weekends: return String(localized: "주말", locale: locale)
        case .custom(let set):
            return set.sorted().map { $0.shortLabel(locale: locale) }.joined(separator: "·")
        }
    }
}
