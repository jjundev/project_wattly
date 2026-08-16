import Foundation

/// Pure GPU-sample derivation: clamps overall percentage and distributes it across physical cores.
/// Fully deterministic under synthetic input.
func makeGPUSample(overall: Double, coreCount: Int, activeGHz: Double?) -> GPUSample {
    let clampedOverall = min(100.0, max(0.0, overall))
    let count = max(1, coreCount)
    let cores = [Double](repeating: clampedOverall, count: count)
    return GPUSample(overall: clampedOverall,
                     coreCount: count,
                     activeGHz: activeGHz,
                     cores: cores)
}
