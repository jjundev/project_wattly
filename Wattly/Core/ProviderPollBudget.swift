import Foundation

/// Pure provider/subpath polling budget. It decides *what* should be read and
/// how often; `SystemMonitor` owns the actual scheduler and provider calls.
enum PollDecision: Sendable, Equatable {
    case due(Duration)
    case suspended
}

struct ProviderPollBudgetInput: Sendable, Equatable {
    var setting: PollInterval
    var panelVisible: Bool
    var activeProviders: Set<ProviderKind>
    var shownCards: Set<CardKind>
    var menubarMetrics: Set<CardKind>
    var warmupProviders: Set<ProviderKind>
    var accessibilityNeedsMetrics: Bool

    init(setting: PollInterval,
         panelVisible: Bool,
         activeProviders: Set<ProviderKind>,
         shownCards: Set<CardKind>,
         menubarMetrics: Set<CardKind>,
         warmupProviders: Set<ProviderKind> = [],
         accessibilityNeedsMetrics: Bool = true) {
        self.setting = setting
        self.panelVisible = panelVisible
        self.activeProviders = activeProviders
        self.shownCards = shownCards
        self.menubarMetrics = menubarMetrics
        self.warmupProviders = warmupProviders
        self.accessibilityNeedsMetrics = accessibilityNeedsMetrics
    }
}

/// Headline/provider cadence. Fixed settings pin the headline cadence; expensive
/// details still have their own minimum lane elsewhere.
func providerPollDecision(kind: ProviderKind, input: ProviderPollBudgetInput) -> PollDecision {
    guard input.activeProviders.contains(kind) else { return .suspended }
    switch input.setting {
    case .s1: return .due(.seconds(1))
    case .s2: return .due(.seconds(2))
    case .s5: return .due(.seconds(5))
    case .auto:
        if input.panelVisible { return .due(.seconds(1)) }
        if input.warmupProviders.contains(kind) { return .due(.seconds(1)) }
        return providerHasMenubarSurface(kind, metrics: input.menubarMetrics)
            ? .due(.seconds(2))
            : .due(.seconds(5))
    }
}

/// Whether there is no visible, menubar, or accessibility surface that needs live
/// data. Only this state may park the scheduler.
func shouldParkScheduler(input: ProviderPollBudgetInput) -> Bool {
    input.activeProviders.isEmpty && input.shownCards.isEmpty
        && (!input.accessibilityNeedsMetrics || input.menubarMetrics.isEmpty)
}

/// Expensive per-process lanes are never allowed to run faster than this, even
/// under a fixed 1 s headline setting.
func processDetailIntervalSeconds() -> Double { 5.0 }
func processDetailInterval() -> Duration { .seconds(Int(processDetailIntervalSeconds())) }

func shouldRunProcessDetailSweep(elapsedSeconds: Double?) -> Bool {
    guard let elapsedSeconds else { return true }
    return !(elapsedSeconds > 0 && elapsedSeconds < processDetailIntervalSeconds())
}

private func providerHasMenubarSurface(_ kind: ProviderKind, metrics: Set<CardKind>) -> Bool {
    metrics.contains { $0.provider == kind }
}
