import Testing
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Wattly

@MainActor
struct SnapshotGeneratorTests {

    actor DynamicMockProvider: MetricProvider {
        let kind: ProviderKind
        let samples: [MetricSample]
        private var index = 0

        init(kind: ProviderKind, samples: [MetricSample]) {
            self.kind = kind
            self.samples = samples
        }

        func read(at instant: ContinuousClock.Instant) async -> ProviderReading {
            guard !samples.isEmpty else { return .pending }
            let sample = samples[index % samples.count]
            index += 1
            return .value(sample)
        }
    }

    actor DynamicMockProcessProvider: MetricProvider, ProcessEnumerating {
        let kind: ProviderKind
        let samples: [MetricSample]
        private var index = 0

        init(kind: ProviderKind, samples: [MetricSample]) {
            self.kind = kind
            self.samples = samples
        }

        func read(at instant: ContinuousClock.Instant) async -> ProviderReading {
            guard !samples.isEmpty else { return .pending }
            let sample = samples[index % samples.count]
            index += 1
            return .value(sample)
        }

        func setEnumerating(_ enabled: Bool) async {}
    }

    /// Renders the complete, unclipped Stacked Cards popover with all 8 cards visible
    struct FullStackedPopoverView: View {
        let monitor: SystemMonitor
        let fanControl: FanControlClient
        @Environment(\.tokens) private var t

        var body: some View {
            VStack(spacing: 0) {
                // Native Popover Header
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        PulseWMark(lineWidth: 1.4)
                            .frame(width: 13, height: 10)
                        Text("Wattly")
                            .font(WattlyFont.at(13, weight: .bold))
                            .tracking(-0.13)
                            .foregroundStyle(t.text)
                        StatusDot(color: Tokens.statusGreen)
                            .padding(.leading, 1)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 2) {
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(t.faint)
                            .frame(width: 26, height: 26)
                        Image(systemName: "gearshape")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(t.faint)
                            .frame(width: 26, height: 26)
                        Image(systemName: "power")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(t.faint)
                            .frame(width: 26, height: 26)
                    }
                }
                .padding(EdgeInsets(top: 2, leading: 4, bottom: 12, trailing: 4))

                // All 8 cards with dynamic sparklines and live data
                VStack(spacing: 8) {
                    ForEach(CardKind.allCases) { card in
                        MetricCardView(
                            card: card,
                            state: monitor.cardState(card),
                            historyValues: monitor.historyValues(for: card, smoothed: false),
                            isExpanded: false
                        )
                    }
                }
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(t.panelBg))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(t.panelBorder, lineWidth: 1))
            .shadow(color: Tokens.shadowFar.color, radius: Tokens.shadowFar.radius, x: 0, y: Tokens.shadowFar.y)
            .shadow(color: Tokens.shadowNear.color, radius: Tokens.shadowNear.radius, x: 0, y: Tokens.shadowNear.y)
        }
    }

    /// Enhanced expanded card wrapper with dynamic, tall sparkline
    struct ExpandedCardWrapper: View {
        let card: CardKind
        let state: MetricState
        let history: [Double]
        @Environment(\.tokens) private var t

        var body: some View {
            VStack(spacing: 0) {
                MetricCardView(
                    card: card,
                    state: state,
                    historyValues: history,
                    isExpanded: true
                )
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(t.panelBg))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(t.panelBorder, lineWidth: 1))
            .shadow(color: Tokens.shadowFar.color, radius: Tokens.shadowFar.radius, x: 0, y: Tokens.shadowFar.y)
            .shadow(color: Tokens.shadowNear.color, radius: Tokens.shadowNear.radius, x: 0, y: Tokens.shadowNear.y)
        }
    }

    /// Authentic macOS Menu Bar Simulation Strip & Balanced Theme Showcase
    struct MacOSMenuBarSimulationView: View {
        let frame: Int
        @Environment(\.tokens) private var t

        var body: some View {
            VStack(spacing: 12) {
                // 1. Authentic macOS Menu Bar Strip
                HStack(spacing: 0) {
                    // Left: Apple Logo & Standard App Menus
                    HStack(spacing: 14) {
                        Image(systemName: "apple.logo")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.95))

                        Text("Wattly")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)

                        HStack(spacing: 11) {
                            Text("File").opacity(0.8)
                            Text("Edit").opacity(0.8)
                            Text("View").opacity(0.8)
                            Text("Window").opacity(0.8)
                            Text("Help").opacity(0.8)
                        }
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.white)
                    }

                    Spacer(minLength: 16)

                    // Right: Wattly Single Live Menu Bar Item (Hill Runner) + macOS System Status Items
                    HStack(spacing: 14) {
                        // Single Wattly Active Live Status Item (Hill Runner Template Style)
                        HStack(spacing: 5) {
                            HillRunnerMark(frame: frame, markerColor: .white)
                                .frame(width: 14, height: 14)
                            Text("CPU 24%")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .fixedSize()
                        }

                        // Standard macOS System Status Items
                        HStack(spacing: 12) {
                            Image(systemName: "wifi")
                                .font(.system(size: 12, weight: .medium))

                            HStack(spacing: 4) {
                                Text("68%")
                                    .font(.system(size: 12, weight: .regular))
                                    .lineLimit(1)
                                    .fixedSize()
                                Image(systemName: "battery.100")
                                    .font(.system(size: 12, weight: .medium))
                            }

                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 12, weight: .medium))

                            Image(systemName: "switch.2")
                                .font(.system(size: 12, weight: .medium))

                            Text("Mon 9:41 AM")
                                .font(.system(size: 12, weight: .regular))
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.82))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.35), radius: 8, x: 0, y: 3)

                // 2. Balanced 6-Theme Kinetic Motion Preview Badges (Monochrome Template Style)
                HStack(spacing: 8) {
                    themeBadge("Cooling Turbine", icon: AnyView(TurbineMark(frame: frame, markerColor: .white)), value: "1850 RPM")
                    themeBadge("Pulse Wave", icon: AnyView(PulseWaveMark(frame: frame, markerColor: .white)), value: "24%")
                    themeBadge("VU Meter", icon: AnyView(VUMeterMark(frame: frame, markerColor: .white)), value: "8.5W")
                    themeBadge("3D Cube", icon: AnyView(Cube3DMark(frame: frame, markerColor: .white)), value: "48°C")
                    themeBadge("Equalizer", icon: AnyView(EqualizerMark(frame: frame, markerColor: .white)), value: "38%")
                    themeBadge("Hill Runner", icon: AnyView(HillRunnerMark(frame: frame, markerColor: .white)), value: "CPU 45%")
                }
            }
            .padding(14)
            .frame(width: 720)
        }

        private func themeBadge(_ label: String, icon: AnyView, value: String) -> some View {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    icon.frame(width: 14, height: 14)
                    Text(value)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.85)))
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))

                Text(label)
                    .font(WattlyFont.at(9.5, weight: .medium))
                    .foregroundStyle(t.faint)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity)
        }
    }

    @MainActor
    private func setupRichMonitor(isEnglish: Bool) async -> (SystemMonitor, FanControlClient, [CardKind: MetricSample]) {
        FontRegistration.register()

        // 16-step dynamic wave sequences for realistic sparklines
        let cpuWattsSequence = [2.8, 3.2, 5.8, 4.1, 7.5, 6.2, 3.9, 8.4, 5.1, 9.2, 6.0, 3.5, 6.8, 4.4, 5.9, 3.82]
        let gpuWattsSequence = [0.8, 1.1, 2.4, 1.8, 3.9, 2.7, 1.2, 3.5, 2.1, 1.6, 2.9, 1.5, 2.2, 1.9, 2.0, 1.65]
        let cpuUsageSequence = [12.0, 15.5, 38.0, 24.0, 58.0, 44.0, 28.0, 52.0, 36.0, 20.0, 48.0, 32.0, 26.0, 34.0, 29.0, 24.5]
        let gpuUsageSequence = [4.0, 6.5, 22.0, 14.0, 36.0, 28.0, 11.0, 34.0, 19.0, 12.0, 26.0, 16.0, 20.0, 15.0, 22.0, 18.5]
        let memGBSequence =    [10.2, 10.4, 10.6, 10.7, 10.9, 11.0, 11.1, 11.2, 11.3, 11.3, 11.4, 11.4, 11.4, 11.4, 11.4, 11.4]
        let batWattsSequence = [6.2, 7.8, 12.4, 9.1, 14.5, 11.2, 8.4, 15.6, 10.3, 7.9, 13.8, 10.5, 11.2, 9.4, 12.0, 9.85]
        let cpuTempSequence =  [41.0, 42.5, 47.0, 51.0, 58.0, 53.5, 49.0, 54.5, 50.0, 46.0, 52.0, 48.0, 49.5, 47.0, 50.0, 48.2]
        let gpuTempSequence =  [39.0, 40.5, 43.5, 46.0, 48.5, 46.5, 44.0, 47.5, 44.5, 42.0, 45.5, 43.0, 44.0, 42.5, 45.0, 43.8]
        let fanRpmSequence =   [1200.0, 1200.0, 1350.0, 1600.0, 2200.0, 2700.0, 2400.0, 2100.0, 1950.0, 1800.0, 1900.0, 1850.0, 1850.0, 1850.0, 1850.0, 1850.0]

        let memProcesses = [
            ProcessUsage(id: "/Applications/Xcode.app", name: "Xcode", footprintBytes: 2450 * 1024 * 1024),
            ProcessUsage(id: "/Applications/Google Chrome.app", name: "Google Chrome", footprintBytes: 1620 * 1024 * 1024),
            ProcessUsage(id: "/Applications/Slack.app", name: "Slack", footprintBytes: 820 * 1024 * 1024),
            ProcessUsage(id: "/Applications/Ghostty.app", name: "Ghostty", footprintBytes: 210 * 1024 * 1024)
        ]

        let powerProcesses = [
            ProcessPower(id: "/Applications/Xcode.app", name: "Xcode", watts: 3.42),
            ProcessPower(id: "/Applications/Google Chrome.app", name: "Google Chrome", watts: 1.85),
            ProcessPower(id: "/Applications/Ghostty.app", name: "Ghostty", watts: 0.45)
        ]

        var powerSamples: [MetricSample] = []
        var cpuSamples: [MetricSample] = []
        var gpuSamples: [MetricSample] = []
        var memSamples: [MetricSample] = []
        var batSamples: [MetricSample] = []
        var tempSamples: [MetricSample] = []
        var fanSamples: [MetricSample] = []

        let pCoreName = isEnglish ? "P-Cores" : "P-코어"
        let eCoreName = isEnglish ? "E-Cores" : "E-코어"

        for i in 0..<16 {
            let cw = cpuWattsSequence[i]
            let gw = gpuWattsSequence[i]
            let tw = cw + gw + 0.12
            powerSamples.append(.power(PowerSample(
                totalW: tw,
                cpuW: cw,
                gpuW: gw,
                npuW: 0.12,
                processes: powerProcesses
            )))

            let cu = cpuUsageSequence[i]
            cpuSamples.append(.cpu(CPUSample(
                overall: cu,
                perfLevels: [
                    PerfLevelUsage(
                        name: "Performance",
                        usage: min(100, cu * 1.5),
                        cores: [cu * 1.7, cu * 1.4, cu * 1.6, cu * 1.3].map { min(100, $0) },
                        activeGHz: 3.49
                    ),
                    PerfLevelUsage(
                        name: "Efficiency",
                        usage: min(100, cu * 0.5),
                        cores: [cu * 0.6, cu * 0.5, cu * 0.5, cu * 0.4].map { min(100, $0) },
                        activeGHz: 2.18
                    )
                ]
            )))

            let gu = gpuUsageSequence[i]
            gpuSamples.append(.gpu(GPUSample(
                overall: gu,
                coreCount: 10,
                activeGHz: 1.28,
                rendererUsage: min(100, gu * 1.2),
                tilerUsage: min(100, gu * 0.75),
                inUseMemoryBytes: 850 * 1024 * 1024,
                allocMemoryBytes: 1400 * 1024 * 1024
            )))

            let mu = memGBSequence[i]
            memSamples.append(.memory(MemorySample(
                usedGB: mu,
                totalGB: 16.0,
                wiredGB: 3.2,
                compressedGB: 1.8,
                swapUsedGB: 0.25,
                processes: memProcesses,
                pressure: .normal,
                pressurePercent: 28
            )))

            let bw = batWattsSequence[i]
            batSamples.append(.battery(BatterySample(
                netW: bw,
                milliamps: Int(bw / 12.01 * 1000),
                volts: 12.01,
                charging: false,
                externalConnected: false,
                remainingWh: 48.2,
                maxWh: 52.0,
                timeRemainingMinutes: 285,
                efficiencyPercent: 96.2,
                cycleCount: 124,
                average1mW: 9.62,
                temperatureCelsius: 31.5
            )))

            let ct = cpuTempSequence[i]
            let gt = gpuTempSequence[i]
            tempSamples.append(.temperature(TemperatureSnapshot(
                cpu: .reading(TemperatureReading(
                    celsius: ct,
                    groups: [
                        TemperatureGroup(name: pCoreName, average: ct + 3.2, hottest: ct + 6.0),
                        TemperatureGroup(name: eCoreName, average: ct - 3.2, hottest: ct - 1.4)
                    ]
                )),
                gpu: .reading(TemperatureReading(
                    celsius: gt,
                    groups: [
                        TemperatureGroup(name: "GPU", average: gt, hottest: gt + 1.3)
                    ]
                ))
            )))

            let fr = fanRpmSequence[i]
            fanSamples.append(.fan(FanSample(fans: [
                FanReading(index: 0, actualRPM: fr, minRPM: 1200, maxRPM: 5800, targetRPM: fr)
            ])))
        }

        let providers: [any MetricProvider] = [
            DynamicMockProcessProvider(kind: .power, samples: powerSamples),
            DynamicMockProvider(kind: .cpu, samples: cpuSamples),
            DynamicMockProvider(kind: .gpu, samples: gpuSamples),
            DynamicMockProcessProvider(kind: .memory, samples: memSamples),
            DynamicMockProvider(kind: .battery, samples: batSamples),
            DynamicMockProvider(kind: .temperature, samples: tempSamples),
            DynamicMockProvider(kind: .fan, samples: fanSamples)
        ]

        let monitor = SystemMonitor(providers: providers)
        await monitor.setShownCards(Set(CardKind.allCases))
        monitor.setPanelVisible(true)

        // Ingest all 16 dynamic points to build real sparklines and populate states
        for _ in 0..<16 {
            await monitor.pollOnce()
        }

        let finalSampleMap: [CardKind: MetricSample] = [
            .power: powerSamples.last!,
            .cpu: cpuSamples.last!,
            .gpu: gpuSamples.last!,
            .mem: memSamples.last!,
            .battery: batSamples.last!,
            .cpuTemp: tempSamples.last!,
            .gpuTemp: tempSamples.last!,
            .fan: fanSamples.last!
        ]

        let statusDetail = isEnglish ? "Smart Curve Active" : "적용 중 · 사용자 지정 곡선으로 제어"
        let mockHandler: FanControlRequestHandler = { request in
            .success(FanControlServiceStatus(
                mode: .controlling,
                detail: statusDetail,
                updatedAt: Date().timeIntervalSince1970
            ))
        }
        let fanControl = FanControlClient(requestHandler: mockHandler)
        await fanControl.refreshStatus()

        return (monitor, fanControl, finalSampleMap)
    }

    @MainActor
    private func saveSnapshot<V: View>(
        view: V,
        filename: String,
        subfolder: String? = nil,
        targetWidth: CGFloat = 320,
        scale: CGFloat = 2.0
    ) {
        var outputDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/assets")
        if let subfolder = subfolder {
            outputDir = outputDir.appendingPathComponent(subfolder)
        }
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let fileURL = outputDir.appendingPathComponent(filename)

        let targetView = view
            .frame(width: targetWidth)
            .padding(14)
            .background(Color.clear)

        let hostingView = NSHostingView(rootView: targetView)
        hostingView.frame = NSRect(x: 0, y: 0, width: targetWidth + 28, height: 1600)
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let finalSize = CGSize(width: targetWidth + 28, height: max(fitting.height, 80))
        hostingView.frame = NSRect(origin: .zero, size: finalSize)
        hostingView.layoutSubtreeIfNeeded()

        let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)!
        rep.size = finalSize
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)

        let image = NSImage(size: finalSize)
        image.addRepresentation(rep)
        if let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            do {
                try png.write(to: fileURL)
                print("✅ Generated [\(subfolder ?? "root")]: \(filename) (\(Int(finalSize.width))x\(Int(finalSize.height)))")
            } catch {
                print("Write error for \(filename): \(error)")
            }
        }
    }

    /// Pure Swift & ImageIO Animated GIF Exporter using SwiftUI Views
    @MainActor
    private func exportAnimatedGIFFromSwiftUI<V: View>(
        viewGenerator: (Int) -> V,
        frameCount: Int = 24,
        frameDuration: Double = 0.065,
        filename: String,
        targetWidth: CGFloat = 720,
        scale: CGFloat = 2.0
    ) {
        let outputDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/assets")
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let fileURL = outputDir.appendingPathComponent(filename)

        var cgImages: [CGImage] = []

        for f in 0..<frameCount {
            let targetView = viewGenerator(f)
                .frame(width: targetWidth)
                .padding(14)
                .background(Color.clear)

            let hostingView = NSHostingView(rootView: targetView)
            let fitting = hostingView.fittingSize
            let size = CGSize(width: targetWidth + 28, height: max(fitting.height, 80))
            hostingView.frame = NSRect(origin: .zero, size: size)
            hostingView.layoutSubtreeIfNeeded()

            if let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) {
                rep.size = size
                hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
                if let cgImage = rep.cgImage {
                    cgImages.append(cgImage)
                }
            }
        }

        guard !cgImages.isEmpty else {
            print("❌ No frames generated for \(filename)")
            return
        }

        guard let destination = CGImageDestinationCreateWithURL(
            fileURL as CFURL,
            UTType.gif.identifier as CFString,
            cgImages.count,
            nil
        ) else {
            print("❌ Failed to create CGImageDestination for \(filename)")
            return
        }

        let fileProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0 // Infinite loop
            ]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameDuration,
                kCGImagePropertyGIFUnclampedDelayTime: frameDuration
            ]
        ]

        for cgImage in cgImages {
            CGImageDestinationAddImage(destination, cgImage, frameProperties as CFDictionary)
        }

        if CGImageDestinationFinalize(destination) {
            print("✅ Successfully exported native Animated GIF via ImageIO: \(filename) (\(cgImages.count) frames)")
        } else {
            print("❌ Failed to finalize GIF destination for \(filename)")
        }
    }

    private func generateLanguageScreenshots(language: String, subfolder: String?) async {
        UserDefaults.standard.set(language, forKey: StorageKey.appLanguage)
        UserDefaults.standard.set(ThemeMode.dark.rawValue, forKey: StorageKey.theme)
        let isEnglish = (language == "en")

        let (monitor, fanControl, sampleMap) = await setupRichMonitor(isEnglish: isEnglish)

        // Mock Battery Control State for optimal representative showcase
        UserDefaults.standard.set(true, forKey: StorageKey.batteryLimitEnabled)
        UserDefaults.standard.set(80, forKey: StorageKey.batteryLimitPercentage)
        UserDefaults.standard.set(true, forKey: StorageKey.batterySailingEnabled)
        UserDefaults.standard.set(5, forKey: StorageKey.batterySailingDelta)
        UserDefaults.standard.set(true, forKey: StorageKey.batteryHeatProtectionEnabled)
        UserDefaults.standard.set(true, forKey: StorageKey.batteryAutoDischargeEnabled)
        UserDefaults.standard.set(80, forKey: StorageKey.batteryManualDischargeTarget)

        let mockBatteryStatus = BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 80,
            isPowerAdapterConnected: true,
            detail: isEnglish ? "Charge limit reached · Powering from adapter" : "충전 제한 도달 · 전원 어댑터로만 작동",
            updatedAt: Date().timeIntervalSince1970,
            appliedLimitPercentage: 80,
            isHardwareSupported: true,
            detailReason: BatteryControlStatusReason(kind: .sailing, limitPercentage: 80, resumePercentage: 75),
            activity: .sailing,
            desiredConfiguration: BatteryControlConfiguration(
                enabled: true,
                limitPercentage: 80,
                lowerHysteresisDelta: 5,
                heatProtectionEnabled: true,
                topUpActive: false,
                autoDischargeEnabled: true,
                manualDischargeActive: false,
                manualDischargeTarget: 80
            ),
            actualGate: .inhibited(appliedLimitPercentage: 80),
            capabilities: [.persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1]
        )

        let mockBatteryHandler: BatteryControlClient.RequestHandler = { _ in
            if let data = try? BatteryControlCodec.encode(mockBatteryStatus) {
                return (data, nil)
            }
            return (nil, nil)
        }
        let batteryControlClient = BatteryControlClient(requestHandler: mockBatteryHandler)
        await batteryControlClient.refreshStatus()
        let scheduleCoordinator = BatteryScheduleCoordinator(batteryControl: batteryControlClient)

        // 1. Popover Mode A: Full Stacked Cards
        let modeAView = ThemedRoot {
            FullStackedPopoverView(monitor: monitor, fanControl: fanControl)
        }
        saveSnapshot(view: modeAView, filename: "popover-mode-a-stacked.png", subfolder: subfolder, targetWidth: 320)

        // 2. Popover Mode B: Compact Grid
        UserDefaults.standard.set(PanelMode.b.rawValue, forKey: StorageKey.panelMode)
        let modeBView = ThemedRoot {
            PopoverContentView(monitor: monitor, fanControl: fanControl)
        }
        saveSnapshot(view: modeBView, filename: "popover-mode-b-grid.png", subfolder: subfolder, targetWidth: 320)

        // 3. Popover Mode C: Hero (Processor Power)
        UserDefaults.standard.set(PanelMode.c.rawValue, forKey: StorageKey.panelMode)
        UserDefaults.standard.set(CardKind.power.rawValue, forKey: StorageKey.heroMetric)
        let modeCView = ThemedRoot {
            PopoverContentView(monitor: monitor, fanControl: fanControl)
        }
        saveSnapshot(view: modeCView, filename: "popover-mode-c-hero.png", subfolder: subfolder, targetWidth: 320)

        // 4. Expand Power
        let expandPowerView = ThemedRoot {
            ExpandedCardWrapper(
                card: .power,
                state: .value(sampleMap[.power]!),
                history: monitor.historyValues(for: .power, smoothed: false)
            )
        }
        saveSnapshot(view: expandPowerView, filename: "expand-power.png", subfolder: subfolder, targetWidth: 320)

        // 5. Expand CPU
        let expandCpuView = ThemedRoot {
            ExpandedCardWrapper(
                card: .cpu,
                state: .value(sampleMap[.cpu]!),
                history: monitor.historyValues(for: .cpu, smoothed: false)
            )
        }
        saveSnapshot(view: expandCpuView, filename: "expand-cpu.png", subfolder: subfolder, targetWidth: 320)

        // 6. Expand GPU
        let expandGpuView = ThemedRoot {
            ExpandedCardWrapper(
                card: .gpu,
                state: .value(sampleMap[.gpu]!),
                history: monitor.historyValues(for: .gpu, smoothed: false)
            )
        }
        saveSnapshot(view: expandGpuView, filename: "expand-gpu.png", subfolder: subfolder, targetWidth: 320)

        // 7. Expand Memory
        let expandMemView = ThemedRoot {
            ExpandedCardWrapper(
                card: .mem,
                state: .value(sampleMap[.mem]!),
                history: monitor.historyValues(for: .mem, smoothed: false)
            )
        }
        saveSnapshot(view: expandMemView, filename: "expand-memory.png", subfolder: subfolder, targetWidth: 320)

        // 8. Expand Battery
        let expandBatView = ThemedRoot {
            ExpandedCardWrapper(
                card: .battery,
                state: .value(sampleMap[.battery]!),
                history: monitor.historyValues(for: .battery, smoothed: false)
            )
        }
        saveSnapshot(view: expandBatView, filename: "expand-battery.png", subfolder: subfolder, targetWidth: 320)

        // 9. Expand Thermals (CPU & GPU)
        let expandThermalsView = ThemedRoot {
            VStack(spacing: 8) {
                MetricCardView(
                    card: .cpuTemp,
                    state: .value(sampleMap[.cpuTemp]!),
                    historyValues: monitor.historyValues(for: .cpuTemp, smoothed: false),
                    isExpanded: true
                )
                MetricCardView(
                    card: .gpuTemp,
                    state: .value(sampleMap[.gpuTemp]!),
                    historyValues: monitor.historyValues(for: .gpuTemp, smoothed: false),
                    isExpanded: true
                )
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Tokens.dark.panelBg))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Tokens.dark.panelBorder, lineWidth: 1))
            .shadow(color: Tokens.shadowFar.color, radius: Tokens.shadowFar.radius, x: 0, y: Tokens.shadowFar.y)
        }
        saveSnapshot(view: expandThermalsView, filename: "expand-thermals.png", subfolder: subfolder, targetWidth: 320)

        // 10. Settings: Battery Section
        let batterySectionView = ThemedRoot {
            VStack(spacing: 9) {
                SettingsBatterySection(batteryControl: batteryControlClient, scheduleCoordinator: scheduleCoordinator)
                SettingsBatteryDischargeSection(batteryControl: batteryControlClient)
            }
            .padding(16)
            .frame(width: 440)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        }
        saveSnapshot(view: batterySectionView, filename: "settings-battery.png", subfolder: subfolder, targetWidth: 440)

        // 11. Settings: Fan Curve Section
        UserDefaults.standard.set(true, forKey: StorageKey.fanControlEnabled)
        await fanControl.refreshStatus()
        let fanSectionView = ThemedRoot {
            VStack(spacing: 0) {
                SettingsFanCurveSection(monitor: monitor, fanControl: fanControl)
            }
            .padding(16)
            .frame(width: 440)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        }
        saveSnapshot(view: fanSectionView, filename: "settings-fan-curve.png", subfolder: subfolder, targetWidth: 440)

        // 12. Settings: Menu Bar Section
        let menubarSectionView = ThemedRoot {
            VStack(spacing: 0) {
                SettingsMenuBarSection(monitor: monitor)
            }
            .padding(16)
            .frame(width: 440)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        }
        saveSnapshot(view: menubarSectionView, filename: "settings-menubar.png", subfolder: subfolder, targetWidth: 440)

        // 13. Settings: Thresholds Section
        let thresholdSectionView = ThemedRoot {
            VStack(spacing: 0) {
                SettingsThresholdSection(showsFan: monitor.isPresent(.fan))
            }
            .padding(16)
            .frame(width: 440)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        }
        saveSnapshot(view: thresholdSectionView, filename: "settings-thresholds.png", subfolder: subfolder, targetWidth: 440)

        // 14. Settings: Display Section
        let displaySectionView = ThemedRoot {
            VStack(spacing: 0) {
                SettingsDisplaySection(monitor: monitor)
            }
            .padding(16)
            .frame(width: 440)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        }
        saveSnapshot(view: displaySectionView, filename: "settings-display.png", subfolder: subfolder, targetWidth: 440)
    }

    @Test func generateAllScreenshots() async {
        // 1. Korean Screenshots (into docs/assets/ and docs/assets/ko/)
        await generateLanguageScreenshots(language: "ko", subfolder: nil)
        await generateLanguageScreenshots(language: "ko", subfolder: "ko")

        // 2. English Screenshots (into docs/assets/en/)
        await generateLanguageScreenshots(language: "en", subfolder: "en")

        // 3. Menu Bar Themes Showcase (Static Snapshot)
        UserDefaults.standard.set("en", forKey: StorageKey.appLanguage)
        let menubarThemesView = ThemedRoot {
            MacOSMenuBarSimulationView(frame: 10)
        }
        saveSnapshot(view: menubarThemesView, filename: "menubar-styles-preview.png", subfolder: nil, targetWidth: 720)
        saveSnapshot(view: menubarThemesView, filename: "menubar-themes.png", subfolder: nil, targetWidth: 720)

        // 4. Native Animated GIF of macOS Menu Bar Simulation
        exportAnimatedGIFFromSwiftUI(
            viewGenerator: { frame in
                ThemedRoot {
                    MacOSMenuBarSimulationView(frame: frame)
                }
            },
            frameCount: 24,
            frameDuration: 0.065,
            filename: "menubar-live.gif",
            targetWidth: 720
        )
        exportAnimatedGIFFromSwiftUI(
            viewGenerator: { frame in
                ThemedRoot {
                    MacOSMenuBarSimulationView(frame: frame)
                }
            },
            frameCount: 24,
            frameDuration: 0.065,
            filename: "menubar-icon-motion.gif",
            targetWidth: 720
        )
    }
}
