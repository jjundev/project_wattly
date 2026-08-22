import AppKit

/// Runs the privileged-helper install while keeping a window alive across the admin-auth dialog.
///
/// Wattly is an accessory (LSUIElement) app, and the auth dialog deactivates it long enough for
/// macOS to destroy the Settings window — reopening it afterwards proved unreliable. So a regular
/// activation policy is held for the duration of the install (a regular app keeps its windows when
/// deactivated) and the window is re-fronted with `orderFrontRegardless` only — NOT `activate`,
/// which would steal keyboard focus from the password field. The menubar-only policy is restored
/// once the window is back up front.
///
/// Both the fan and the battery client drive this; it is one copy on purpose.
@MainActor
enum PrivilegedHelperInstallSession {
    /// Installs the helper, runs `postInstall` before handing the window back, and returns `nil` on
    /// success or the failure (including a cancelled auth prompt).
    static func run(window: NSWindow?, postInstall: @MainActor () async -> Void) async -> Error? {
        let priorPolicy = NSApp.activationPolicy()
        let raised = priorPolicy != .regular
        if raised { NSApp.setActivationPolicy(.regular) }

        // Keep the window visible UNDER the auth panel for the whole prompt + script run (~seconds)
        // so it does not sink behind other apps. `install()` runs its `osascript` off the main
        // thread, so the main actor is free to run this loop while we await it.
        let keepVisible = Task { @MainActor in
            while !Task.isCancelled {
                window?.orderFrontRegardless()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }

        var failure: Error?
        do {
            try await FanHelperInstaller.install()
        } catch {
            failure = error
        }
        keepVisible.cancel()

        // Re-raise the window the INSTANT the auth dialog is gone — before `postInstall`, which
        // connects to the just-started daemon over XPC and can stall for several seconds.
        raiseFront(window)
        if failure == nil { await postInstall() }

        // Drop the transient Dock icon, then re-front once more (restoring `.accessory` while
        // another app is active can sink the window), with retries to win any late focus steal.
        if raised { NSApp.setActivationPolicy(priorPolicy) }
        for _ in 0..<3 {
            raiseFront(window)
            try? await Task.sleep(for: .milliseconds(300))
        }
        return failure
    }

    private static func raiseFront(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
