import Foundation

/// Pure adaptive-polling policy (issue 09). No SwiftUI, no I/O — the cadence and
/// active-provider decisions live here as deterministic functions so they're table-tested
/// directly (issue 18); `SystemMonitor` only applies the result.

/// The poll interval for one cycle. Only `.auto` adapts to runtime state: an open panel
/// means the user is watching (1 s live view — `Task.sleep` `tolerance` coalesces toward
/// the prototype's "1–2초"), while a closed panel drops to 2 s when the menubar has live
/// content (text or Kinetic Notch motion) and 5 s when it doesn't (issue 09 §1 + prototype hint copy). The fixed
/// 1/2/5 settings are constant: the user pinned a cadence, so it doesn't idle down.
func resolvePollInterval(setting: PollInterval,
                         panelVisible: Bool,
                         menubarLiveContentEnabled: Bool) -> Duration {
    switch setting {
    case .s1: return .seconds(1)
    case .s2: return .seconds(2)
    case .s5: return .seconds(5)
    case .auto:
        if panelVisible { return .seconds(1) }
        return menubarLiveContentEnabled ? .seconds(2) : .seconds(5)
    }
}

/// Which providers must actually be polled: the union of the providers feeding a shown
/// card and the providers the menubar still needs (issue 09 §3 — hidden metrics drop out
/// of the poll). With every card shown (the default) this is the full provider set, so the
/// filter is a no-op until a card is hidden (issue 13's visibility toggles). `menubarNeeds`
/// is passed in rather than derived here, so issue 14's multi-metric menubar can widen it
/// without touching this function.
func activeProviders(shown: Set<CardKind>, menubarNeeds: Set<CardKind>) -> Set<ProviderKind> {
    Set(shown.union(menubarNeeds).map(\.provider))
}

private func baseProviderIntervals(mode: PowerMode,
                                   setting: PollInterval,
                                   panelVisible: Bool,
                                   menubarLiveContentEnabled: Bool,
                                   active: Set<ProviderKind>,
                                   menubarNeeds: Set<CardKind>,
                                   heroCard: CardKind? = nil,
                                   isACConnected: Bool = false) -> [ProviderKind: Duration] {
    if setting != .auto {
        let interval: Duration = switch setting {
        case .s1: .seconds(1)
        case .s2: .seconds(2)
        case .s5: .seconds(5)
        case .auto: preconditionFailure("handled above")
        }
        return Dictionary(uniqueKeysWithValues: active.map { ($0, interval) })
    }

    if mode == .performance {
        if panelVisible {
            var open: [ProviderKind: Duration] = [
                .cpu: .seconds(1), .gpu: .seconds(1), .power: .seconds(1), .temperature: .seconds(1),
                .memory: .seconds(3), .battery: .seconds(3), .fan: .seconds(3),
            ]
            if let heroCard {
                open[heroCard.provider] = .seconds(1)
            }
            return open.filter { active.contains($0.key) }
        }

        let fastInterval: Duration = if menubarLiveContentEnabled {
            isACConnected ? .seconds(2) : .seconds(3)
        } else {
            isACConnected ? .seconds(3) : .seconds(5)
        }
        let slowInterval: Duration = if menubarLiveContentEnabled {
            isACConnected ? .seconds(5) : .seconds(10)
        } else {
            .seconds(10)
        }

        var result: [ProviderKind: Duration] = [:]
        for kind in active {
            switch kind {
            case .cpu, .gpu, .power, .temperature:
                result[kind] = fastInterval
            case .memory, .battery, .fan:
                result[kind] = slowInterval
            }
        }
        return result
    }

    if panelVisible {
        var open: [ProviderKind: Duration] = [
            .cpu: .seconds(1), .gpu: .seconds(1), .power: .seconds(1), .temperature: .seconds(2),
            .memory: .seconds(5), .battery: .seconds(5), .fan: .seconds(5),
        ]
        if let heroCard {
            open[heroCard.provider] = .seconds(1)
        }
        return open.filter { active.contains($0.key) }
    }

    guard menubarLiveContentEnabled else { return [:] }
    let menuProviders = Set(menubarNeeds.map(\.provider)).intersection(active)
    var result: [ProviderKind: Duration] = [:]
    for kind in menuProviders {
        switch kind {
        case .cpu, .gpu, .power, .temperature:
            result[kind] = .seconds(2)
        case .memory, .battery, .fan:
            result[kind] = .seconds(5)
        }
    }
    return result
}

/// 폴링 간격의 공개 진입점. `baseProviderIntervals`의 결과에 설정 창의 수요를 겹쳐 놓는다.
///
/// 설정 › 배터리는 강제 방전 중 실측 전력을 보여준다. 그런데 팝오버가 닫힌 기본(eco) 상태에서
/// 배터리 provider는 메뉴바가 배터리를 쓰지 않는 한 **한 번도 읽히지 않는다** — 그대로 화면에
/// 올리면 몇 시간 묵은 표본을 실시간이라고 부르게 된다. performance 모드에서도 닫힌 팝오버는
/// 5–10초라 방전 추적에는 너무 느리다.
///
/// `active`에 `.battery`가 없어도 넣는 이유는, 배터리 **카드**를 숨긴 사용자도 설정 화면은 열기
/// 때문이다. 카드 표시 여부와 이 화면의 필요는 별개다. 이미 더 빠른 간격이 잡혀 있으면
/// (팝오버가 함께 열려 있는 경우) 그쪽을 존중한다.
func providerIntervals(mode: PowerMode,
                       setting: PollInterval,
                       panelVisible: Bool,
                       menubarLiveContentEnabled: Bool,
                       active: Set<ProviderKind>,
                       menubarNeeds: Set<CardKind>,
                       heroCard: CardKind? = nil,
                       isACConnected: Bool = false,
                       settingsBatteryLive: Bool = false) -> [ProviderKind: Duration] {
    var result = baseProviderIntervals(mode: mode, setting: setting, panelVisible: panelVisible,
                                       menubarLiveContentEnabled: menubarLiveContentEnabled,
                                       active: active, menubarNeeds: menubarNeeds,
                                       heroCard: heroCard, isACConnected: isACConnected)
    guard settingsBatteryLive else { return result }
    let demand = Duration.seconds(2)
    result[.battery] = result[.battery].map { min($0, demand) } ?? demand
    return result
}

func dueProviders(intervals: [ProviderKind: Duration],
                  lastRead: [ProviderKind: ContinuousClock.Instant],
                  now: ContinuousClock.Instant,
                  force: Bool) -> Set<ProviderKind> {
    Set(intervals.compactMap { kind, interval in
        guard force || lastRead[kind].map({ seconds(from: $0, to: now) >= seconds(interval) }) != false
        else { return nil }
        return kind
    })
}

func nextPollDelay(intervals: [ProviderKind: Duration],
                   lastRead: [ProviderKind: ContinuousClock.Instant],
                   now: ContinuousClock.Instant,
                   fallback: Duration = .seconds(5)) -> Duration {
    intervals.reduce(fallback) { next, entry in
        guard let last = lastRead[entry.key] else { return .zero }
        let remaining = max(0, seconds(entry.value) - seconds(from: last, to: now))
        return min(next, .seconds(remaining))
    }
}

func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: end)
    return Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
}

private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
}
