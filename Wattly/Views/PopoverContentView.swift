import SwiftUI
import AppKit

/// A card's layout slot captured once at drag start (issue 12). The reorder maps the cursor
/// to one of these static slots, so it never depends on the 1-frame-lagged live frames and
/// always keeps up with the cursor — keeping the drop offset small (no snap).
private struct DragSlot { let card: CardKind; let minY: CGFloat; let height: CGFloat }

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
    /// Edit-mode drag state (issue 12). `draggingCard` drives the 0.45 dim + float, `dragOffset`
    /// makes the dragged card follow the cursor, and `cardFrames` holds each row's layout slot
    /// (in the "cards" space) so a drop can hit-test which card it landed on. A plain
    /// `DragGesture` — NOT `.onDrag`/`.draggable` — because a `MenuBarExtra(.window)` popover
    /// won't start a system drag session, so pasteboard drag-and-drop silently no-ops there.
    @State private var draggingCard: CardKind?
    @State private var dragOffset: CGFloat = 0
    /// How far the dragged card's home slot has moved due to live swaps. The render offset is
    /// `translation − homeShift`, which keeps the card glued to the cursor WITHOUT reading the
    /// (1-frame-lagged) post-swap layout frame — so there's no per-swap stutter.
    @State private var homeShift: CGFloat = 0
    @State private var cardFrames: [CardKind: CGRect] = [:]
    @State private var dragSlots: [DragSlot] = []   // static slot snapshot for the active drag
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                           activeBg: Tokens.accent.opacity(0.16)) {
                    editMode.toggle()
                    draggingCard = nil   // clear any residual drag dim when leaving/entering edit
                }
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
        editMode = false       // opening settings exits edit mode (prototype `openSettings`, line 762)
        draggingCard = nil
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Cards (prototype lines 76–173)

    private static let cardSpace = "wattly.cards"
    private static let cardSpacing: CGFloat = 8   // matches the cards VStack spacing

    private var cardsStack: some View {
        VStack(spacing: 8) {
            ForEach(visibleCards) { card in
                // Each row publishes its layout slot (in the "cards" space) so a drop can
                // hit-test which card it landed on. Read on the un-offset row, so the reported
                // frame is the stable slot — not the dragged card's transient offset.
                let row = cardRow(card)
                    .background(GeometryReader { geo in
                        Color.clear.preference(
                            key: CardFrameKey.self,
                            value: [card: geo.frame(in: .named(Self.cardSpace))])
                    })
                // The drag gesture attaches ONLY in edit mode, so a non-edit row can't be
                // reordered (prototype `if(!editMode)return`, line 651).
                if editMode {
                    row
                        .opacity(draggingCard == card ? 0.45 : 1)
                        .offset(y: draggingCard == card ? dragOffset : 0)
                        .zIndex(draggingCard == card ? 1 : 0)
                        // Make the WHOLE row — including the grip's empty strip on the left — one
                        // hit-test rect, so a drag started on the grip handle registers. The grip
                        // is just tiny dots with no fill, so that 14px strip is otherwise dead.
                        .contentShape(Rectangle())
                        .gesture(dragGesture(card))
                        // NOTE: deliberately NO `.animation(value: cardOrder)` here. The dragged
                        // card already glides via `homeShift`; animating the displaced cards left
                        // a 0.2 s slide (plus its re-render churn) running right at drop, which the
                        // user saw as a post-drop freeze once the dragged card stopped moving.
                        // Instant reorder = no trailing animation = no freeze.
                } else {
                    row
                }
            }
        }
        .coordinateSpace(name: Self.cardSpace)
        .onPreferenceChange(CardFrameKey.self) { cardFrames = $0 }
        .padding(.vertical, 1)
    }

    /// Reorder by a plain `DragGesture` (see the `homeShift` note for why not `.onDrag`).
    /// LIVE: as the cursor crosses a neighbour's midpoint the cards reorder in real time and
    /// the displaced ones slide aside; the dragged card tracks the cursor via `dragOffset`.
    /// On release nothing jumps — the order is already final, the card just settles into place.
    private func dragGesture(_ card: CardKind) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.cardSpace))
            .onChanged { value in
                if draggingCard != card { beginDrag(card) }
                updateReorder(card, fingerY: value.location.y)
                dragOffset = clampedOffset(card, raw: value.translation.height - homeShift)
            }
            .onEnded { _ in
                guard !reduceMotion else {
                    draggingCard = nil; dragOffset = 0; homeShift = 0; dragSlots = []
                    return
                }
                // Settle the small residual offset into the slot, THEN drop the drag identity.
                // (Clearing `draggingCard` first would zero the offset binding instantly, so the
                // glide must run while the card is still "the dragged card".) The order is already
                // final from the live reorder — only this one card moves.
                withAnimation(.easeOut(duration: 0.13)) {
                    dragOffset = 0
                } completion: {
                    draggingCard = nil
                    homeShift = 0
                    dragSlots = []
                }
            }
    }

    /// Snapshot the visible cards' slot geometry once, at the moment a drag begins.
    private func beginDrag(_ card: CardKind) {
        draggingCard = card
        homeShift = 0
        dragSlots = visibleCards.compactMap { c in
            cardFrames[c].map { DragSlot(card: c, minY: $0.minY, height: $0.height) }
        }
    }

    /// Map the cursor to a static slot and move the dragged card straight there (any distance,
    /// in one shot — so a fast drag never lags). `homeShift` is recomputed as an ABSOLUTE value
    /// from the snapshot each time (no accumulation drift), so `dragOffset = translation −
    /// homeShift` stays within one slot and the drop never snaps far.
    private func updateReorder(_ card: CardKind, fingerY: CGFloat) {
        guard let oi = dragSlots.firstIndex(where: { $0.card == card }) else { return }
        // The slot the cursor is currently over (last slot whose top is above the cursor).
        var target = 0
        for (idx, s) in dragSlots.enumerated() {
            if fingerY >= s.minY { target = idx } else { break }
        }
        // Net vertical move of the dragged card's home from its original slot to the target.
        if target > oi {
            homeShift = dragSlots[(oi + 1)...target].reduce(0) { $0 + $1.height + Self.cardSpacing }
        } else if target < oi {
            homeShift = -dragSlots[target..<oi].reduce(0) { $0 + $1.height + Self.cardSpacing }
        } else {
            homeShift = 0
        }
        // Desired visible order = snapshot order with `card` moved to `target`; write it back
        // into the full order, leaving hidden cards in their absolute positions.
        var vis = dragSlots.map(\.card)
        vis.removeAll { $0 == card }
        vis.insert(card, at: min(target, vis.count))
        let visibleSet = Set(dragSlots.map(\.card))
        var it = vis.makeIterator()
        let newCards = cardOrder.cards.map { visibleSet.contains($0) ? (it.next() ?? $0) : $0 }
        let newOrder = CardOrder(newCards)
        if newOrder != cardOrder { cardOrder = newOrder }
    }

    /// Keep the dragged card within the list's vertical bounds, so over-dragging past the first
    /// or last slot doesn't fling it into empty space (which would snap back on release).
    private func clampedOffset(_ card: CardKind, raw: CGFloat) -> CGFloat {
        guard let oi = dragSlots.firstIndex(where: { $0.card == card }),
              let first = dragSlots.first, let last = dragSlots.last else { return raw }
        let homeTop = dragSlots[oi].minY + homeShift            // dragged card's slot top at target
        let minTop = first.minY                                 // can't rise above the first slot
        let maxTop = last.minY + last.height - dragSlots[oi].height  // …or sink below the last
        let renderedTop = homeTop + raw
        return raw + (min(max(renderedTop, minTop), maxTop) - renderedTop)
    }

    /// One reorderable row: the grip (edit mode only) + the metric card. In edit mode the
    /// expand-tap is suppressed (`onToggleExpand: nil`) so a card can't change height
    /// mid-drag; already-expanded cards are left as-is (no forced collapse).
    private func cardRow(_ card: CardKind) -> some View {
        HStack(spacing: 5) {
            if editMode {
                GripGlyph().frame(width: 14)
            }
            MetricCardView(
                card: card,
                state: monitor.cardState(card, smoothed: powerSmoothed),
                historyValues: monitor.historyValues(for: card, smoothed: powerSmoothed),
                isExpanded: expanded.contains(card),
                onToggleExpand: editMode ? nil : (card.isExpandable ? { toggleExpand(card) } : nil),
                thresholds: thresholds
            )
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

/// Per-card layout slots in the popover's "cards" coordinate space, collected so an
/// edit-mode drag can hit-test which card it was released over (issue 12).
private struct CardFrameKey: PreferenceKey {
    static let defaultValue: [CardKind: CGRect] = [:]
    static func reduce(value: inout [CardKind: CGRect], nextValue: () -> [CardKind: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
