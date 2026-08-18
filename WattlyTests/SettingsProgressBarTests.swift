import Testing
import Foundation
@testable import Wattly

@Suite struct SettingsProgressBarTests {
    @Test func clampsProgressValueBetweenZeroAndOne() {
        #expect(WattlyProgressBar.clampedFraction(-0.5) == 0.0)
        #expect(WattlyProgressBar.clampedFraction(0.0) == 0.0)
        #expect(WattlyProgressBar.clampedFraction(0.42) == 0.42)
        #expect(WattlyProgressBar.clampedFraction(1.0) == 1.0)
        #expect(WattlyProgressBar.clampedFraction(1.5) == 1.0)
        #expect(WattlyProgressBar.clampedFraction(.nan) == 0.0)
        #expect(WattlyProgressBar.clampedFraction(.infinity) == 1.0)
        #expect(WattlyProgressBar.clampedFraction(-.infinity) == 0.0)
    }
}
