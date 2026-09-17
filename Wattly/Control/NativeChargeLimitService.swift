import Foundation

/// 이 SDK(macOS 27)의 Foundation 오버레이는 `UserDefaults`의 `Sendable` 준수를 명시적으로
/// `unavailable`로 막아 놨다 — 구현은 내부적으로 스레드-세이프임에도 그렇다. 이 서비스의 init은
/// 액터 격리 경계를 넘어 `UserDefaults`를 받고, 호출자(테스트 rig 등)도 같은 참조를 계속 들고
/// 있어야 하므로 `nonisolated(unsafe)` 저장 프로퍼티만으로는 부족하다(파라미터가 액터로
/// "송신"되는 시점에 이미 막힌다). 대신 여기서만 `@unchecked Sendable`로 재선언해 이 파일이
/// 만드는 경계에서만 위험을 떠안는다.
extension UserDefaults: @unchecked @retroactive Sendable {}

/// macOS 27에서 루트 도우미 대신 충전 제한 요청에 답하는 앱 안 서비스.
///
/// `BatteryControlClient`의 요청 계약을 그대로 말한다(`.configure(Data)` / `.status` → 인코딩된
/// `BatteryControlServiceStatus`). 그래서 브리지·정책·표시·단축어·스케줄은 자기가 도우미와
/// 말하는지 이 서비스와 말하는지 모른다.
///
/// **모든 요청이 조정 패스다.** 네이티브 상태를 읽고, 저장된 정책과 다르면 다시 쓴다. 도우미는
/// 5초 타이머로 스스로 돌지만 이 서비스는 타이머가 없다 — 앱의 60초 reconcile 루프와 설정 창의
/// 5초 상태 폴링이 곧 박동이다. 앱이 꺼져 있는 동안은 펌웨어가 제한을 쥐고 있으므로 놓치는 것은
/// Top Up 만료뿐이고, 그건 다음 실행의 첫 요청에서 처리된다.
///
/// actor인 이유: PowerUI 호출은 `PowerUIAgent`로 가는 동기 XPC라 메인 스레드에서 부르면 안 되고,
/// 단축어는 호출마다 새 `BatteryControlClient`를 만들므로 상태를 클라이언트가 들고 있을 수 없다.
actor NativeChargeLimitService {
    typealias Reader = @Sendable () -> NativeLimitBatteryReading?

    private let driver: any NativeChargeLimitDriving
    private let reader: Reader
    private let defaults: UserDefaults
    private let now: @Sendable () -> TimeInterval
    private var lastMaintenance: BatteryMaintenanceRecord?
    private var hasHandledRequest = false

    init(
        driver: any NativeChargeLimitDriving,
        reader: @escaping Reader,
        defaults: UserDefaults,
        now: @escaping @Sendable () -> TimeInterval
    ) {
        self.driver = driver
        self.reader = reader
        self.defaults = defaults
        self.now = now
    }

    func handle(_ request: BatteryControlClient.BatteryControlClientRequest) -> (Data?, NSError?) {
        do {
            return (try BatteryControlCodec.encode(process(request)), nil)
        } catch {
            return (nil, error as NSError)
        }
    }

    func process(_ request: BatteryControlClient.BatteryControlClientRequest) -> BatteryControlServiceStatus {
        var configuration = storedConfiguration()
        // 프로세스의 첫 요청은 "서비스가 올라와 정책을 다시 세웠다"로 기록한다.
        var trigger: BatteryMaintenanceTrigger? = hasHandledRequest ? nil : .startup
        hasHandledRequest = true
        var decodeFailed = false

        if case .configure(let data) = request {
            trigger = .clientConfiguration
            if let decoded = try? BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data) {
                let incoming = decoded.configuration.normalized
                // 새로 시작하는 Top Up은 새 시계를 갖고, 끝난 Top Up은 시계를 버린다. 진행 중인
                // Top Up 위로 같은 설정이 다시 오면(60초 reconcile) 시계를 건드리지 않는다.
                if !incoming.topUpActive || !configuration.topUpActive { setReachedFullAt(nil) }
                configuration = incoming
                store(configuration)
            } else {
                decodeFailed = true
            }
        }

        guard let reading = reader() else {
            return NativeChargeLimitStatus.powerSourceUnreadable(configuration: configuration, now: now())
        }

        if configuration.topUpActive {
            if !reading.isPluggedIn {
                // 도우미와 같은 규칙: 어댑터 분리는 Top Up의 종료 사유다.
                configuration.topUpActive = false
                setReachedFullAt(nil)
                store(configuration)
                trigger = trigger ?? .adapterTransition
            } else {
                switch BatteryTopUpExpiry.decide(
                    topUpActive: true,
                    isHoldingAtFull: reading.percentage >= 100,
                    reachedFullAt: reachedFullAt(),
                    now: now()
                ) {
                case .none:
                    break
                case .stamp(let moment):
                    setReachedFullAt(moment)
                case .expire:
                    configuration.topUpActive = false
                    setReachedFullAt(nil)
                    store(configuration)
                    trigger = .topUpExpired
                }
            }
        }

        let listed = (try? driver.availableLimits()) ?? []
        let availableLimits = listed.isEmpty ? NativeChargeLimitPlan.fallbackLimits : listed
        var snapshot = try? driver.snapshot()
        var outcome = NativeLimitWriteOutcome.none

        if let current = snapshot {
            let command = NativeChargeLimitPlan.command(
                configuration: configuration,
                isPluggedIn: reading.isPluggedIn,
                native: current,
                ownsNativeLimit: defaults.bool(forKey: StorageKey.nativeLimitOwned),
                availableLimits: availableLimits)
            do {
                switch command {
                case .none:
                    break
                case .setLimit(let percentage):
                    try driver.setLimit(percentage)
                    defaults.set(percentage < NativeChargeLimitPlan.releaseLimit, forKey: StorageKey.nativeLimitOwned)
                    outcome = .applied
                case .temporarilyDisable:
                    try driver.temporarilyDisable()
                    outcome = .applied
                case .release:
                    try driver.setLimit(NativeChargeLimitPlan.releaseLimit)
                    defaults.set(false, forKey: StorageKey.nativeLimitOwned)
                    outcome = .applied
                }
            } catch {
                outcome = .failed
            }
            if outcome == .applied { snapshot = try? driver.snapshot() }
        }

        var status = NativeChargeLimitStatus.make(
            configuration: configuration,
            reading: reading,
            native: snapshot,
            availableLimits: availableLimits,
            outcome: outcome,
            now: now())

        // 요청이 없던 쓰기(상태 폴링 중 자가 복구)는 `.startup`으로 남긴다 — "서비스가 정책을
        // 다시 세웠다"는 뜻으로 도우미가 쓰는 것과 같은 의미다.
        if let effectiveTrigger = trigger ?? (outcome == .none ? nil : .startup) {
            let failed = decodeFailed || outcome == .failed || snapshot == nil
            lastMaintenance = BatteryMaintenanceRecord(
                trigger: effectiveTrigger,
                result: failed ? .failed : (outcome == .applied ? .applied : .verified),
                occurredAt: now(),
                reason: failed ? status.detailReason : nil)
        }
        status.lastMaintenance = lastMaintenance
        return status
    }

    // MARK: - Persistence

    private func storedConfiguration() -> BatteryControlConfiguration {
        guard let data = defaults.data(forKey: StorageKey.nativeLimitDesiredConfiguration),
              let decoded = try? BatteryControlCodec.decode(BatteryControlConfiguration.self, from: data)
        else { return BatteryControlConfiguration() }
        return decoded.normalized
    }

    private func store(_ configuration: BatteryControlConfiguration) {
        guard let data = try? BatteryControlCodec.encode(configuration) else { return }
        defaults.set(data, forKey: StorageKey.nativeLimitDesiredConfiguration)
    }

    private func reachedFullAt() -> TimeInterval? {
        defaults.object(forKey: StorageKey.nativeLimitTopUpReachedFullAt) as? TimeInterval
    }

    private func setReachedFullAt(_ moment: TimeInterval?) {
        if let moment {
            defaults.set(moment, forKey: StorageKey.nativeLimitTopUpReachedFullAt)
        } else {
            defaults.removeObject(forKey: StorageKey.nativeLimitTopUpReachedFullAt)
        }
    }
}
