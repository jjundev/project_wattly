import Foundation

/// Reads the Korean status sentences that an **already-installed, older** `WattlyFanDaemon` sends,
/// and turns them back into reason codes the app can localize.
///
/// This is not belt-and-braces. Nothing in the app replaces a privileged helper that is outdated
/// but still answering — only a missing one gets installed — so a user who updates Wattly keeps
/// their old daemon, and its Korean-only `detail` field, until something else replaces it. Without
/// this table those users would read Korean in an otherwise fully translated app.
///
/// **This table is frozen.** It describes binaries already on disk (built from commit `e311a7f`),
/// which can never change retroactively. `BatteryControlStatusReason.legacyKoreanDetail` looks
/// identical today but answers a different question — what *this* build emits — and is free to be
/// reworded. Sharing one table between them means the day someone improves the copy, the app
/// silently stops recognizing every helper already installed in the field.
enum LegacyBatteryDetail {

    /// `nil` for anything not on the list, which is the right answer for XPC/system error
    /// descriptions travelling in the same field: they are already localized by macOS, and forcing
    /// them into a status code would hide a real failure behind a cheerful sentence.
    static func reason(from detail: String) -> BatteryControlStatusReason? {
        switch detail {
        case "초기화 중": return .init(kind: .initializing)
        case "전원 소스를 읽을 수 없습니다": return .init(kind: .powerSourceUnreadable)
        case "이 Mac은 충전 제어를 지원하지 않습니다": return .init(kind: .hardwareUnsupported)
        case "충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)": return .init(kind: .releaseFailed)
        case "이 Mac에서 충전 제어를 적용하지 못했습니다": return .init(kind: .applyFailed)
        case "충전 제한 비활성화됨": return .init(kind: .limitDisabled)
        case "배터리 전원으로 구동 중": return .init(kind: .onBatteryPower)
        default: break
        }

        // The two interpolated sentences. A catalog lookup can never match these — the limit is
        // baked into the string — so this is the only path that localizes them.
        if let limit = number(in: detail,
                              between: "충전 제한 ",
                              and: "% 도달 (전원 어댑터 바이패스 구동)") {
            return .init(kind: .inhibitedAtLimit, limitPercentage: limit)
        }
        if let limit = number(in: detail, between: "목표치(", and: "%)까지 충전 중") {
            return .init(kind: .chargingToTarget, limitPercentage: limit)
        }
        return nil
    }

    /// Affix matching rather than a regular expression: the surrounding copy contains `(`, `)` and
    /// `%`, all of which would need escaping, and the shape here is fixed enough that a pattern
    /// would only add ways to get it wrong.
    private static func number(in text: String, between prefix: String, and suffix: String) -> Int? {
        guard text.hasPrefix(prefix), text.hasSuffix(suffix),
              text.count > prefix.count + suffix.count else { return nil }
        let start = text.index(text.startIndex, offsetBy: prefix.count)
        let end = text.index(text.endIndex, offsetBy: -suffix.count)
        return Int(text[start..<end])
    }
}
