import Testing
import Foundation
@testable import Wattly

/// Pure-logic tests for card reordering (issue 12 §26) and `CardOrder` persistence.
/// The drag/drop UI is a thin shell over `CardOrder.reordering` — these cross that pure
/// seam directly (no SwiftUI), mirroring the prototype `reorderCards` down/up branch.
/// `CardOrder` had zero coverage before this.
struct CardReorderTests {

    // Default order indices: power 0, battery 1, cpu 2, mem 3, cpuTemp 4, gpuTemp 5, batTemp 6.
    private let order = Defaults.cardOrder

    // MARK: dragging downward drops `from` AFTER `target`

    @Test func dragDownLandsAfterTarget() {
        // power (0) onto cpu (2) → power sits right after cpu
        let r = order.reordering(.power, onto: .cpu)
        #expect(r.cards == [.battery, .cpu, .power, .mem, .cpuTemp, .gpuTemp, .batTemp, .fan])
    }

    @Test func dragDownAdjacentSwaps() {
        // power (0) onto battery (1) → simple swap
        let r = order.reordering(.power, onto: .battery)
        #expect(r.cards == [.battery, .power, .cpu, .mem, .cpuTemp, .gpuTemp, .batTemp, .fan])
    }

    @Test func dragFirstToLast() {
        let r = order.reordering(.power, onto: .batTemp)
        #expect(r.cards == [.battery, .cpu, .mem, .cpuTemp, .gpuTemp, .batTemp, .power, .fan])
    }

    // MARK: dragging upward drops `from` BEFORE `target`

    @Test func dragUpLandsBeforeTarget() {
        // batTemp (6) onto cpu (2) → batTemp sits right before cpu
        let r = order.reordering(.batTemp, onto: .cpu)
        #expect(r.cards == [.power, .battery, .batTemp, .cpu, .mem, .cpuTemp, .gpuTemp, .fan])
    }

    @Test func dragUpAdjacentSwaps() {
        // mem (3) onto cpu (2) → swap
        let r = order.reordering(.mem, onto: .cpu)
        #expect(r.cards == [.power, .battery, .mem, .cpu, .cpuTemp, .gpuTemp, .batTemp, .fan])
    }

    @Test func dragLastToFirst() {
        let r = order.reordering(.batTemp, onto: .power)
        #expect(r.cards == [.batTemp, .power, .battery, .cpu, .mem, .cpuTemp, .gpuTemp, .fan])
    }

    // MARK: no-ops & invariants

    @Test func sameCardIsNoOp() {
        #expect(order.reordering(.cpu, onto: .cpu).cards == order.cards)
    }

    @Test func reorderIsAPermutation() {
        // No card lost or duplicated by a reorder.
        let r = order.reordering(.power, onto: .gpuTemp)
        #expect(Set(r.cards) == Set(order.cards))
        #expect(r.cards.count == order.cards.count)
    }

    @Test func reorderKeepsOtherCardsRelativeOrder() {
        // A shorter custom order: dragging an end card past the middle must not disturb
        // the relative order of the cards it passes.
        let custom = CardOrder([.power, .battery, .cpu, .mem])
        #expect(custom.reordering(.power, onto: .mem).cards == [.battery, .cpu, .mem, .power])
    }

    // MARK: CardOrder RawRepresentable round-trip + init? guards (previously untested)

    @Test func rawValueRoundTrips() {
        let o = CardOrder(CardKind.allCases.reversed())   // a full permutation — nothing to migrate
        #expect(CardOrder(rawValue: o.rawValue)?.cards == o.cards)
    }

    @Test func defaultsRoundTrip() {
        #expect(CardOrder(rawValue: Defaults.cardOrder.rawValue)?.cards == Defaults.cardOrder.cards)
    }

    @Test func emptyStringIsRejected() {
        #expect(CardOrder(rawValue: "") == nil)
    }

    @Test func unknownTokenIsRejected() {
        // "foo" isn't a CardKind → count mismatch vs parts → nil (per init? guard).
        #expect(CardOrder(rawValue: "power,foo,cpu") == nil)
    }

    @Test func cardOrderAppendsNewlyAddedCards() {
        // A persisted order from before the fan card shipped (7 cards, no ".fan").
        let legacy = "power,battery,cpu,mem,cpuTemp,gpuTemp,batTemp"
        let order = CardOrder(rawValue: legacy)
        #expect(order != nil)
        #expect(order?.cards.contains(.fan) == true)               // migrated in
        #expect(Set(order?.cards ?? []) == Set(CardKind.allCases))  // every card present
        #expect(order?.cards.prefix(7).map(\.rawValue) == legacy.split(separator: ",").map(String.init))  // user order preserved, new card appended
    }

}
