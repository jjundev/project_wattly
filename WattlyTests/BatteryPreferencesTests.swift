// WattlyTests/BatteryPreferencesTests.swift
import Testing
import Foundation
@testable import Wattly

@Suite struct BatteryPreferencesTests {
    private func freshDefaults() -> UserDefaults {
        let name = "BatteryPreferencesTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    /// `integer(forKey:)`는 없는 키에 0을 준다. 감사에서 잡힌 두 버그(알림 false, Sailing 0→1)가 이 줄에서 죽는다.
    @Test func absentKeysReadAsTheDeclaredDefaults() {
        let prefs = BatteryPreferences(defaults: freshDefaults())
        #expect(prefs == .standard)
        #expect(prefs.sailingDelta == 5)
        #expect(prefs.manualDischargeTarget == 80)
        #expect(prefs.heatProtectionThresholdCelsius == 35)
        #expect(freshDefaults().wattlyBool(StorageKey.batteryScheduleNotificationsEnabled,
                                           default: Defaults.batteryScheduleNotificationsEnabled) == true)
    }

    @Test func writeThenReadRoundTripsEveryField() {
        let d = freshDefaults()
        var prefs = BatteryPreferences.standard
        prefs.limitEnabled = true; prefs.limitPercentage = 85
        prefs.sailingEnabled = true; prefs.sailingDelta = 4
        prefs.heatProtectionEnabled = true; prefs.heatProtectionThresholdCelsius = 38
        prefs.autoDischargeEnabled = true; prefs.manualDischargeTarget = 70
        prefs.clamshellDischargeEnabled = true
        prefs.write(to: d)
        #expect(BatteryPreferences(defaults: d) == prefs)
    }

    @Test func writeOnlyTouchesChangedKeys() {
        let d = freshDefaults()
        BatteryPreferences.standard.write(to: d)
        // 기본값과 같은 값은 쓰지 않는다 — 키가 여전히 없다.
        #expect(d.object(forKey: StorageKey.batteryLimitPercentage) == nil)
        var changed = BatteryPreferences.standard
        changed.limitPercentage = 90
        changed.write(to: d)
        #expect(d.object(forKey: StorageKey.batteryLimitPercentage) as? Int == 90)
        #expect(d.object(forKey: StorageKey.batterySailingDelta) == nil)
    }

    @Test func configurationAppliesTheSailingAndClampRules() {
        var prefs = BatteryPreferences.standard
        prefs.limitEnabled = true; prefs.limitPercentage = 85
        prefs.sailingEnabled = false; prefs.sailingDelta = 5
        prefs.manualDischargeTarget = 100
        let off = prefs.configuration(clamshellDischargeAllowed: true)
        #expect(off.lowerHysteresisDelta == 2)
        #expect(off.manualDischargeTarget == BatterySectionPresentation.manualDischargeTargetRange.upperBound)
        #expect(off.clamshellDischargeAllowed == true)
        #expect(off.topUpActive == false && off.manualDischargeActive == false && off.calibrationActive == false)

        prefs.sailingEnabled = true
        #expect(prefs.configuration(clamshellDischargeAllowed: false).lowerHysteresisDelta == 5)
    }

    @Test func calibrationSnapshotCarriesTheRawStoredValues() {
        var prefs = BatteryPreferences.standard
        prefs.sailingEnabled = true; prefs.sailingDelta = 3; prefs.manualDischargeTarget = 100
        let snap = prefs.calibrationSnapshot
        #expect(snap.sailingEnabled == true && snap.sailingDelta == 3)
        // 스냅샷은 원복용 원값이다. 클램프는 전송 시점(`configuration`)에만 한다.
        #expect(snap.manualDischargeTarget == 100)
    }

    /// 브리지가 `.onChange(of: preferences)` 하나로 관찰하므로, 모든 필드가 동등성에 참여해야 한다.
    @Test func everyFieldParticipatesInEquality() {
        let base = BatteryPreferences.standard
        var variants: [BatteryPreferences] = []
        var v = base; v.limitEnabled.toggle(); variants.append(v)
        v = base; v.limitPercentage += 1; variants.append(v)
        v = base; v.sailingEnabled.toggle(); variants.append(v)
        v = base; v.sailingDelta += 1; variants.append(v)
        v = base; v.heatProtectionEnabled.toggle(); variants.append(v)
        v = base; v.heatProtectionThresholdCelsius += 1; variants.append(v)
        v = base; v.autoDischargeEnabled.toggle(); variants.append(v)
        v = base; v.manualDischargeTarget += 1; variants.append(v)
        v = base; v.clamshellDischargeEnabled.toggle(); variants.append(v)
        #expect(variants.count == 9)
        for variant in variants { #expect(variant != base) }
    }
}
