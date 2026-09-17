import Foundation

/// 이 프로세스가 충전 제한 요청을 어디로 보낼지 정한다.
///
/// 네이티브 백엔드는 **다른 길이 없다고 증명된 Mac에서만** 고른다: 구동 가능한 레지스터
/// (`CHTE`/`CH0B`/`BCLM`)가 전부 SMC result 132로 부재가 확인됐고(`uncertain`은 증명이 아니다),
/// PowerUI가 지원한다고 답할 때. 레지스터가 하나라도 남아 있는 Mac — macOS 26.x 전부 — 은
/// 예전 그대로 루트 도우미를 쓴다. 도우미 경로는 세일링·열 보호·80% 미만 목표를 표현할 수
/// 있고 네이티브는 못 하므로, 둘 다 가능할 때 네이티브를 고를 이유가 없다.
enum BatteryControlBackendSelector {
    static func select(
        isRunningTests: Bool,
        smcProbe: (String) -> BatteryControlKeyProbeResult,
        isNativeSupported: () -> Bool
    ) -> BatteryControlBackend {
        guard !isRunningTests else { return .smc }
        guard BatteryControlKeys.runtimeDrivableRegisterProbe(probing: smcProbe) == .noDrivableRegisterAtRuntime else {
            return .smc
        }
        return isNativeSupported() ? .nativeLimit : .smc
    }

    /// 테스트 호스트는 실제 Wattly.app이다. 여기서 네이티브 백엔드가 선택되면 핸들러를 주입하지
    /// 않은 `BatteryControlClient()`를 만드는 기존 테스트가 개발자의 시스템 충전 제한을 바꾼다.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// 프로세스당 한 번. 레지스터 세대는 펌웨어의 사실이라 실행 중에 바뀌지 않는다.
    static let current: BatteryControlBackend = {
        // SMC에 붙지 못하면 레지스터의 부재를 **증명할 수 없다**. 증명 없이 네이티브로 가면
        // 레지스터가 멀쩡한 Mac에서 기능이 조용히 줄어들므로, 모르는 쪽은 기존 경로로 둔다.
        guard let smc = SMCConnection() else { return .smc }
        return select(
            isRunningTests: isRunningTests,
            smcProbe: { key in
                let reply = smc.probeKeyInfo(key)
                return .fromSMCKeyInfo(
                    kernelSucceeded: reply.kernel == KERN_SUCCESS,
                    smcResult: reply.output.result,
                    type: SMCConnection.string(reply.output.keyInfo.dataType),
                    size: Int(reply.output.keyInfo.dataSize))
            },
            isNativeSupported: { NativeChargeLimitService.sharedDriver.isSupported })
    }()
}

extension NativeChargeLimitService {
    /// 실제 PowerUI 드라이버. `static let`이라 처음 읽힐 때 — 즉 선택기가 "레지스터가 없다"고
    /// 판정한 뒤에만 — 프레임워크를 올린다.
    static let sharedDriver = PowerUIChargeLimitDriver()

    static let shared = NativeChargeLimitService(
        driver: sharedDriver,
        reader: { NativeLimitBatteryReader.read() },
        defaults: .standard,
        now: { Date().timeIntervalSince1970 })
}

#if DEBUG
/// DEBUG 실기 프로브. 이 Mac에서 어느 백엔드가 선택되는지와 네이티브 제한의 현재 상태를 출력하고
/// 종료한다. **읽기만 한다** — `setLimit`/`temporarilyDisable`은 부르지 않는다.
///   `Wattly.app/Contents/MacOS/Wattly -WattlyNativeLimitProbe`
/// Release에서는 제외.
enum NativeLimitProbe {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("-WattlyNativeLimitProbe") else { return }
        print("[native-limit-probe] selected backend: \(BatteryControlBackendSelector.current.rawValue)")
        let driver = NativeChargeLimitService.sharedDriver
        print("[native-limit-probe] PowerUI supported: \(driver.isSupported)")
        do {
            print("[native-limit-probe] available limits: \(try driver.availableLimits())")
            let snapshot = try driver.snapshot()
            print("[native-limit-probe] native limit: \(snapshot.limit) state: \(snapshot.state)")
        } catch {
            print("[native-limit-probe] PowerUI read failed: \(error)")
        }
        if let reading = NativeLimitBatteryReader.read() {
            print("[native-limit-probe] battery: \(reading.percentage)% plugged=\(reading.isPluggedIn) mA=\(reading.batteryMilliamps.map(String.init) ?? "nil")")
        } else {
            print("[native-limit-probe] battery: unreadable")
        }
        let defaults = UserDefaults.standard
        print("[native-limit-probe] owned=\(defaults.bool(forKey: StorageKey.nativeLimitOwned)) topUpReachedFullAt=\(defaults.object(forKey: StorageKey.nativeLimitTopUpReachedFullAt) ?? "nil")")
        exit(0)
    }
}
#endif
