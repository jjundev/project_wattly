import Foundation
import Testing
@testable import Wattly

@Suite struct NativeLimitPresentationTests {
    @Test func theHelperBackendHidesNothing() {
        #expect(BatterySectionPresentation.hiddenFeatures(backend: .smc).isEmpty)
        // nil = 필드를 모르는 도우미 = SMC 백엔드.
        #expect(BatterySectionPresentation.hiddenFeatures(backend: nil).isEmpty)
        #expect(BatterySectionPresentation.hiddenFeatures(backend: .unrecognized).isEmpty)
    }

    @Test func theNativeBackendHidesWhatACeilingCannotExpress() {
        #expect(BatterySectionPresentation.hiddenFeatures(backend: .nativeLimit)
                == [.sailing, .heatProtection, .sleepUntilLimit])
    }

    @Test func theNoticeAppearsOnlyForTheNativeBackend() {
        let korean = Locale(identifier: "ko")
        #expect(BatterySectionPresentation.nativeLimitNotice(backend: .smc, locale: korean) == nil)
        #expect(BatterySectionPresentation.nativeLimitNotice(backend: nil, locale: korean) == nil)
        #expect(BatterySectionPresentation.nativeLimitNotice(backend: .nativeLimit, locale: korean)
                == "이 macOS에서는 시스템 충전 제한을 사용합니다. 일부 옵션은 사용할 수 없습니다.")
    }
}
