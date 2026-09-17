import Testing
@testable import Wattly

@Suite struct NativeChargeLimitDriverTests {
    /// 프레임워크를 못 찾는 Mac(구형 macOS, 애플이 경로를 옮긴 미래)에서 드라이버는 조용히
    /// "미지원"이어야 한다 — 백엔드 선택기가 이 값 하나로 SMC 경로로 물러난다.
    @Test func missingFrameworkMeansUnsupportedAndEveryCallThrows() {
        let driver = PowerUIChargeLimitDriver(frameworkPath: "/nonexistent/PowerUI.framework/PowerUI")
        #expect(driver.isSupported == false)
        #expect(throws: NativeChargeLimitError.unavailable) { try driver.availableLimits() }
        #expect(throws: NativeChargeLimitError.unavailable) { try driver.snapshot() }
        #expect(throws: NativeChargeLimitError.unavailable) { try driver.setLimit(80) }
        #expect(throws: NativeChargeLimitError.unavailable) { try driver.temporarilyDisable() }
    }

    @Test func fakeDriverRejectsOffListValuesLikeTheRealOne() {
        let fake = FakeNativeChargeLimitDriver()
        #expect(throws: NativeChargeLimitError.callFailed(selector: "setMCLLimit:error:", code: 4)) {
            try fake.setLimit(70)
        }
        #expect(fake.writes.isEmpty)
    }

    @Test func fakeDriverTurnsItselfOffAtOneHundred() throws {
        let fake = FakeNativeChargeLimitDriver()
        try fake.setLimit(80)
        #expect(fake.current == .init(limit: 80, state: .on))
        try fake.setLimit(100)
        #expect(fake.current == .init(limit: 100, state: .off))
    }
}
