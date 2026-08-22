import Foundation
import Testing
@testable import Wattly

@Suite struct BatteryControlKeysTests {
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

    @Test func probeOrderPrefersTheNewerRegisterSet() {
        // An M5 exposes CHTE and not CH0B. Probing CH0B first would pick the legacy set on any Mac
        // that happens to expose both, which is the failure mode this ordering exists to prevent.
        #expect(BatteryControlKeys.probeOrder.map(\.key) == ["CHTE", "CH0B", "BCLM"])
        #expect(BatteryControlKeys.probeOrder.map(\.registerSet) == [.modern, .legacy, .intel])
    }
}
