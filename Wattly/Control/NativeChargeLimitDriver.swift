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
/// 여섯 개가 **전부 존재하고 서명까지 같을 때만** `client`를 갖는다. 하나라도 빠지거나 타입
/// 인코딩이 다르면 `client == nil`이고 모든 호출이 `.unavailable`을 던진다 — 애플이 이 비공개
/// API를 바꾸는 날, 앱은 크래시가 아니라 "이 Mac은 지원되지 않음"으로 떨어져야 한다.
///
/// **이름이 아니라 서명을 본다.** `responds(to:)`만 통과시키면, 애플이 같은 이름으로 인자
/// 폭이나 반환형을 바꿨을 때 `@convention(c)` 캐스트가 쓰레기 값을 들고 사용자의 시스템 충전
/// 제한을 건드린다. 대조표(`requiredSelectorEncodings`)는 macOS 27.0(26A428) arm64에서
/// `method_getTypeEncoding`으로 읽은 실측값이다 — 앱은 arm64 전용이라 인코딩이 고정이다.
///
/// `@unchecked Sendable`: `client`는 불변이고, 호출은 한 곳(`BatteryControlBackendSelector.current`가
/// 백엔드를 정하며 `isSupported`를 한 번 읽는다 — actor를 쓰기 전, 프로세스당 한 번)을 빼면 전부
/// `NativeChargeLimitService` actor 안에서 직렬로 일어난다. 각 호출은 `PowerUIAgent`로 가는 동기
/// XPC 왕복이므로 메인 스레드에서 부르지 않는다.
final class PowerUIChargeLimitDriver: NativeChargeLimitDriving, @unchecked Sendable {
    static let defaultFrameworkPath = "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI"

    private typealias ErrorPointer = AutoreleasingUnsafeMutablePointer<NSError?>?

    /// 셀렉터 → 기대 타입 인코딩. macOS 27.0(26A428) arm64 실측.
    static let requiredSelectorEncodings: [String: String] = [
        "isMCLSupported": "B16@0:8",
        "availableChargeLimitsWithError:": "@24@0:8^@16",
        "getMCLLimitWithError:": "C24@0:8^@16",
        "isMCLCurrentlyEnabled:": "Q24@0:8^@16",
        "setMCLLimit:error:": "B28@0:8C16^@20",
        "temporarilyDisableMCL:": "B24@0:8^@16"
    ]

    /// 순수 대조. `actual`의 값이 `nil`이면 "셀렉터가 없다"는 뜻이고, 그것도 불일치다.
    /// PowerUI 없이 테스트할 수 있도록 런타임 조회와 분리해 둔다.
    static func encodingsMatch(_ actual: [String: String?]) -> Bool {
        requiredSelectorEncodings.allSatisfy { name, expected in
            (actual[name] ?? nil) == expected
        }
    }

    /// 실제 클래스에서 읽은 인코딩. 없는 셀렉터는 `nil`로 남는다.
    private static func encodings(of instance: NSObject) -> [String: String?] {
        let cls: AnyClass = type(of: instance)
        return requiredSelectorEncodings.keys.reduce(into: [String: String?]()) { table, name in
            let method = class_getInstanceMethod(cls, NSSelectorFromString(name))
            table[name] = method.flatMap(method_getTypeEncoding).map { String(cString: $0) }
        }
    }

    private let client: NSObject?

    init(clientName: String = "Wattly", frameworkPath: String = PowerUIChargeLimitDriver.defaultFrameworkPath) {
        guard dlopen(frameworkPath, RTLD_NOW) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type,
              // `alloc`의 +1은 `init…`이 소비하므로 여기서는 소유권을 가져오지 않는다.
              let allocated = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
              let instance = allocated.perform(NSSelectorFromString("initWithClientName:"), with: clientName)?
                  .takeRetainedValue() as? NSObject,
              Self.encodingsMatch(Self.encodings(of: instance))
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
