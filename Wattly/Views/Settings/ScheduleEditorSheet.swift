import SwiftUI

struct ScheduleEditorSheet: View {
    @Environment(\.tokens) private var t
    @Environment(\.locale) private var locale
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
    @AppStorage(StorageKey.batteryAutoDischargeEnabled) private var autoDischargeEnabled = Defaults.batteryAutoDischargeEnabled

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
                        ForEach(0..<24) { h in Text(String(format: String(localized: "%02d시", locale: locale), locale: locale, h)).tag(h) }
                    }
                    .labelsHidden()
                    .frame(width: 80)

                    Text(":")
                        .font(WattlyFont.at(14, weight: .bold))
                        .foregroundStyle(t.faint)

                    Picker("분", selection: $minute) {
                        ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { m in
                            Text(String(format: String(localized: "%02d분", locale: locale), locale: locale, m)).tag(m)
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

                WattlySegment(
                    selection: $actionType,
                    options: [
                        (0, "충전 한도 설정"),
                        (1, "100% 완충"),
                        (2, "충전 일시 정지")
                    ],
                    fontSize: 11.5,
                    pillVPadding: 5
                )

                // "충전 일시 정지"는 한도를 내리는 것으로 구현돼 있어서, 자동 방전이 켜져
                // 있으면 그 한도 변경이 곧 강제 방전이 된다. 저장하기 전에 알린다.
                // 어떤 동작이 경고 대상인지는 코디네이터가 정한다 — 이 뷰는 선택된 동작을
                // 그대로 넘기기만 한다.
                let selectedAction: ScheduleAction = switch actionType {
                case 1: .startTopUp
                case 2: .pauseCharging
                default: .setLimit(percentage: targetLimit)
                }
                if let warning = BatteryScheduleCoordinator.autoDischargeWarning(
                    action: selectedAction,
                    isAutoDischargeEnabled: autoDischargeEnabled,
                    locale: locale) {
                    Text(verbatim: warning)
                        .font(WattlyFont.at(10.5, weight: .regular))
                        .foregroundStyle(Tokens.statusOrange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }

                if actionType == 0 {
                    HStack {
                        Text(String(format: String(localized: "목표 한도: %lld%%", locale: locale), locale: locale, Int64(targetLimit)))
                            .font(WattlyFont.at(11.5, weight: .medium))
                            .foregroundStyle(t.sub)
                        Spacer()
                        WattlySegment(
                            selection: $targetLimit,
                            options: [80, 85, 90, 95].map { ($0, "\($0)%") },
                            fontSize: 11.5,
                            pillVPadding: 4
                        )
                        .frame(width: 190)
                    }
                    .padding(.top, 4)
                }
            }

            // Repeat Rule
            VStack(alignment: .leading, spacing: 6) {
                Text("반복")
                    .font(WattlyFont.at(11, weight: .medium))
                    .foregroundStyle(t.faint)

                WattlySegment(
                    selection: $repeatType,
                    options: [
                        (1, "매일"),
                        (2, "평일"),
                        (3, "주말"),
                        (4, "요일 선택"),
                        (0, "1회만")
                    ],
                    fontSize: 11.5,
                    pillVPadding: 5
                )

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
                                Text(day.shortLabel(locale: locale))
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
                Button {
                    dismiss()
                } label: {
                    Text(LocalizedStringKey("취소"))
                }
                .buttonStyle(.plain)
                .foregroundStyle(t.faint)

                Spacer()

                Button {
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
                } label: {
                    Text(LocalizedStringKey("저장"))
                }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.accent)
                .disabled(isSaveDisabled)
            }
        }
        .padding(18)
        .frame(width: 380, height: 430)
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
