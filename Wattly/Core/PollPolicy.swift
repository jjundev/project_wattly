import Foundation

/// Pure adaptive-polling policy (issue 09). No SwiftUI, no I/O — the cadence and
/// active-provider decisions live here as deterministic functions so they're table-tested
/// directly (issue 18); `SystemMonitor` only applies the result.

/// The poll interval for one cycle. Only `.auto` adapts to runtime state: an open panel
/// means the user is watching (1 s live view — `Task.sleep` `tolerance` coalesces toward
/// the prototype's "1–2초"), while a closed panel drops to 2 s when the menubar still
/// shows a number and 5 s when it doesn't (issue 09 §1 + prototype hint copy). The fixed
/// 1/2/5 settings are constant: the user pinned a cadence, so it doesn't idle down.
func resolvePollInterval(setting: PollInterval,
                         panelVisible: Bool,
                         menubarTextEnabled: Bool) -> Duration {
    switch setting {
    case .s1: return .seconds(1)
    case .s2: return .seconds(2)
    case .s5: return .seconds(5)
    case .auto:
        if panelVisible { return .seconds(1) }
        return menubarTextEnabled ? .seconds(2) : .seconds(5)
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

func providerIntervals(mode: PowerMode,
                       setting: PollInterval,
                       panelVisible: Bool,
                       menubarTextEnabled: Bool,
                       active: Set<ProviderKind>,
                       menubarNeeds: Set<CardKind>) -> [ProviderKind: Duration] {
    if mode == .performance {
        let interval = resolvePollInterval(setting: setting, panelVisible: panelVisible,
                                           menubarTextEnabled: menubarTextEnabled)
        return Dictionary(uniqueKeysWithValues: active.map { ($0, interval) })
    }
    if setting != .auto {
        let interval: Duration = switch setting {
        case .s1: .seconds(1)
        case .s2: .seconds(2)
        case .s5: .seconds(5)
        case .auto: preconditionFailure("handled above")
        }
        return Dictionary(uniqueKeysWithValues: active.map { ($0, interval) })
    }
    if panelVisible {
        let open: [ProviderKind: Duration] = [
            .cpu: .seconds(1), .power: .seconds(1), .temperature: .seconds(2),
            .memory: .seconds(5), .battery: .seconds(5),
        ]
        return open.filter { active.contains($0.key) }
    }
    guard menubarTextEnabled else { return [:] }
    let menuProviders = Set(menubarNeeds.map(\.provider))
    return Dictionary(uniqueKeysWithValues:
        menuProviders.intersection(active).map { ($0, .seconds(2)) })
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
                   housekeeping: Duration = .seconds(30)) -> Duration {
    intervals.reduce(housekeeping) { next, entry in
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
