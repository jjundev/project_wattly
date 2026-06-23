import Foundation

// Unrelated model dependencies needed when compiling the production PowerProvider
// into this standalone, app-target-excluded diagnostic executable.
enum MemoryPressure: Sendable, Equatable { case normal, warning, critical }
func appBundlePath(forExecutable path: String) -> String? { nil }

@main
struct PowerDifferentialProbe {
    static func main() async {
        let count = max(1, Int(CommandLine.arguments.dropFirst().first ?? "30") ?? 30)
        guard let subscription = IOReportEnergySubscription(),
              var previous = subscription.sample()?.energies else {
            fputs("IOReport Energy Model subscription failed\n", stderr)
            exit(2)
        }
        var previousInstant = ContinuousClock.now
        print("epoch,rollup_w,per_core_w,cluster_w,gpu_w,ane_w")

        for _ in 0..<count {
            try? await Task.sleep(for: .seconds(1))
            let before = ContinuousClock.now
            guard let capture = subscription.sample() else { continue }
            let after = ContinuousClock.now
            let instant = before.advanced(by: before.duration(to: after) / 2)
            let dt = seconds(from: previousInstant, to: instant)
            let current = capture.energies

            func watts(_ names: [String]) -> Double {
                guard dt > 0 else { return 0 }
                return names.reduce(0.0) { total, name in
                    total + max(0, (current[name] ?? 0) - (previous[name] ?? 0)) / dt
                }
            }

            let coreNames = current.keys.filter(isCPUCoreEnergyChannel)
            let clusterNames = current.keys.filter { ["ECPU", "PCPU"].contains($0) }
            let gpuName = current["GPU Energy"] != nil ? "GPU Energy" : "GPU"
            let aneNames = current.keys.filter { classifyEngine($0) == .npu }

            print(String(format: "%.3f,%.6f,%.6f,%.6f,%.6f,%.6f",
                         Date().timeIntervalSince1970,
                         watts(["CPU Energy"]), watts(Array(coreNames)),
                         watts(Array(clusterNames)), watts([gpuName]), watts(Array(aneNames))))
            previous = current
            previousInstant = instant
        }
    }

    private static func seconds(from a: ContinuousClock.Instant,
                                to b: ContinuousClock.Instant) -> Double {
        let d = a.duration(to: b)
        return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }
}
