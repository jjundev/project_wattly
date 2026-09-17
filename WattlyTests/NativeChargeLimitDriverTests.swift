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

    /// 셀렉터 이름만 맞고 **서명이 다르면** `@convention(c)` 캐스트가 쓰레기 인자를 들고
    /// 시스템 충전 제한을 건드린다. 이름 목록이 아니라 타입 인코딩을 대조해야 하는 이유다.
    @Test func matchingEncodingsAreRequiredSelectorBySelector() {
        let measured = PowerUIChargeLimitDriver.requiredSelectorEncodings.mapValues { Optional($0) }
        #expect(PowerUIChargeLimitDriver.encodingsMatch(measured))

        var changed = measured
        changed["setMCLLimit:error:"] = "B28@0:8Q16^@20"   // UInt8이 아니라 UInt64를 받는 서명
        #expect(PowerUIChargeLimitDriver.encodingsMatch(changed) == false)

        var missing = measured
        missing.updateValue(nil, forKey: "temporarilyDisableMCL:")   // 셀렉터가 사라졌다
        #expect(PowerUIChargeLimitDriver.encodingsMatch(missing) == false)

        #expect(PowerUIChargeLimitDriver.encodingsMatch([:]) == false)
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
