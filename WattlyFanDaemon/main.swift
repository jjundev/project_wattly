import Foundation

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

let daemon = FanControlDaemon(
    allowedUID: uid_t(uid),
    hardware: hardware,
    batteryHardware: batteryHardware
)
daemon.run()
RunLoop.main.run()
