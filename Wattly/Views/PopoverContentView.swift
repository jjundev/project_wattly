import SwiftUI
import AppKit

/// The popover panel (prototype lines 62–174), mode A. Deliberately host-agnostic
/// (L2): no `MenuBarExtra` knowledge, so an AppKit `NSPanel` could host it
/// unchanged. The connector-arrow triangle is cosmetic and omitted (issue 02 memo).
struct PopoverContentView: View {
    let monitor: SystemMonitor

    @Environment(\.tokens) private var t
    @Environment(\.openSettings) private var openSettings
    @AppStorage(StorageKey.cardOrder) private var cardOrder = Defaults.cardOrder
    /// Power-type cards (프로세서 전력 + 배터리): show the EMA-smoothed value/sparkline
    /// (steady, tracks the real sustained draw) vs the raw 1-second reading. Default on.
    @AppStorage(StorageKey.powerSmoothed) private var powerSmoothed = Defaults.powerSmoothed
    /// Warn/crit thresholds (issue 10). Read here (the card composition root) and passed
    /// into each card; an `@AppStorage` change re-renders the cards, so a slider edit recolors
    /// the panel live with no extra observer.
    @AppStorage(StorageKey.thresholds) private var thresholds = Defaults.thresholds

    @State private var editMode = false
    // Persisted across popover opens (#12). @AppStorage can't hold a Set, so it's
    // a sorted CSV of card raw values. Shared by CPU and memory expand state.
    @AppStorage(StorageKey.expandedCards) private var expandedRaw = ""

    private var expanded: Set<CardKind> {
        Set(expandedRaw.split(separator: ",").compactMap { CardKind(rawValue: String($0)) })
    }

    private var memExpanded: Bool { expanded.contains(.mem) }

    var body: some View {
        // No ScrollView here: MenuBarExtra(.window) sizes the window to the
        // content's natural height, and a ScrollView has no intrinsic height so it
        // collapses (empty panel). The panel grows to fit the cards instead.
        // (Scroll-on-overflow for very tall lists is a later refinement.)
        VStack(spacing: 0) {
            header
            cardsStack
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(t.panelBg))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(t.panelBorder, lineWidth: 1))
        .shadow(color: Tokens.shadowFar.color, radius: Tokens.shadowFar.radius, x: 0, y: Tokens.shadowFar.y)
        .shadow(color: Tokens.shadowNear.color, radius: Tokens.shadowNear.radius, x: 0, y: Tokens.shadowNear.y)
        // Panel open/closed drives the adaptive cadence (issue 09): open → 1 s live view,
        // closed → 2–5 s. The panel unmounts on close, so onAppear/onDisappear bracket the
        // open state. (Card visibility is pushed by the always-alive PollPolicyBridge, not
        // here — it must reach the monitor even while this view is unmounted.)
        .onAppear { monitor.setPanelVisible(true) }
        // Gate memory process enumeration to when this panel is open AND the memory card is
        // expanded (issue 05 §M11/M18); .onDisappear reliably turns both off on close.
        .task(id: memExpanded) { monitor.setMemoryProcessEnumeration(memExpanded) }
        .onDisappear {
            monitor.setPanelVisible(false)
            monitor.setMemoryProcessEnumeration(false)
        }
    }

    // MARK: Header (prototype lines 66–72)

    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                LightningGlyph().fill(t.text).frame(width: 14, height: 14)
                Text("Wattly")
                    .font(WattlyFont.at(13, weight: .bold)).tracking(-0.13)
                    .foregroundStyle(t.text)
                StatusDot(color: monitor.aggregateHealthy ? Tokens.statusGreen : Tokens.statusOrange)
                    .padding(.leading, 1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                iconButton("pencil", active: editMode, activeColor: Tokens.accent,
                           activeBg: Tokens.accent.opacity(0.16)) { editMode.toggle() }
                iconButton("gearshape", active: false, activeColor: t.faint,
                           activeBg: .clear) { openSettingsRaised() }
            }
        }
        .padding(EdgeInsets(top: 2, leading: 4, bottom: 12, trailing: 4))
    }

    private func iconButton(_ system: String, active: Bool, activeColor: Color,
                            activeBg: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(active ? activeColor : t.faint)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(active ? activeBg : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(system == "pencil" ? "편집" : "설정")
    }

    /// Open (or focus) the settings window AND raise it above other apps. In an
    /// LSUIElement (accessory) app, `openSettings()` alone only focuses the window
    /// within our app — it doesn't activate us over other apps, so an already-open
    /// window stays hidden behind whatever is frontmost. `openSettings()` first puts
    /// Settings frontmost within the app, then `activate` crosses the app boundary to
    /// pull Wattly (with Settings on top) above everything else. `activate(ignoringOtherApps:)`
    /// is deprecated on macOS 14 but the non-deprecated `activate()` is unreliable at
    /// raising an accessory app over other apps, so we keep it deliberately.
    private func openSettingsRaised() {
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Cards (prototype lines 76–173)

    private var cardsStack: some View {
        VStack(spacing: 8) {
            ForEach(visibleCards) { card in
                HStack(spacing: 5) {
                    if editMode {
                        GripGlyph().frame(width: 14)
                    }
                    MetricCardView(
                        card: card,
                        state: monitor.cardState(card, smoothed: powerSmoothed),
                        historyValues: monitor.historyValues(for: card, smoothed: powerSmoothed),
                        isExpanded: expanded.contains(card),
                        onToggleExpand: card.isExpandable ? { toggleExpand(card) } : nil,
                        thresholds: thresholds
                    )
                }
            }
        }
        .padding(.vertical, 1)
    }

    // MARK: Visibility (prototype `card.visible`, line 638)

    private var visibleCards: [CardKind] {
        cardOrder.cards.filter { monitor.isPresent($0) && isShown($0) }
    }

    private func isShown(_ card: CardKind) -> Bool {
        UserDefaults.standard.object(forKey: StorageKey.show(card)) as? Bool ?? (Defaults.show[card] ?? true)
    }

    private func toggleExpand(_ card: CardKind) {
        var s = expanded
        if s.contains(card) { s.remove(card) } else { s.insert(card) }
        expandedRaw = s.map(\.rawValue).sorted().joined(separator: ",")
    }
}
