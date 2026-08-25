import Foundation
import Testing
@testable import Wattly

@Suite struct BatteryControlKeysTests {
    @Test func modernReadbackUsesTheFourByteCHTEGate() {
        let gate = BatteryControlKeys.readGate(registerSet: .modern) { key in
            key == "CHTE" ? (type: "ui32", bytes: [1, 0, 0, 0]) : nil
        }
        #expect(gate == .inhibited(appliedLimitPercentage: nil))
    }

    @Test func modernReadbackRequiresExactFourByteCHTEPayloads() {
        let allowed = BatteryControlKeys.readGate(registerSet: .modern) { _ in
            (type: "ui32", bytes: [0, 0, 0, 0])
        }
        let malformedHighByte = BatteryControlKeys.readGate(registerSet: .modern) { _ in
            (type: "ui32", bytes: [0, 0, 0, 1])
        }
        #expect(allowed == .allowed)
        #expect(malformedHighByte == .unreadable)
    }

    @Test func legacyReadbackUsesCH0BAndRejectsUnknownBytes() {
        let allowed = BatteryControlKeys.readGate(registerSet: .legacy) { _ in
            (type: "ui8 ", bytes: [0])
        }
        let malformed = BatteryControlKeys.readGate(registerSet: .legacy) { _ in
            (type: "ui8 ", bytes: [7])
        }
        #expect(allowed == .allowed)
        #expect(malformed == .unreadable)
    }

    @Test func intelReadbackCarriesTheAppliedBCLMLimit() {
        let gate = BatteryControlKeys.readGate(registerSet: .intel) { _ in
            (type: "ui8 ", bytes: [85])
        }
        #expect(gate == .inhibited(appliedLimitPercentage: 85))
    }

    @Test func handsOffRegisterSetsHaveNoReadableGate() {
        for registerSet: BatteryControlRegisterSet in [.firmwareManaged, .unsupported] {
            #expect(BatteryControlKeys.readGate(registerSet: registerSet) { _ in nil }
                    == .unreadable)
        }
    }

    @Test func modernMacsWriteTheFourByteCHTEFlag() {
        let inhibit = BatteryControlKeys.writes(inhibited: true, registerSet: .modern, targetLimit: 85)
        #expect(inhibit == [BatteryControlKeyWrite(key: "CHTE",
                                                   bytes: [0x01, 0x00, 0x00, 0x00],
                                                   isRequired: true)])

        let release = BatteryControlKeys.writes(inhibited: false, registerSet: .modern, targetLimit: 85)
        #expect(release == [BatteryControlKeyWrite(key: "CHTE",
                                                   bytes: [0x00, 0x00, 0x00, 0x00],
                                                   isRequired: true)])
    }

    @Test func modernReleaseAtFullTargetIsThePayloadTheSafetyUnlatchSends() {
        // `releaseChargingControlAndVerify` uses exactly this call — `inhibited: false`,
        // `targetLimit: 100` — for a `.firmwareManaged` Mac that still exposes CHTE. Pinning the pure
        // register table here covers the payload even though `WattlyFanDaemon` has no test host.
        let release = BatteryControlKeys.writes(inhibited: false, registerSet: .modern, targetLimit: 100)
        #expect(release == [BatteryControlKeyWrite(key: "CHTE",
                                                   bytes: [0x00, 0x00, 0x00, 0x00],
                                                   isRequired: true)])
    }

    @Test func theModernFlagIgnoresTheTargetBecauseChargingIsBinary() {
        // CHTE is a gate, not a ceiling. The engine holds the target by flipping the gate at the
        // threshold — if this row ever encoded the percentage it would be lying about the hardware.
        let at80 = BatteryControlKeys.writes(inhibited: true, registerSet: .modern, targetLimit: 80)
        let at95 = BatteryControlKeys.writes(inhibited: true, registerSet: .modern, targetLimit: 95)
        #expect(at80 == at95)
    }

    @Test func legacyMacsWriteBothChargerRegistersAndOnlyCH0BIsRequired() {
        let writes = BatteryControlKeys.writes(inhibited: true, registerSet: .legacy, targetLimit: 85)
        #expect(writes.count == 2)
        #expect(writes[0] == BatteryControlKeyWrite(key: "CH0B", bytes: [0x02], isRequired: true))
        #expect(writes[1] == BatteryControlKeyWrite(key: "CH0C", bytes: [0x02], isRequired: false))
        #expect(writes.filter(\.isRequired).map(\.key) == ["CH0B"])
    }

    @Test func legacyReleaseRestoresBothChargerRegisters() {
        let writes = BatteryControlKeys.writes(inhibited: false, registerSet: .legacy, targetLimit: 100)
        #expect(writes.map(\.key) == ["CH0B", "CH0C"])
        #expect(writes.allSatisfy { $0.bytes == [0x00] })
    }

    @Test func intelWritesTheCeilingItself() {
        let inhibit = BatteryControlKeys.writes(inhibited: true, registerSet: .intel, targetLimit: 85)
        #expect(inhibit == [BatteryControlKeyWrite(key: "BCLM", bytes: [85], isRequired: true)])

        let release = BatteryControlKeys.writes(inhibited: false, registerSet: .intel, targetLimit: 85)
        #expect(release == [BatteryControlKeyWrite(key: "BCLM", bytes: [100], isRequired: true)])
    }

    @Test func intelCeilingIsClampedIntoAByte() {
        let writes = BatteryControlKeys.writes(inhibited: true, registerSet: .intel, targetLimit: 4000)
        #expect(writes[0].bytes == [255])
    }

    @Test func unsupportedHardwareHasNothingToWrite() {
        #expect(BatteryControlKeys.writes(inhibited: true, registerSet: .unsupported, targetLimit: 85).isEmpty)
        #expect(BatteryControlKeys.writes(inhibited: false, registerSet: .unsupported, targetLimit: 85).isEmpty)
    }

    @Test func firmwareManagedHardwareHasNothingToWrite() {
        // macOS 27 firmware owns the limit. Writing anything here is worse than doing nothing, so
        // the table hands back the same empty list it uses for a Mac with no register at all.
        #expect(BatteryControlKeys.writes(inhibited: true, registerSet: .firmwareManaged, targetLimit: 85).isEmpty)
        #expect(BatteryControlKeys.writes(inhibited: false, registerSet: .firmwareManaged, targetLimit: 85).isEmpty)
    }

    @Test func onlyTheDrivableGenerationsMayBeWritten() {
        #expect(BatteryControlRegisterSet.modern.canDriveCharging)
        #expect(BatteryControlRegisterSet.legacy.canDriveCharging)
        #expect(BatteryControlRegisterSet.intel.canDriveCharging)
        #expect(!BatteryControlRegisterSet.firmwareManaged.canDriveCharging)
        #expect(!BatteryControlRegisterSet.unsupported.canDriveCharging)
    }

    @Test func probeOrderPrefersTheNewerRegisterSet() {
        // A preference, not a measured requirement — see the doc comment on `probeOrder`.
        #expect(BatteryControlKeys.probeOrder.map(\.key) == ["CHTE", "CH0B", "BCLM"])
        #expect(BatteryControlKeys.probeOrder.map(\.registerSet) == [.modern, .legacy, .intel])
    }

    @Test func selectionPicksTheGenerationTheHardwareActuallyAnswers() {
        // Tahoe-era firmware: CHTE present at 4 bytes, the older pair absent.
        #expect(BatteryControlKeys.registerSet { $0 == "CHTE" ? ("ui32", 4) : nil } == .modern)
        // Pre-Tahoe firmware: CH0B present at one byte.
        #expect(BatteryControlKeys.registerSet { $0 == "CH0B" ? ("hex_", 1) : nil } == .legacy)
        // An Intel Mac.
        #expect(BatteryControlKeys.registerSet { $0 == "BCLM" ? ("ui8", 1) : nil } == .intel)
        // A desktop with no charge control at all.
        #expect(BatteryControlKeys.registerSet { _ in nil } == .unsupported)
    }

    @Test func firmwareManagedKeysWinOverEveryDrivableRegister() {
        // macOS 27 firmware can sit on a machine that still answers to one of the drivable
        // registers. Taking that register would drive it out from under the firmware that owns the
        // charger, so the firmware keys win over every one of them — not just over CHTE.
        func probe(alongside key: String, size: Int) -> BatteryControlRegisterSet {
            BatteryControlKeys.registerSet {
                switch $0 {
                case "bfF0", "bfD0", "bfE0": return ("ui32", 4)
                case key: return ("ui32", size)
                default: return nil
                }
            }
        }
        #expect(probe(alongside: "CHTE", size: 4) == .firmwareManaged)
        #expect(probe(alongside: "CH0B", size: 1) == .firmwareManaged)
        #expect(probe(alongside: "BCLM", size: 1) == .firmwareManaged)

        // Size is deliberately not checked on these, so an unfamiliar payload width still switches
        // the feature off rather than falling through to a drivable register.
        let oddWidths = BatteryControlKeys.registerSet {
            ["bfF0", "bfD0", "bfE0"].contains($0) ? ("hex_", 2) : ("ui32", 4)
        }
        #expect(oddWidths == .firmwareManaged)
    }

    @Test func theDecidingFirmwareKeysAreEnoughWithoutTheThird() {
        // `bfD0` is excluded from the test on purpose, so a macOS 27 Mac that names its upper-limit
        // key something else still stands the feature down instead of being driven through CHTE.
        let withoutUpper = BatteryControlKeys.registerSet {
            switch $0 {
            case "bfF0", "bfE0": return ("ui32", 4)
            case "CHTE": return ("ui32", 4)
            default: return nil
            }
        }
        #expect(withoutUpper == .firmwareManaged)

        // ...and firmware-managed is reported even when no drivable register is present at all,
        // rather than collapsing into the "this Mac has no charge control" answer.
        let firmwareOnly = BatteryControlKeys.registerSet {
            ["bfF0", "bfE0"].contains($0) ? ("ui32", 4) : nil
        }
        #expect(firmwareOnly == .firmwareManaged)
    }

    @Test func aLoneFirmwareKeyDoesNotDisableWorkingHardware() {
        // Tahoe firmware exposes bfD0 on its own as a 2-byte read-only key — measured on the M5 this
        // feature was developed on, where the charge limit works through CHTE. A check that let a
        // single unfamiliar key vote would turn the limit off on every machine that works today.
        let m5 = BatteryControlKeys.registerSet {
            switch $0 {
            case "bfD0": return ("hex_", 2)
            case "CHTE": return ("ui32", 4)
            default: return nil
            }
        }
        #expect(m5 == .modern)

        // The same holds for either deciding key on its own: two are required together.
        for lone in ["bfF0", "bfE0"] {
            let onlyOne = BatteryControlKeys.registerSet {
                switch $0 {
                case lone: return ("ui32", 4)
                case "CHTE": return ("ui32", 4)
                default: return nil
                }
            }
            #expect(onlyOne == .modern)
        }
    }

    @Test func aKeyOfTheWrongSizeIsTreatedAsAbsent() {
        // A register that answers but is not the shape the table writes would fail every write with
        // no way to tell that apart from broken hardware. Fall through instead of trusting it.
        #expect(BatteryControlKeys.registerSet { $0 == "CHTE" ? ("ui8", 1) : nil } == .unsupported)

        // ...and falling through is what lets a machine with a malformed CHTE still use CH0B.
        let bothButModernIsWrong = BatteryControlKeys.registerSet {
            switch $0 {
            case "CHTE": return ("ui8", 1)
            case "CH0B": return ("hex_", 1)
            default: return nil
            }
        }
        #expect(bothButModernIsWrong == .legacy)
    }

    @Test func drivableRegisterSetSurvivesTheFirmwareManagedVerdictOnModernHardware() {
        // This is the exact pair `SMCBatteryControlHardware` needs on a Mac that took a macOS 27
        // firmware update while `CHTE == 1` was still latched from the old firmware: `registerSet`
        // must say `.firmwareManaged` (so the engine never drives it again), while
        // `drivableRegisterSet` must still say `.modern` (so the dedicated verified-release path
        // retains CHTE as its safety register). Losing either half of this pair is the bug — the
        // firmware verdict swallowing the drivable answer would leave `CHTE` with nobody to clear it.
        func probe(_ key: String) -> (type: String, size: Int)? {
            switch key {
            case "bfF0", "bfE0": return ("ui32", 4)
            case "CHTE": return ("ui32", 4)
            default: return nil
            }
        }
        #expect(BatteryControlKeys.registerSet(probing: probe) == .firmwareManaged)
        #expect(BatteryControlKeys.drivableRegisterSet(probing: probe) == .modern)
    }

    @Test func drivableRegisterSetSurvivesTheFirmwareManagedVerdictOnLegacyHardware() {
        // Same pairing, on a pre-Tahoe Mac that somehow already picked up the firmware-managed keys:
        // `.firmwareManaged` for the policy question, `.legacy` for the mechanical one, so the
        // dedicated verified release goes out through CH0B instead of CHTE.
        func probe(_ key: String) -> (type: String, size: Int)? {
            switch key {
            case "bfF0", "bfE0": return ("ui32", 4)
            case "CH0B": return ("hex_", 1)
            default: return nil
            }
        }
        #expect(BatteryControlKeys.registerSet(probing: probe) == .firmwareManaged)
        #expect(BatteryControlKeys.drivableRegisterSet(probing: probe) == .legacy)
    }

    @Test func drivableRegisterSetIsUnsupportedWhenFirmwareManagedHasNoDrivableRegisterUnderneath() {
        // A firmware-managed Mac that exposes none of CHTE/CH0B/BCLM has nothing for the dedicated
        // verified release to write through — `drivableRegisterSet` must say `.unsupported` so
        // `SMCBatteryControlHardware` reports the verified release as not controllable rather than
        // sending it to a key that was never there.
        func probe(_ key: String) -> (type: String, size: Int)? {
            switch key {
            case "bfF0", "bfE0": return ("ui32", 4)
            default: return nil
            }
        }
        #expect(BatteryControlKeys.registerSet(probing: probe) == .firmwareManaged)
        #expect(BatteryControlKeys.drivableRegisterSet(probing: probe) == .unsupported)
    }

    @Test func measuredKeyInfoResultKeepsTheModernReleaseProbeDrivable() {
        func reply(for key: String) -> BatteryControlKeyProbeResult {
            switch key {
            case "CHTE":
                return .fromSMCKeyInfo(
                    kernelSucceeded: true,
                    smcResult: 0,
                    type: "ui32",
                    size: 4)
            case "CH0B", "BCLM":
                return .fromSMCKeyInfo(
                    kernelSucceeded: true,
                    smcResult: 132,
                    type: "",
                    size: 0)
            default:
                return .uncertain
            }
        }

        #expect(reply(for: "CH0B") == .confirmedAbsent)
        #expect(BatteryControlKeyProbeResult.fromSMCKeyInfo(
            kernelSucceeded: true,
            smcResult: 135,
            type: "",
            size: 0) == .uncertain)
        #expect(BatteryControlKeyProbeResult.fromSMCKeyInfo(
            kernelSucceeded: false,
            smcResult: 0,
            type: "ui32",
            size: 4) == .uncertain)
        #expect(BatteryControlKeyProbeResult.fromSMCKeyInfo(
            kernelSucceeded: true,
            smcResult: 0,
            type: "ui32",
            size: 0) == .uncertain)
        #expect(BatteryControlKeys.runtimeDrivableRegisterProbe(probing: reply) == .drivable(.modern))
    }

    @Test func runtimeNoLatchProofRequiresConfirmedAbsenceForEveryCandidate() throws {
        // A failed key-info transport and a reachable key with a shape we do not recognise are
        // fundamentally different from proof that a latch key is absent. Neither may mint the
        // readback-free no-latch release proof.
        let absent = BatteryControlKeys.runtimeDrivableRegisterProbe { _ in .confirmedAbsent }
        let transportFailure = BatteryControlKeys.runtimeDrivableRegisterProbe { key in
            key == "CH0B" ? .uncertain : .confirmedAbsent
        }
        let unexpectedSize = BatteryControlKeys.runtimeDrivableRegisterProbe { key in
            key == "CHTE" ? .readable(type: "ui32", size: 1) : .confirmedAbsent
        }
        let unexpectedType = BatteryControlKeys.runtimeDrivableRegisterProbe { key in
            key == "CHTE" ? .readable(type: "flt ", size: 4) : .confirmedAbsent
        }

        #expect(absent == .noDrivableRegisterAtRuntime)
        #expect(transportFailure == .unsafeToRelease)
        #expect(unexpectedSize == .unsafeToRelease)
        #expect(unexpectedType == .unsafeToRelease)
    }

    @Test func runtimeReleaseProbeKeepsTheNormalGenerationCandidate() {
        let candidate = BatteryControlKeys.runtimeDrivableRegisterProbe { key in
            key == "CHTE" ? .readable(type: "ui32", size: 4) : .confirmedAbsent
        }
        #expect(candidate == .drivable(.modern))
    }

    @Test func runtimeReleaseProbeFailsClosedWhenAnotherLatchProbeIsUncertain() {
        // A known CHTE does not prove that a different reachable latch is clear. Release must not
        // skip that uncertainty merely because it has one familiar key it could write.
        let candidate = BatteryControlKeys.runtimeDrivableRegisterProbe { key in
            switch key {
            case "CHTE": return .readable(type: "ui32", size: 4)
            case "CH0B": return .uncertain
            default: return .confirmedAbsent
            }
        }
        #expect(candidate == .unsafeToRelease)
    }

    @Test func drivableRegisterSetIgnoresTheFirmwareKeysEntirely() {
        // `drivableRegisterSet` answers "which register could this Mac be driven through" and must
        // never consult `firmwareManagedKeys` — it stays true even when the app has decided not to
        // drive the Mac. This is this M5's actual measured shape: `bfD0` present read-only at 2
        // bytes, no `bfF0`/`bfE0`, `CHTE` present at 4 bytes. `registerSet` and `drivableRegisterSet`
        // agree here (both `.modern`), which is the ordinary case this feature has shipped on.
        func probe(_ key: String) -> (type: String, size: Int)? {
            switch key {
            case "bfD0": return ("hex_", 2)
            case "CHTE": return ("ui32", 4)
            default: return nil
            }
        }
        #expect(BatteryControlKeys.registerSet(probing: probe) == .modern)
        #expect(BatteryControlKeys.drivableRegisterSet(probing: probe) == .modern)
    }
}

@Suite struct BatteryControlKeysDischargeTests {
    @Test func dischargeKeyProbingAndWrites() {
        let registerSet = BatteryControlKeys.registerSet { key in
            if key == "CHIE" { return ("hex_", 1) }
            if key == "CHTE" { return ("ui32", 4) }
            return nil
        }
        #expect(registerSet.isDischargeSupported)
        let writesOn = BatteryControlKeys.dischargeWrites(active: true, registerSet: registerSet)
        #expect(writesOn.contains(where: { $0.key == "CHIE" && $0.bytes == [0x08] }))
        let writesOff = BatteryControlKeys.dischargeWrites(active: false, registerSet: registerSet)
        #expect(writesOff.contains(where: { $0.key == "CHIE" && $0.bytes == [0x00] }))
    }

    @Test func legacyRegisterSetSupportsDischarge() {
        let registerSet = BatteryControlKeys.registerSet { key in
            if key == "CH0B" { return ("hex_", 1) }
            return nil
        }
        #expect(registerSet.isDischargeSupported)
        let writesOn = BatteryControlKeys.dischargeWrites(active: true, registerSet: registerSet)
        #expect(writesOn == [BatteryControlKeyWrite(key: "CHIE", bytes: [0x08], isRequired: true)])
        let writesOff = BatteryControlKeys.dischargeWrites(active: false, registerSet: registerSet)
        #expect(writesOff == [BatteryControlKeyWrite(key: "CHIE", bytes: [0x00], isRequired: true)])
    }

    @Test func nonAppleSiliconOrUnsupportedRegisterSetsHaveNoDischargeWrites() {
        for registerSet: BatteryControlRegisterSet in [.intel, .firmwareManaged, .unsupported] {
            #expect(!registerSet.isDischargeSupported)
            #expect(BatteryControlKeys.dischargeWrites(active: true, registerSet: registerSet).isEmpty)
            #expect(BatteryControlKeys.dischargeWrites(active: false, registerSet: registerSet).isEmpty)
        }
    }
}

