import Foundation

/// Build-target placeholder. The XPC listener and all fan-control behavior are introduced
/// by later B2 slices; this target deliberately performs no hardware access or writes.
enum WattlyFanDaemon {}
