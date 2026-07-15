# Local fan-control helper installation

This is a personal, local-machine installation. It installs a root LaunchDaemon so Wattly can write the Apple SMC fan-control keys; it is not a distributable privileged-helper installer.

## Before installing

Wattly must be the only application controlling the fans. Quit and uninstall **Macs Fan Control** first. The installer also refuses to continue when either the Macs Fan Control app process or its `com.crystalidea.macsfancontrol.smcwrite` launchd helper is present.

Start from the repository root as the logged-in macOS user, not as root:

```zsh
./scripts/install-fan-helper.sh
```

The script builds the Debug daemon, substitutes the invoking user's UID into the launchd plist, then uses `sudo` to install a `root:wheel` helper and plist. It stops a prior Wattly service before reinstalling it, bootstraps the new service, kickstarts it, and confirms that launchctl can print the service. Do not run the installer through `sudo`; it deliberately records the login user's UID as the allowed client.

The in-app fan-control toggle remains **off** after installation. Do not enable it until the smoke test below is complete.

## Smoke test and operating limits

Before enabling the toggle, record the initial fan mode and target RPM for every fan in your test notes. Record the same values after the test and confirm that macOS has resumed control. The helper returns every controlled fan to **automatic** mode when control is released; macOS then owns the effective target RPM again.

When enabled, the curve target is clamped to each fan's hardware minimum and maximum, so it never commands a target below the system minimum. The daemon checks a heartbeat every five seconds and automatically releases fans to macOS **automatic** control if no heartbeat arrives for 15 seconds. It also releases control on app disable, SMC/sensor failure, sleep, and daemon termination.

For the first smoke test, enable the toggle briefly, verify the status and observed fan behavior, then disable it and confirm automatic mode. Perform a cold boot with Macs Fan Control still absent and leave the toggle off initially; this confirms the normal reboot state before any manual control is requested.

## Authorization limitation

The daemon authorizes callers by the UID written during installation and by the audit-token process executable basename `Wattly`. This is intentionally weak authorization: an executable owned by that local user can potentially use the same basename. It is accepted only for this machine's personal local-owner setup, and is not suitable for shared machines or distribution. There is no code-signature authorization in this ad-hoc build.

## Recovery and uninstall

If the smoke test fails, fan behavior is unexpected, or you need to return immediately to macOS control, disable the in-app toggle and run:

```zsh
./scripts/uninstall-fan-helper.sh
```

The uninstall script uses `sudo` to boot out the service before removing its plist and helper. Booting out the daemon also triggers its termination cleanup, which requests automatic fan mode. If the app is unavailable, run the uninstall script from Terminal and reboot; the helper is no longer present, so a subsequent boot remains in macOS automatic fan control.
