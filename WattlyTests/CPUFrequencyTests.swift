import Testing
import Foundation
@testable import Wattly

struct CPUFrequencyTests {
    @Test func perfLevelActiveGHzDefaultsNil() {
        #expect(PerfLevelUsage(name: "P", usage: 0).activeGHz == nil)
    }
}
