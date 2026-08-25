import AppKit
import SwiftUI
import Testing
@testable import Wattly

struct ProcessListRowsViewTests {
    @Test func powerRowsIgnoreChangesBelowVisiblePrecision() {
        let a = [
            ProcessPower(id: "top", name: "Top", watts: 1.0, iconPath: "/Top.app"),
            ProcessPower(id: "second", name: "Second", watts: 0.5011, iconPath: "/Second.app"),
        ]
        let b = [
            ProcessPower(id: "top", name: "Top", watts: 1.0, iconPath: "/Top.app"),
            ProcessPower(id: "second", name: "Second", watts: 0.5012, iconPath: "/Second.app"),
        ]

        #expect(powerProcessRowPresentations(a) == powerProcessRowPresentations(b))
    }

    @Test func powerRowsChangeForVisibleValueOrIdentityChange() {
        let original = [
            ProcessPower(id: "top", name: "Top", watts: 1.0, iconPath: "/Top.app"),
            ProcessPower(id: "second", name: "Second", watts: 0.501, iconPath: "/Second.app"),
        ]
        let changedValue = [
            ProcessPower(id: "top", name: "Top", watts: 1.0, iconPath: "/Top.app"),
            ProcessPower(id: "second", name: "Second", watts: 0.511, iconPath: "/Second.app"),
        ]
        let changedIdentity = [
            ProcessPower(id: "new", name: "New", watts: 1.0, iconPath: "/New.app"),
            ProcessPower(id: "second", name: "Second", watts: 0.501, iconPath: "/Second.app"),
        ]

        #expect(powerProcessRowPresentations(original) != powerProcessRowPresentations(changedValue))
        #expect(powerProcessRowPresentations(original) != powerProcessRowPresentations(changedIdentity))
    }

    @Test func memoryRowsKeepCurrentTextAndRelativeBars() {
        let gib: UInt64 = 1_073_741_824
        let rows = memoryProcessRowPresentations([
            ProcessUsage(id: "a", name: "A", footprintBytes: 2 * gib, iconPath: "/A.app"),
            ProcessUsage(id: "b", name: "B", footprintBytes: gib, iconPath: "/B.app"),
        ])

        #expect(rows.map(\.id) == ["a", "b"])
        #expect(rows.map(\.valueText) == [CardPresentation.gbText(2 * gib), CardPresentation.gbText(gib)])
        #expect(rows.map(\.fractionPermille) == [1_000, 500])
    }

    @MainActor
    @Test func iconCacheLoadsOneImagePerPath() {
        var loads = 0
        let image = NSImage(size: NSSize(width: 16, height: 16))
        let cache = ProcessAppIconCache(countLimit: 8) { _ in
            loads += 1
            return image
        }

        let first = cache.image(for: "/Applications/A.app")
        let second = cache.image(for: "/Applications/A.app")

        #expect(first === image)
        #expect(second === image)
        #expect(loads == 1)
    }

    @MainActor
    @Test func equatableRowsIncludeThemeAndBarColor() {
        let rows = [ProcessListRowPresentation(
            id: "a", name: "A", valueText: "0.50 W",
            fractionPermille: 500, iconPath: "/A.app")]
        let dark = ProcessListRowsView(rows: rows, tokens: .dark, barColor: .red)

        #expect(dark == ProcessListRowsView(rows: rows, tokens: .dark, barColor: .red))
        #expect(dark != ProcessListRowsView(rows: rows, tokens: .light, barColor: .red))
        #expect(dark != ProcessListRowsView(rows: rows, tokens: .dark, barColor: .blue))
    }
}
