import Foundation

if CommandLine.arguments.contains("--verify-battery-release") {
    guard let verifierSMC = SMCControlConnection() else { exit(74) }
    let verifierHardware = SMCBatteryControlHardware(smc: verifierSMC)
    let verification = verifierHardware.releaseChargingControlAndVerify()
    // 방전 중에 도우미가 교체·삭제되면 시스템 `SleepDisabled`가 고아로 남는다. 파일에 Wattly의
    // 소유 마커가 있을 때만 되돌린다 — 사용자가 직접 켜둔 값은 건드리지 않는다.
    // `try?`는 옵셔널을 평탄화하므로 `load()`의 `PersistedBatteryPolicy?`가 그대로 나온다.
    // `load()`는 `.battery-control.previous`가 남아 있으면 rename으로 롤백하는 부수효과가 있다 —
    // 데몬 시작과 같은 동작이라 여기서도 문제없다.
    if (try? BatteryPolicyFileStore().load())?.sleepInhibitedAt != nil {
        _ = IOPMSystemSleepInhibitor().setSleepDisabled(false)
    }
    exit(verification.isSafeToRemove ? 0 : 74)
}

let rawUID = ProcessInfo.processInfo.environment["WATTLY_ALLOWED_UID"] ?? ""
guard let uid = UInt32(rawUID), uid > 0 else {
    fputs("WATTLY_ALLOWED_UID is required\n", stderr)
    exit(78)
}
guard let smc = SMCControlConnection() else {
    fputs("Unable to open SMC control connection\n", stderr)
    exit(69)
}
guard let hardware = SMCFanControlHardware(smc: smc) else {
    fputs("Unable to open SMC fan control hardware\n", stderr)
    exit(69)
}
let batteryHardware = SMCBatteryControlHardware(smc: smc)
let batteryEngine = BatteryControlEngine(hardware: batteryHardware)
let batteryStore = BatteryPolicyFileStore()
let batteryCoordinator = BatteryControlCoordinator(
    ownerUID: uid,
    store: batteryStore,
    engine: batteryEngine,
    now: { Date().timeIntervalSince1970 },
    sleepInhibitor: IOPMSystemSleepInhibitor()
)

let daemon = FanControlDaemon(
    allowedUID: uid_t(uid),
    hardware: hardware,
    batteryCoordinator: batteryCoordinator
)
daemon.run()
do {
    try daemon.startPowerObservation()
} catch {
    fputs("Unable to register system power notifications\n", stderr)
    exit(71)
}
RunLoop.main.run()
