import Foundation

/// Small, fast, seedable PRNG (SplitMix64).
///
/// Used for all AI randomness so a match is reproducible from its seed and
/// input log (important for replays, tests and future multiplayer).
public struct RandomSource: Codable, Equatable {
    public private(set) var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func nextDouble() -> Double {
        Double(nextUInt64() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Uniform in [lo, hi).
    public mutating func uniform(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * nextDouble()
    }

    /// Standard normal sample (Box–Muller).
    public mutating func gaussian(mean: Double = 0, sd: Double = 1) -> Double {
        let u1 = max(nextDouble(), 1e-12)
        let u2 = nextDouble()
        return mean + sd * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    public mutating func chance(_ p: Double) -> Bool { nextDouble() < p }
}

/// Converts variable real-time frame deltas into a whole number of fixed
/// simulation ticks (classic accumulator). Physics never sees the frame rate.
public struct FixedStepClock: Codable, Equatable {
    public let step: Double
    public private(set) var accumulator: Double = 0
    /// Cap to avoid a "spiral of death" after a long stall (e.g. app resume).
    public var maxStepsPerAdvance: Int = 24

    public init(step: Double) { self.step = step }

    /// Returns how many fixed steps to run for `elapsed` seconds of real time.
    public mutating func advance(by elapsed: Double) -> Int {
        accumulator += max(0, elapsed)
        var n = Int((accumulator / step + 1e-9).rounded(.down))
        if n > maxStepsPerAdvance { n = maxStepsPerAdvance; accumulator = 0; return n }
        accumulator -= Double(n) * step
        return n
    }

    /// Fraction of a step left over (for render interpolation).
    public var alpha: Double { accumulator / step }
}
