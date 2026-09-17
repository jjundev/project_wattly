import Foundation

/// 용량(mAh)·사이클·온도·실전류를 **출처와 무관하게** 한 형태로 모은 배터리 사실.
///
/// macOS 27(펌웨어 20457, 2026-09-17 Mac17,2 실측)부터 `AppleSmartBattery` 최상위 키
/// `AppleRawMaxCapacity`/`AppleRawCurrentCapacity`/`DesignCapacity`/`Temperature`/
/// `ChargingCurrent`가 사라졌다. mAh는 `BatteryData` 서브딕셔너리로 옮겨갔고, 같은 값이
/// SMC `B0RM`/`B0NC`/`B0DC`/`B0CT`/`B0AT`/`B0AC`로도 읽힌다. 디코딩과 우선순위 결정은
/// 여기 한 곳에만 있고(`BatteryPower`/`Temperature`와 같은 패턴), IOKit·SMC I/O는
/// `BatteryProvider`·`AppleSmartBatteryReader`·`FanControlDaemon`이 각자 한다.
struct BatteryFacts: Equatable, Sendable {
    var remainingMilliampHours: Int? = nil
    /// Nominal 충전 용량. Full-charge(`B0FC`)가 아니다 — 옛 `AppleRawMaxCapacity`의
    /// 관측 범위와 Apple 자체 "최대 용량 %"가 둘 다 Nominal 쪽이다(스펙 §3-1).
    var maxMilliampHours: Int? = nil
    var designMilliampHours: Int? = nil
    var cycleCount: Int? = nil
    var temperatureCelsius: Double? = nil
    /// 배터리 실전류 mA. 양수 = 충전, 음수 = 방전. 레지스트리는 주지 않고 SMC만 준다.
    var currentMilliamps: Int? = nil
}

enum BatteryFactsSource {
    /// 배터리 팩 온도의 그럴듯한 범위(°C). `BatteryProvider`가 예전부터 쓰던 값.
    static let temperatureRange: ClosedRange<Double> = 0...80

    /// SMC 읽기 클로저 → 사실. 없는 키·디코드 실패·0 이하 mAh·범위 밖 온도는 nil.
    /// 실측 타입: `B0RM`/`B0NC`/`B0DC`/`B0CT`/`B0AT` = ui16, `B0AC` = si16 (전부 LE).
    static func fromSMC(read: (String) -> (type: String, bytes: [UInt8])?) -> BatteryFacts {
        func int(_ key: String) -> Int? {
            guard let raw = read(key) else { return nil }
            return smcInt(raw.bytes, type: raw.type)
        }
        var facts = BatteryFacts()
        facts.remainingMilliampHours = positive(int("B0RM"))
        facts.maxMilliampHours = positive(int("B0NC"))
        facts.designMilliampHours = positive(int("B0DC"))
        facts.cycleCount = int("B0CT")
        facts.temperatureCelsius = smcTemperatureCelsius(read: read)
        facts.currentMilliamps = int("B0AC")
        return facts
    }

    /// 데몬 열 보호용 단일 키 읽기 — `B0AT`(centi-°C) 하나만 묻는다. 5초 watchdog마다 여섯 키를 읽고 다섯을 버리지 않기 위해서.
    static func smcTemperatureCelsius(read: (String) -> (type: String, bytes: [UInt8])?) -> Double? {
        guard let raw = read("B0AT"), let centi = smcInt(raw.bytes, type: raw.type) else { return nil }
        return batteryCelsius(rawCentiCelsius: centi, in: temperatureRange)
    }

    /// 레지스트리 → 사실. `topLevel`은 macOS 26 이하의 최상위 키, `batteryData`는 macOS 27의
    /// `BatteryData` 서브딕셔너리. 최상위 키가 있으면 그것이 이긴다(26 이하에서 오늘과
    /// 바이트 단위로 같은 값을 유지하기 위해서).
    static func fromRegistry(topLevel: [String: Int], batteryData: [String: Any]?) -> BatteryFacts {
        func sub(_ key: String) -> Int? { (batteryData?[key] as? NSNumber)?.intValue }
        var facts = BatteryFacts()
        facts.remainingMilliampHours = positive(topLevel["AppleRawCurrentCapacity"]) ?? positive(sub("RemainingCapacity"))
        facts.maxMilliampHours = positive(topLevel["AppleRawMaxCapacity"]) ?? positive(sub("NominalChargeCapacity"))
        facts.designMilliampHours = positive(topLevel["DesignCapacity"]) ?? positive(sub("DesignCapacity"))
        // 사이클은 macOS 27에서도 최상위 `CycleCount`가 남아 있고 `BatteryData`에는 없다 — 2단(최상위 → SMC `B0CT`)이 전부다.
        facts.cycleCount = topLevel["CycleCount"]
        facts.temperatureCelsius = topLevel["Temperature"].flatMap { batteryCelsius(rawCentiCelsius: $0, in: temperatureRange) }
        return facts
    }

    /// 필드별 `primary ?? fallback`. 호출자가 우선순위를 정한다(스펙: 레지스트리 → SMC).
    /// `fallback`은 primary에 빈칸이 있을 때만 평가된다 — macOS 26 이하처럼 레지스트리가 완전하면
    /// 폴링마다 SMC 6키를 읽고 버리는 일이 없다.
    static func merged(primary: BatteryFacts, fallback: @autoclosure () -> BatteryFacts) -> BatteryFacts {
        guard primary.remainingMilliampHours == nil || primary.maxMilliampHours == nil
                || primary.designMilliampHours == nil || primary.cycleCount == nil
                || primary.temperatureCelsius == nil || primary.currentMilliamps == nil else { return primary }
        let fallback = fallback()
        return BatteryFacts(
            remainingMilliampHours: primary.remainingMilliampHours ?? fallback.remainingMilliampHours,
            maxMilliampHours: primary.maxMilliampHours ?? fallback.maxMilliampHours,
            designMilliampHours: primary.designMilliampHours ?? fallback.designMilliampHours,
            cycleCount: primary.cycleCount ?? fallback.cycleCount,
            temperatureCelsius: primary.temperatureCelsius ?? fallback.temperatureCelsius,
            currentMilliamps: primary.currentMilliamps ?? fallback.currentMilliamps)
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }
}
