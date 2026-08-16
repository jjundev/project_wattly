import Foundation

/// Pure GPU-sample derivation: clamps percentages and binds engine metrics into a Sendable GPUSample.
/// Fully deterministic under synthetic input.
func makeGPUSample(overall: Double,
                   rendererUsage: Double = 0,
                   tilerUsage: Double = 0,
                   inUseMemoryBytes: UInt64 = 0,
                   allocMemoryBytes: UInt64 = 0,
                   coreCount: Int,
                   activeGHz: Double?) -> GPUSample {
    let clampedOverall = min(100.0, max(0.0, overall))
    let clampedRenderer = min(100.0, max(0.0, rendererUsage))
    let clampedTiler = min(100.0, max(0.0, tilerUsage))
    return GPUSample(
        overall: clampedOverall,
        coreCount: max(1, coreCount),
        activeGHz: activeGHz,
        rendererUsage: clampedRenderer,
        tilerUsage: clampedTiler,
        inUseMemoryBytes: inUseMemoryBytes,
        allocMemoryBytes: allocMemoryBytes
    )
}
