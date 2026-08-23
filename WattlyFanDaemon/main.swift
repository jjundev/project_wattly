import Foundation

if CommandLine.arguments.contains("--verify-battery-release") {
    guard let verifierSMC = SMCControlConnection() else { exit(74) }
    let verifierHardware = SMCBatteryControlHardware(smc: verifierSMC)
    let verdict = verifierHardware.releaseChargingControlAndVerify()
    exit(verdict.isSafeToRemove ? 0 : 74)
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
    now: { Date().timeIntervalSince1970 }
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
