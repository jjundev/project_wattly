import Foundation
import Testing
@testable import Wattly

struct SleepAssertionTests {
    final class Spy: @unchecked Sendable {
        var created: [String] = []
        var released: [UInt32] = []
        var nextID: UInt32 = 7
        var shouldFail = false
    }

    private func makeAssertion(_ spy: Spy) -> SleepAssertion {
        SleepAssertion(
            create: { reason in
                spy.created.append(reason)
                return spy.shouldFail ? nil : spy.nextID
            },
            release: { spy.released.append($0) })
    }

    @Test func acquireIsIdempotent() {
        let spy = Spy()
        let assertion = makeAssertion(spy)
        assertion.acquire(reason: "calibration discharge")
        assertion.acquire(reason: "calibration discharge")
        #expect(spy.created.count == 1)
        #expect(assertion.isHeld)
    }

    @Test func releaseHandsTheAssertionBackExactlyOnce() {
        let spy = Spy()
        let assertion = makeAssertion(spy)
        assertion.acquire(reason: "x")
        assertion.release()
        assertion.release()
        #expect(spy.released == [7])
        #expect(assertion.isHeld == false)
    }

    @Test func aFailedCreateLeavesNothingHeld() {
        let spy = Spy()
        spy.shouldFail = true
        let assertion = makeAssertion(spy)
        assertion.acquire(reason: "x")
        #expect(assertion.isHeld == false)
        assertion.release()
        #expect(spy.released.isEmpty)
    }

    @Test func reacquireAfterReleaseCreatesANewAssertion() {
        let spy = Spy()
        let assertion = makeAssertion(spy)
        assertion.acquire(reason: "x")
        assertion.release()
        spy.nextID = 9
        assertion.acquire(reason: "x")
        #expect(spy.created.count == 2)
        assertion.release()
        #expect(spy.released == [7, 9])
    }
}
