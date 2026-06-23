import Testing
@testable import Wattly

/// Pure-seam tests for the mode-C hero resolution (plan 20). `resolveHero` picks the persisted
/// hero when it's still visible, else the first visible card (in the passed `cardOrder` order),
/// else nil — the prototype fallback (lines 693–695), independent of SwiftUI. It is deliberately
/// state-agnostic: the caller's `visible` set already includes present-but-unavailable cards, so a
/// fallback can legitimately land on a card that will render its unavailable face.
struct HeroSelectionTests {

    @Test func persistedHeroWhenVisible() {
        #expect(CardPresentation.resolveHero(persisted: .cpu,
                                             visible: [.power, .cpu, .mem]) == .cpu)
    }

    @Test func fallsBackToFirstVisibleWhenHidden() {
        // Persisted hero (.battery) not in the visible set → first visible (.power).
        #expect(CardPresentation.resolveHero(persisted: .battery,
                                             visible: [.power, .cpu, .mem]) == .power)
    }

    @Test func fallbackHonorsVisibleOrder() {
        // "First visible" follows the passed (cardOrder) order — not a fixed metric order.
        #expect(CardPresentation.resolveHero(persisted: .gpuTemp,
                                             visible: [.mem, .cpu, .power]) == .mem)
    }

    @Test func emptyVisibleYieldsNil() {
        #expect(CardPresentation.resolveHero(persisted: .power, visible: []) == nil)
    }
}
