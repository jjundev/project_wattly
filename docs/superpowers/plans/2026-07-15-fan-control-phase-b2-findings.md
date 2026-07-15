# Fan Control (Phase B-2) — Feasibility Findings & Handoff

> **Status:** NOT built. This is a research/handoff doc for a future branch. Phase A (fan
> speed card) and Phase B-1 (fan curve model + Settings preview, no writes) are DONE and in
> this branch. Phase B-2 = actually driving the fan. On-device feasibility is **confirmed**;
> this captures everything the next session needs before writing the B-2 plan.

## TL;DR

**Manual fan control works on this machine (Mac17,2 / Apple M5, MacBook Pro).** Physically
verified on 2026-07-15 via a throwaway privileged spike: writing `F0md=1` (manual) then
`F0Tg=4500` spun the fan up audibly; restoring the originals + `F0md=0` returned it to
automatic idle. The user also already runs **Macs Fan Control**, which is independent proof.

The originally-grilled B-2 design was **wrong in two ways** that this research corrects:
1. The M5 mode key is **`F0md` (lowercase `md`)**, NOT `F0Md` (uppercase — that's M1–M4).
   The first spike falsely concluded "impossible" because it probed only the uppercase name.
2. The **`Ftst` unlock sequence is NOT needed on M5** (it doesn't exist here). On M1–M4 you
   must write `Ftst=1`, wait ~3 s, then retry the mode write; on M5 you write `F0md=1` directly.

Everything else from the grill still holds: **root is required** (a privileged helper), and
a self-installed LaunchDaemon via `sudo` is a valid path (no Developer ID needed) — this is
exactly how Macs Fan Control ships (`/Library/PrivilegedHelperTools/com.crystalidea.macsfancontrol.smcwrite`).

## On-device evidence (Mac17,2 / M5, macOS as of 2026-07-15)

Read-only key probe (unprivileged, uid 501):

| Key | Exists | Type | Value | Role |
|-----|--------|------|-------|------|
| `FNum` | ✅ | ui8 | 1 | fan count |
| `F0Ac` | ✅ | flt | ~2317 | actual RPM |
| `F0Mn` | ✅ | flt | **2317** | min RPM (matches ThermalForge's "2317 on M5") |
| `F0Mx` | ✅ | flt | **6550** | max RPM |
| `F0Tg` | ✅ | flt | ~2317 | **target RPM (write here to set speed)** |
| `F0md` | ✅ | **ui8** | 0/1 | **mode: 0=auto, 1=manual (write here to take control)** |
| `F0St` | ✅ | ui8 | 5 | status |
| `F0Md` (uppercase) | ❌ | — | — | absent (M1–M4 only) |
| `Ftst` | ❌ | — | — | absent (M1–M4 unlock only) |
| `FS!` | ❌ | — | — | absent (Intel only) |

Privileged write spike (sudo) — the working sequence:
```
[original] F0md=0/1  F0Tg=2317  F0Ac=2320  [min 2317, max 6550]
[write] F0md=1 (manual)  -> OK (accepted first try; on a cold machine, retry up to ~10s)
[write] F0Tg=4500        -> OK
   t+1s F0Ac ramping ...  (fan audibly spins up)
[RESULT] ✅ manual control accepted + physical spin-up
[restore] F0Tg <- original, F0md <- 0 (auto)  -> fan returns to idle
```
RPM values are little-endian IEEE-754 `flt`; `F0md`/`F0St` are `ui8`. (On Intel it's big-endian
`fpe2` fixed-point — not relevant here.)

## The M5 control mechanism (what B-2 must implement)

Confirmed against ThermalForge source (`Sources/ThermalForgeCore/FanControl.swift`,
`SMCKeys.swift`) + our on-device spike. Per-fan `n` (0-based; this Mac has 1 fan):

1. **Detect chip generation** by which mode key reads: `F{n}md` (lowercase) → M5; else
   `F{n}Md` (uppercase) → M1–M4. Detect `Ftst` presence (`getKeyInfo("Ftst").size > 0`) → M1–M4.
2. **Unlock / engage manual:**
   - M1–M4: write `Ftst=1`, sleep ~0.5 s, then poll `F{n}Md=1` until it succeeds (deadline ~10 s).
   - **M5 (this machine): write `F{n}md=1` directly**, poll until success (deadline ~10 s). No Ftst.
   - Firmware may reject early with SMC error **0x82** while `thermalmonitord` still holds the
     fan in system mode (3) — the retry loop is what wins control (the "few seconds delay" the
     user observed with MFC).
3. **Set speed:** write `F{n}Tg` = float RPM bytes. **Clamp to `[F{n}Mn, F{n}Mx]`** — never
   below min (fan can't spin slower) and never above max.
4. **Release:** write `F{n}md=0` (auto) → `thermalmonitord` reassumes control. SMC fan state
   also resets on reboot.

Minimal SMC write path (mirror of Wattly's existing read-only `SMCConnection.read`, extended
with cmd 6 = write; the read-only client is `Wattly/Core/SMC.swift`):
```swift
// keyInfo (cmd 9) to get dataType/dataSize, then write (cmd 6) with the value bytes.
func write(_ key: String, ki: KeyInfo, bytes: [UInt8]) -> kern_return_t {
    var p = Param(); p.key = fourCC(key); p.keyInfo = ki; p.data8 = 6 /* cmdWrite */
    // pack `bytes` into p.bytes[0..<dataSize], then IOConnectCallStructMethod(conn, 2, ...)
}
// mode:   write("F0md", ui8Info, [1])           // manual;  [0] = auto
// target: write("F0Tg", fltInfo, float32LE(rpm)) // rpm as little-endian Float32
```
**This write path MUST live behind the privileged helper, never in the unsigned GUI app**
(non-root writes fail; only root's `IOServiceOpen(AppleSMC)` connection can write these keys).

## Required architecture (privileged helper)

Same shape as Macs Fan Control's own design (validated on this machine):
- **Root LaunchDaemon** (self-installed via a `sudo` installer script; **no Developer ID / no
  notarization required** for this path — unlike `SMAppService`, which `agoodkind/macos-smc-fan`
  uses and which hard-requires a paid Developer ID). Installs a plist to `/Library/LaunchDaemons/`
  + the helper binary to `/Library/PrivilegedHelperTools/`.
- **App ↔ helper via XPC** (or a minimal local socket). App sends "set fan `n` to RPM" / "auto";
  helper does the SMC writes. Keep the interface tiny (one command surface).
- **Caller authorization:** ad-hoc binary hash changes each rebuild, so code-signature auth is
  weak; gate by uid + connecting-binary path / a shared token (known trade-off, documented in the
  original grill).

## Non-negotiable safety (from the grill + reinforced by ThermalForge)

- **Curve only RAISES the floor** — never command below the system's own requested minimum;
  hard-clamp to `[F{n}Mn, F{n}Mx]`.
- **Dead-man watchdog INSIDE the daemon:** revert `F{n}md=0` on XPC/heartbeat timeout, so app
  quit/crash/sleep returns the fan to macOS control (a userspace-only watchdog dies with the app
  → unsafe). ThermalForge uses a ~15 s heartbeat; mirror that.
- **Absolute safety override:** force max fans if any sensor ≥ 95 °C, always active (ThermalForge
  pattern). Never remove macOS thermal safety wholesale (that's TG Pro's risky "override" mode).
- **Control loop drives off the HOTTEST CPU sensor** (`hottestCPUCelsius` already exists in
  `Wattly/Core/Fan.swift` from B-1), not the steadier average.
- **Control loop lives in the daemon**, independent of the app's poll scheduler / card visibility
  (the B-1 findings + grill-review established this). The daemon can read SMC temps itself.

## Integration with the existing A/B-1 code

- `FanCurve` (`Wattly/Core/Fan.swift`) + `evaluate(inputCelsius:)` + `hottestCPUCelsius` are
  DONE and directly reusable as the control input → target RPM.
- `FanProvider` / `SMCFanTransport` are read-only today; B-2 adds a **separate** privileged
  writer, NOT a write method on the shared read connection.
- The B-1 Settings preview disclaimer ("실제 팬 제어는 아직 지원되지 않습니다") flips to a real
  toggle once B-2 ships; gate the control UI on `monitor.isPresent(.fan)` (already available).

## Reference implementations (read these first next session)

- **ThermalForge** — https://github.com/ProducerGuy/ThermalForge — tested on M5 Max (Mac17,7);
  `Sources/ThermalForgeCore/{SMCKeys,FanControl,SMCConnection,Daemon}.swift` are the closest map
  to what B-2 needs. MIT. The `F0md` lowercase + no-Ftst M5 path came from here.
- **agoodkind/macos-smc-fan** — https://github.com/agoodkind/macos-smc-fan — documents the
  `Ftst` unlock + the `thermalmonitord` System-Mode enforcement; uses `SMAppService` (Developer
  ID required — the path we are NOT taking).
- Context: exelban/stats #2928 (M3/M4 fan-control breakage), Macs Fan Control (crystalidea).

## Open decisions for the B-2 grill/plan (needs-you)

1. **Product intent:** Wattly replaces Macs Fan Control (user drops MFC to avoid the two apps
   fighting over `F0md`/`F0Tg`), OR B-2 detects a running MFC helper and refuses/warns. Two apps
   controlling one fan WILL conflict — must be handled.
2. **Distribution:** local/dev use (ad-hoc, sudo installer) vs. real distribution (Gatekeeper
   quarantine on the unsigned helper; weaker caller auth). Affects installer UX + auth model.
3. **Curve authority envelope:** "full control within a floor-only safety envelope" — confirm the
   exact bound (can the user ever command below stock idle? default: no).
4. **On a cold machine (MFC quit):** re-verify the `F0md=1` retry-to-engage timing without MFC's
   pre-conditioning (our confirming test ran with MFC's helper present). Budget for the ~few-second
   `thermalmonitord` yield the user observed.

## Throwaway spike code (not committed; regenerate if needed)

The three diagnostic Swift files lived only in the session scratchpad and are gone now:
`smc-key-probe.swift` (read-only key enumeration), `smc-write-spike.swift` (v1, wrong uppercase
key), `smc-control-spike.swift` (v2, correct `F0md` path + record-original/defer-restore). The
essential mechanism is captured in "The M5 control mechanism" above — that's enough to rebuild.
