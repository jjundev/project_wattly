import SwiftUI

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
        // Gate memory process enumeration to when this panel is open AND the memory
        // card is expanded (issue 05 §M11/M18). The panel unmounts on close (issue
        // 03 render-stop), so .onDisappear reliably turns it off.
        .task(id: memExpanded) { monitor.setMemoryProcessEnumeration(memExpanded) }
        .onDisappear { monitor.setMemoryProcessEnumeration(false) }
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
                           activeBg: .clear) { openSettings() }
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
                        state: smoothedState(for: card),
                        historyValues: smoothedHistory(for: card),
                        isExpanded: expanded.contains(card),
                        onToggleExpand: (card == .cpu || card == .mem) ? { toggleExpand(card) } : nil
                    )
                }
            }
        }
        .padding(.vertical, 1)
    }

    /// Power and battery cards apply display smoothing (shared `powerSmoothed` toggle);
    /// every other card passes its raw state/history straight through.
    private func smoothedState(for card: CardKind) -> MetricState {
        switch card {
        case .power:   return monitor.powerCardState(smoothed: powerSmoothed)
        case .battery: return monitor.batteryCardState(smoothed: powerSmoothed)
        default:       return monitor.cardState(card)
        }
    }

    private func smoothedHistory(for card: CardKind) -> [Double] {
        switch card {
        case .power:   return monitor.powerHistoryValues(smoothed: powerSmoothed)
        case .battery: return monitor.batteryHistoryValues(smoothed: powerSmoothed)
        default:       return monitor.history[card]?.values ?? []
        }
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
