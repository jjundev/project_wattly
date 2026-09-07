import AppKit
import Testing
@testable import Wattly

@Suite struct ExternalDisplayDetectorTests {
    /// 내장 화면 하나뿐이면 클램쉘 방전의 전제가 없다.
    @Test func builtinOnlyIsNotExternal() {
        #expect(ExternalDisplayDetector.hasExternalDisplay(
            displayIDs: [1], isBuiltin: { _ in true }) == false)
    }

    @Test func anyNonBuiltinDisplayCounts() {
        #expect(ExternalDisplayDetector.hasExternalDisplay(
            displayIDs: [1, 2], isBuiltin: { $0 == 1 }) == true)
    }

    /// 뚜껑을 닫으면 내장 화면이 목록에서 빠지고 외장만 남는다 — 그때도 참이어야 한다.
    @Test func lidClosedLeavesOnlyTheExternalDisplay() {
        #expect(ExternalDisplayDetector.hasExternalDisplay(
            displayIDs: [2], isBuiltin: { $0 == 1 }) == true)
    }

    /// 뚜껑을 닫은 채 외장 모니터까지 뽑으면 화면이 하나도 없다 — 거짓이어야 데몬이 잠자기를
    /// 되돌린다.
    @Test func noDisplaysIsNotExternal() {
        #expect(ExternalDisplayDetector.hasExternalDisplay(
            displayIDs: [], isBuiltin: { _ in false }) == false)
    }

    @Test func clamshellPreferenceDefaultsOffWithAStableKey() {
        #expect(Defaults.batteryClamshellDischargeEnabled == false)
        #expect(StorageKey.batteryClamshellDischargeEnabled == "batteryClamshellDischargeEnabled")
    }
}
