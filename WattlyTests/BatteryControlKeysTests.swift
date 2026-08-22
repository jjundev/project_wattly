import Foundation
import Testing
@testable import Wattly

@Suite struct BatteryControlKeysTests {
    @Test func appleSiliconInhibitWritesBothChargerRegisters() {
        let writes = BatteryControlKeys.writes(inhibited: true, isAppleSilicon: true, targetLimit: 85)
        #expect(writes.count == 2)
        #expect(writes[0] == BatteryControlKeyWrite(key: "CH0B", byte: 0x02, isRequired: true))
        #expect(writes[1] == BatteryControlKeyWrite(key: "CH0C", byte: 0x02, isRequired: false))
    }

    @Test func appleSiliconReleaseRestoresBothChargerRegisters() {
        let writes = BatteryControlKeys.writes(inhibited: false, isAppleSilicon: true, targetLimit: 100)
        #expect(writes.map(\.key) == ["CH0B", "CH0C"])
        #expect(writes.allSatisfy { $0.byte == 0x00 })
    }

    @Test func onlyCH0BIsRequiredSoAModelWithoutCH0CStillCounts() {
        let writes = BatteryControlKeys.writes(inhibited: true, isAppleSilicon: true, targetLimit: 80)
        #expect(writes.filter(\.isRequired).map(\.key) == ["CH0B"])
    }

    @Test func intelWritesTheCeilingItself() {
        let inhibit = BatteryControlKeys.writes(inhibited: true, isAppleSilicon: false, targetLimit: 85)
        #expect(inhibit == [BatteryControlKeyWrite(key: "BCLM", byte: 85, isRequired: true)])

        let release = BatteryControlKeys.writes(inhibited: false, isAppleSilicon: false, targetLimit: 85)
        #expect(release == [BatteryControlKeyWrite(key: "BCLM", byte: 100, isRequired: true)])
    }

    @Test func intelCeilingIsClampedIntoAByte() {
        let writes = BatteryControlKeys.writes(inhibited: true, isAppleSilicon: false, targetLimit: 4000)
        #expect(writes[0].byte == 255)
    }
}
