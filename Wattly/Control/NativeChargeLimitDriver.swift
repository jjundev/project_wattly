import Foundation

enum NativeChargeLimitError: Error, Equatable {
    /// 프레임워크·클래스·셀렉터 중 하나가 없다. 이 Mac에서는 네이티브 백엔드를 쓸 수 없다.
    case unavailable
    /// 호출은 됐지만 실패했다. `code`는 `PowerUISmartChargingErrorDomain`의 코드(목록 밖 값 = 4),
    /// NSError 없이 `NO`만 돌아오면 -1.
    case callFailed(selector: String, code: Int)
}

/// 애플 네이티브 충전 제한에 대한 최소 인터페이스. 서비스와 테스트가 이 뒤에서만 I/O를 본다.
protocol NativeChargeLimitDriving: Sendable {
    var isSupported: Bool { get }
    func availableLimits() throws -> [Int]
    func snapshot() throws -> NativeLimitSnapshot
    func setLimit(_ percentage: Int) throws
    func temporarilyDisable() throws
}

/// 비공개 `PowerUI.framework`의 `PowerUISmartChargeClient`를 ObjC 런타임으로 부른다.
///
/// 헤더도 링크도 없다. `dlopen`으로 올리고 `NSClassFromString`으로 찾은 뒤, 필요한 셀렉터
/// 여섯 개가 **전부** 응답할 때만 `client`를 갖는다. 하나라도 빠지면 `client == nil`이고 모든
/// 호출이 `.unavailable`을 던진다 — 애플이 이 비공개 API를 바꾸는 날, 앱은 크래시가 아니라
/// "이 Mac은 지원되지 않음"으로 떨어져야 한다.
///
/// 타입 인코딩은 macOS 27.0(26A428)에서 `method_getTypeEncoding`으로 읽은 값이다:
/// `getMCLLimitWithError:` = `C24@0:8^@16`(UInt8), `isMCLCurrentlyEnabled:` = `Q24@0:8^@16`(UInt64),
/// `setMCLLimit:error:` = `B28@0:8C16^@20`, `temporarilyDisableMCL:` = `B24@0:8^@16`,
/// `availableChargeLimitsWithError:` = `@24@0:8^@16`, `isMCLSupported` = `B16@0:8`.
///
/// `@unchecked Sendable`: `client`는 불변이고 호출은 전부 `NativeChargeLimitService` actor 안에서
/// 직렬로 일어난다. 각 호출은 `PowerUIAgent`로 가는 동기 XPC 왕복이므로 메인 스레드에서 부르지 않는다.
final class PowerUIChargeLimitDriver: NativeChargeLimitDriving, @unchecked Sendable {
    static let defaultFrameworkPath = "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI"

    private typealias ErrorPointer = AutoreleasingUnsafeMutablePointer<NSError?>?
    private static let requiredSelectors = [
        "isMCLSupported", "availableChargeLimitsWithError:", "getMCLLimitWithError:",
        "isMCLCurrentlyEnabled:", "setMCLLimit:error:", "temporarilyDisableMCL:"
    ]

    private let client: NSObject?

    init(clientName: String = "Wattly", frameworkPath: String = PowerUIChargeLimitDriver.defaultFrameworkPath) {
        guard dlopen(frameworkPath, RTLD_NOW) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type,
              // `alloc`의 +1은 `init…`이 소비하므로 여기서는 소유권을 가져오지 않는다.
              let allocated = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
              let instance = allocated.perform(NSSelectorFromString("initWithClientName:"), with: clientName)?
                  .takeRetainedValue() as? NSObject,
              Self.requiredSelectors.allSatisfy({ instance.responds(to: NSSelectorFromString($0)) })
        else {
            client = nil
            return
        }
        client = instance
    }

    var isSupported: Bool {
        guard let client else { return false }
        let sel = NSSelectorFromString("isMCLSupported")
        let fn = unsafeBitCast(client.method(for: sel), to: (@convention(c) (AnyObject, Selector) -> Bool).self)
        return fn(client, sel)
    }

    func availableLimits() throws -> [Int] {
        let name = "availableChargeLimitsWithError:"
        let (client, sel) = try target(name)
        let fn = unsafeBitCast(
            client.method(for: sel),
            to: (@convention(c) (AnyObject, Selector, ErrorPointer) -> Unmanaged<AnyObject>?).self)
        var error: NSError?
        let result = fn(client, sel, &error)?.takeUnretainedValue()
        if let error { throw NativeChargeLimitError.callFailed(selector: name, code: error.code) }
        return ((result as? [NSNumber]) ?? []).map(\.intValue).sorted()
    }

    func snapshot() throws -> NativeLimitSnapshot {
        NativeLimitSnapshot(limit: try currentLimit(), state: try enabledState())
    }

    func setLimit(_ percentage: Int) throws {
        let name = "setMCLLimit:error:"
        let (client, sel) = try target(name)
        let fn = unsafeBitCast(
            client.method(for: sel),
            to: (@convention(c) (AnyObject, Selector, UInt8, ErrorPointer) -> Bool).self)
        var error: NSError?
        let ok = fn(client, sel, UInt8(clamping: percentage), &error)
        guard ok, error == nil else {
            throw NativeChargeLimitError.callFailed(selector: name, code: error?.code ?? -1)
        }
    }

    func temporarilyDisable() throws {
        let name = "temporarilyDisableMCL:"
        let (client, sel) = try target(name)
        let fn = unsafeBitCast(
            client.method(for: sel),
            to: (@convention(c) (AnyObject, Selector, ErrorPointer) -> Bool).self)
        var error: NSError?
        let ok = fn(client, sel, &error)
        guard ok, error == nil else {
            throw NativeChargeLimitError.callFailed(selector: name, code: error?.code ?? -1)
        }
    }

    private func currentLimit() throws -> Int {
        let name = "getMCLLimitWithError:"
        let (client, sel) = try target(name)
        let fn = unsafeBitCast(
            client.method(for: sel),
            to: (@convention(c) (AnyObject, Selector, ErrorPointer) -> UInt8).self)
        var error: NSError?
        let value = fn(client, sel, &error)
        if let error { throw NativeChargeLimitError.callFailed(selector: name, code: error.code) }
        return Int(value)
    }

    private func enabledState() throws -> NativeLimitEnabledState {
        let name = "isMCLCurrentlyEnabled:"
        let (client, sel) = try target(name)
        let fn = unsafeBitCast(
            client.method(for: sel),
            to: (@convention(c) (AnyObject, Selector, ErrorPointer) -> UInt64).self)
        var error: NSError?
        let value = fn(client, sel, &error)
        if let error { throw NativeChargeLimitError.callFailed(selector: name, code: error.code) }
        return NativeLimitEnabledState(rawState: value)
    }

    private func target(_ selector: String) throws -> (NSObject, Selector) {
        guard let client else { throw NativeChargeLimitError.unavailable }
        return (client, NSSelectorFromString(selector))
    }
}
