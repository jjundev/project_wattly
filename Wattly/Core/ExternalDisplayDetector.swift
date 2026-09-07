import AppKit
import CoreGraphics

/// 외장 디스플레이가 하나라도 켜져 있는지.
///
/// 클램쉘 방전의 두 번째 전제다(첫째는 사용자 옵트인). 외장 화면 없이 뚜껑을 닫은 Mac이
/// 깨어 있는 것은 사용자가 원한 것이 아니므로, 앱은 이 값이 거짓이면 데몬에
/// `clamshellDischargeAllowed=false`를 보낸다. 루트 데몬은 WindowServer 없이 CG를 부를 수
/// 없어 이 판정은 앱만 한다.
///
/// 뚜껑을 닫으면 내장 화면은 `NSScreen.screens`에서 빠지고 외장만 남는다 — 그래서 "내장이
/// 아닌 화면이 하나라도 있는가"이지 "화면이 둘 이상인가"가 아니다.
enum ExternalDisplayDetector {
    /// 순수 코어. `isBuiltin`은 `CGDisplayIsBuiltin`을 주입받는다.
    static func hasExternalDisplay(
        displayIDs: [CGDirectDisplayID],
        isBuiltin: (CGDirectDisplayID) -> Bool
    ) -> Bool {
        displayIDs.contains { !isBuiltin($0) }
    }

    @MainActor
    static func hasExternalDisplay(screens: [NSScreen] = NSScreen.screens) -> Bool {
        let ids = screens.compactMap { screen -> CGDirectDisplayID? in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        return hasExternalDisplay(displayIDs: ids, isBuiltin: { CGDisplayIsBuiltin($0) != 0 })
    }
}
