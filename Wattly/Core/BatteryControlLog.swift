import OSLog

/// The battery-control path is the one part of this app that drives a privileged helper into SMC
/// register writes, and its failures are invisible from the outside: a reconcile that decides not
/// to write looks exactly like a reconcile that never ran. One `Logger`, defined once, so the
/// subsystem and category are not retyped at each call site.
enum BatteryControlLog {
    static let battery = Logger(subsystem: "dev.jjundev.Wattly", category: "battery-control")
}
