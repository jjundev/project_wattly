import SwiftUI

struct ScheduleEditorSheet: View {
    @Environment(\.tokens) private var t
    @Environment(\.dismiss) private var dismiss

    let initialSchedule: BatteryChargingSchedule?
    let onSave: (BatteryChargingSchedule) -> Void

    @State private var name: String = ""
    @State private var hour: Int = 8
    @State private var minute: Int = 0
    @State private var repeatType: Int = 1 // 0: once, 1: daily, 2: weekdays, 3: weekends, 4: custom
    @State private var customDays: Set<ScheduleRepeatRule.Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
    @State private var actionType: Int = 0 // 0: setLimit, 1: startTopUp, 2: pauseCharging
    @State private var targetLimit: Int = 80
    @State private var catchUpMinutes: Int = 30

    init(
        initialSchedule: BatteryChargingSchedule? = nil,
        onSave: @escaping (BatteryChargingSchedule) -> Void
    ) {
        self.initialSchedule = initialSchedule
        self.onSave = onSave
    }

    private var isSaveDisabled: Bool {
        if repeatType == 4 && customDays.isEmpty {
            return true
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(initialSchedule == nil ? "새 예약 일정 추가" : "예약 일정 수정")
                .font(WattlyFont.at(14, weight: .bold))
                .foregroundStyle(t.text)

            // Name
            VStack(alignment: .leading, spacing: 4) {
                Text("일정 이름 (선택)")
                    .font(WattlyFont.at(11, weight: .medium))
                    .foregroundStyle(t.faint)
                TextField("예: 출근 전 완충, 야간 충전 제한", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(WattlyFont.at(12, weight: .regular))
            }

            // Time Picker
            VStack(alignment: .leading, spacing: 6) {
                Text("실행 시각")
                    .font(WattlyFont.at(11, weight: .medium))
                    .foregroundStyle(t.faint)
                HStack(spacing: 8) {
                    Picker("시", selection: $hour) {
                        ForEach(0..<24) { h in Text(String(format: "%02d시", h)).tag(h) }
                    }
                    .labelsHidden()
                    .frame(width: 80)

                    Text(":")
                        .font(WattlyFont.at(14, weight: .bold))
                        .foregroundStyle(t.faint)

                    Picker("분", selection: $minute) {
                        ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { m in
                            Text(String(format: "%02d분", m)).tag(m)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 80)
                }
            }

            // Action
            VStack(alignment: .leading, spacing: 6) {
                Text("동작")
                    .font(WattlyFont.at(11, weight: .medium))
                    .foregroundStyle(t.faint)
                Picker("동작", selection: $actionType) {
                    Text("충전 한도 설정").tag(0)
                    Text("한 번만 100% 완충").tag(1)
                    Text("충전 일시 정지").tag(2)
                }
                .pickerStyle(.segmented)

                if actionType == 0 {
                    HStack {
                        Text("목표 한도: \(targetLimit)%")
                            .font(WattlyFont.at(11.5, weight: .medium))
                            .foregroundStyle(t.sub)
                        Spacer()
                        WattlySegment(
                            selection: $targetLimit,
                            options: [80, 85, 90, 95].map { ($0, "\($0)%") },
                            pillVPadding: 4
                        )
                        .frame(width: 200)
                    }
                    .padding(.top, 4)
                }
            }

            // Repeat Rule
            VStack(alignment: .leading, spacing: 6) {
                Text("반복")
                    .font(WattlyFont.at(11, weight: .medium))
                    .foregroundStyle(t.faint)
                Picker("반복", selection: $repeatType) {
                    Text("매일").tag(1)
                    Text("평일").tag(2)
                    Text("주말").tag(3)
                    Text("요일 선택").tag(4)
                    Text("1회만").tag(0)
                }
                .pickerStyle(.segmented)

                if repeatType == 4 {
                    HStack(spacing: 4) {
                        ForEach(ScheduleRepeatRule.Weekday.allCases, id: \.self) { day in
                            let isSelected = customDays.contains(day)
                            Button {
                                if isSelected {
                                    if customDays.count > 1 { customDays.remove(day) }
                                } else {
                                    customDays.insert(day)
                                }
                            } label: {
                                Text(day.shortLabel)
                                    .font(WattlyFont.at(11, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(isSelected ? Tokens.accent : t.segTrack))
                                    .foregroundStyle(isSelected ? Color.white : t.sub)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 4)
                }
            }

            Spacer()

            // Action Buttons
            HStack {
                Button("취소") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(t.faint)
                Spacer()
                Button("저장") {
                    let repeatRule: ScheduleRepeatRule
                    switch repeatType {
                    case 0: repeatRule = .once(Date())
                    case 1: repeatRule = .daily
                    case 2: repeatRule = .weekdays
                    case 3: repeatRule = .weekends
                    case 4: repeatRule = .custom(customDays)
                    default: repeatRule = .daily
                    }

                    let action: ScheduleAction
                    switch actionType {
                    case 0: action = .setLimit(percentage: targetLimit)
                    case 1: action = .startTopUp
                    case 2: action = .pauseCharging
                    default: action = .setLimit(percentage: 80)
                    }

                    let schedule = BatteryChargingSchedule(
                        id: initialSchedule?.id ?? UUID(),
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        isEnabled: initialSchedule?.isEnabled ?? true,
                        time: ScheduleTime(hour: hour, minute: minute),
                        repeatRule: repeatRule,
                        action: action,
                        catchUpPolicy: .executeIfWithin(minutes: catchUpMinutes),
                        createdAt: initialSchedule?.createdAt ?? Date(),
                        lastTriggeredAt: initialSchedule?.lastTriggeredAt
                    )
                    onSave(schedule)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.accent)
                .disabled(isSaveDisabled)
            }
        }
        .padding(18)
        .frame(width: 360, height: 420)
        .background(t.cardBg)
        .onAppear {
            if let initial = initialSchedule {
                name = initial.name
                hour = initial.time.hour
                minute = initial.time.minute
                switch initial.repeatRule {
                case .once: repeatType = 0
                case .daily: repeatType = 1
                case .weekdays: repeatType = 2
                case .weekends: repeatType = 3
                case .custom(let set):
                    repeatType = 4
                    customDays = set
                }
                switch initial.action {
                case .setLimit(let pct):
                    actionType = 0
                    targetLimit = pct
                case .startTopUp:
                    actionType = 1
                case .pauseCharging:
                    actionType = 2
                }
                if case .executeIfWithin(let mins) = initial.catchUpPolicy {
                    catchUpMinutes = mins
                }
            }
        }
    }
}
