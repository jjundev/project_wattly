import Foundation

if CommandLine.arguments.contains("--verify-battery-release") {
    // 잠자기 정리를 SMC guard보다 **먼저** 한다. 둘은 아무 관계가 없는데(하나는 전원 관리
    // 설정, 하나는 AppleSMC 연결), 뒤에 두면 SMC 연결이 실패한 순간 `exit(74)`가 먼저 나가
    // 재부팅을 넘어 살아남는 `SleepDisabled`가 영원히 켜진 채 남는다 — Mac이 다시는 잠들지
    // 않는다. 하드웨어 계층이 이미 이상할 때가 이 경로를 탈 가능성이 가장 높은 때다.
    // 파일에 Wattly의 소유 마커가 있을 때만 되돌린다 — 사용자가 직접 켜둔 값은 건드리지 않는다.
    // `try?`는 옵셔널을 평탄화하므로 `load()`의 `PersistedBatteryPolicy?`가 그대로 나온다.
    // `load()`는 `.battery-control.previous`가 남아 있으면 rename으로 롤백하는 부수효과가 있다 —
    // 데몬 시작과 같은 동작이라 여기서도 문제없다.
    if (try? BatteryPolicyFileStore().load())?.sleepInhibitedAt != nil {
        // 정리 실패는 Mac이 영원히 잠들지 못하게 만드는 유일한 결과다. 종료 코드는 SMC 해제
        // 안전성을 보고하는 자리라 건드리지 않되, 실패는 이 파일의 다른 실패들처럼 남긴다.
        if !IOPMSystemSleepInhibitor().setSleepDisabled(false) {
            fputs("Unable to clear orphaned SleepDisabled\n", stderr)
        }
    }
    guard let verifierSMC = SMCControlConnection() else { exit(74) }
    let verifierHardware = SMCBatteryControlHardware(smc: verifierSMC)
    let verification = verifierHardware.releaseChargingControlAndVerify()
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
