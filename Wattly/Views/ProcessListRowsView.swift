import AppKit
import SwiftUI

struct ProcessListRowPresentation: Identifiable, Equatable {
    let id: String
    let name: String
    let valueText: String
    let fractionPermille: Int
    let iconPath: String?

    var fraction: Double {
        Double(fractionPermille) / 1_000
    }
}

private func processFractionPermille(_ value: Double) -> Int {
    Int((min(1, max(0, value)) * 1_000).rounded())
}

func memoryProcessRowPresentations(_ processes: [ProcessUsage]) -> [ProcessListRowPresentation] {
    let maxBytes = processes.first?.footprintBytes ?? 0
    return processes.map { process in
        ProcessListRowPresentation(
            id: process.id,
            name: process.name,
            valueText: CardPresentation.gbText(process.footprintBytes),
            fractionPermille: processFractionPermille(
                barFraction(footprint: process.footprintBytes, maxBytes: maxBytes)),
            iconPath: process.iconPath)
    }
}

func powerProcessRowPresentations(_ processes: [ProcessPower]) -> [ProcessListRowPresentation] {
    let maxWatts = processes.first?.watts ?? 0
    return processes.map { process in
        ProcessListRowPresentation(
            id: process.id,
            name: process.name,
            valueText: CardPresentation.wattText(process.watts),
            fractionPermille: processFractionPermille(
                wattFraction(watts: process.watts, maxWatts: maxWatts)),
            iconPath: process.iconPath)
    }
}

@MainActor
final class ProcessAppIconCache {
    static let shared = ProcessAppIconCache { path in
        NSWorkspace.shared.icon(forFile: path)
    }

    private let cache = NSCache<NSString, NSImage>()
    private let load: (String) -> NSImage

    init(countLimit: Int = 128, load: @escaping (String) -> NSImage) {
        cache.countLimit = countLimit
        self.load = load
    }

    func image(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = load(path)
        cache.setObject(image, forKey: key)
        return image
    }
}

@MainActor
struct ProcessListRowsView: View, Equatable {
    let rows: [ProcessListRowPresentation]
    let tokens: Tokens
    let barColor: Color

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rows == rhs.rows
            && lhs.tokens == rhs.tokens
            && lhs.barColor == rhs.barColor
    }

    var body: some View {
        ForEach(rows) { row in
            HStack(spacing: 9) {
                processIcon(row.iconPath)
                    .frame(width: 15, height: 15)
                Text(row.name)
                    .font(WattlyFont.at(11, weight: .semibold))
                    .foregroundStyle(tokens.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 74, alignment: .leading)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(tokens.sparkFill)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(barColor)
                            .frame(width: geometry.size.width * row.fraction)
                    }
                }
                .frame(height: 6)
                Text(row.valueText)
                    .font(WattlyFont.at(10.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tokens.sub)
                    .frame(width: 46, alignment: .trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(row.name), \(row.valueText)")
        }
    }

    @ViewBuilder
    private func processIcon(_ path: String?) -> some View {
        if let path {
            Image(nsImage: ProcessAppIconCache.shared.image(for: path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 3).fill(tokens.sparkFill)
        }
    }
}
