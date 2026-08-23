import Foundation
import IOKit
import IOKit.pwr_mgt

final class SystemPowerObserver {
    enum RegistrationError: Error {
        case unavailable
    }

    private let onEvent: @Sendable (SystemPowerEvent) -> Void
    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    // These are `IOMessage.h`'s `iokit_common_msg` values. Swift cannot import the C macros
    // because their expansion contains a C-only cast, so retain the SDK-defined message values.
    private enum MessageType {
        static let canSystemSleep: UInt32 = 0xE0000270
        static let systemWillSleep: UInt32 = 0xE0000280
        static let systemWillPowerOn: UInt32 = 0xE0000320
        static let systemHasPoweredOn: UInt32 = 0xE0000300
    }

    init(onEvent: @escaping @Sendable (SystemPowerEvent) -> Void) {
        self.onEvent = onEvent
    }

    func start() throws {
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(
            context,
            &notificationPort,
            { context, _, messageType, messageArgument in
                guard let context else { return }
                let observer = Unmanaged<SystemPowerObserver>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                observer.receive(
                    messageType: messageType,
                    messageArgument: messageArgument)
            },
            &notifier)
        guard rootPort != 0, let notificationPort else {
            throw RegistrationError.unavailable
        }

        let source = IONotificationPortGetRunLoopSource(notificationPort)
            .takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func receive(
        messageType: UInt32,
        messageArgument: UnsafeMutableRawPointer?
    ) {
        let notificationID = Int(bitPattern: messageArgument)
        switch messageType {
        case MessageType.canSystemSleep:
            onEvent(.canSleep)
            IOAllowPowerChange(rootPort, notificationID)
        case MessageType.systemWillSleep:
            defer { IOAllowPowerChange(rootPort, notificationID) }
            onEvent(.willSleep)
        case MessageType.systemWillPowerOn:
            onEvent(.willPowerOn)
        case MessageType.systemHasPoweredOn:
            onEvent(.hasPoweredOn)
        default:
            break
        }
    }

    deinit {
        if notifier != 0 {
            _ = IODeregisterForSystemPower(&notifier)
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
        }
        if rootPort != 0 {
            IOServiceClose(rootPort)
        }
    }
}
