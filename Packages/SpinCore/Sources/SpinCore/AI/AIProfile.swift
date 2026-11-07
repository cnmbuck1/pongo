import Foundation

public enum AIDifficulty: String, Codable, CaseIterable {
    case beginner, intermediate, advanced

    public var displayName: String {
        switch self {
        case .beginner: return "Beginner"
        case .intermediate: return "Intermediate"
        case .advanced: return "Advanced"
        }
    }

    public var profile: AIProfile {
        switch self {
        case .beginner: return .beginner
        case .intermediate: return .intermediate
        case .advanced: return .advanced
        }
    }
}

/// Tunable personality of a computer opponent. Difficulty is expressed only
/// through these parameters — the ball physics is identical for everyone.
public struct AIProfile: Codable, Equatable {
    public var name: String
    /// Seconds after the opponent's contact before the AI starts tracking.
    public var reactionDelay: Double
    /// Paddle movement limits while positioning.
    public var maxSpeed: Double
    public var maxAcceleration: Double
    /// Std. dev. of the intercept-point estimate error (m).
    public var predictionError: Double
    /// Std. dev. of blade-angle error at contact (degrees).
    public var aimErrorDegrees: Double
    /// Probability per shot of a clear mistake (misjudged ball or bad aim).
    public var mistakeProbability: Double
    /// 0...1 how much brushing (spin) the AI puts into strokes.
    public var spinPreference: Double
    /// -1 (prefers backspin/push) ... +1 (prefers topspin).
    public var topspinBias: Double
    /// 0...1 probability-weight of adding sidespin.
    public var sidespinPreference: Double
    /// 0...1 swing speed / risk.
    public var aggressiveness: Double
    /// 0...1 how wide shots are placed.
    public var placementWidth: Double
    /// Target the side of the table away from the opponent's paddle.
    public var strategicPlacement: Bool
    /// Preferred upper limit on outgoing ball speed (m/s).
    public var maxShotSpeed: Double

    public static let beginner = AIProfile(
        name: "Rookie", reactionDelay: 0.2, maxSpeed: 2.7, maxAcceleration: 15,
        predictionError: 0.022, aimErrorDegrees: 2.2, mistakeProbability: 0.10,
        spinPreference: 0.15, topspinBias: 0.2, sidespinPreference: 0.0,
        aggressiveness: 0.15, placementWidth: 0.25, strategicPlacement: false, maxShotSpeed: 6.5)

    public static let intermediate = AIProfile(
        name: "Contender", reactionDelay: 0.17, maxSpeed: 3.0, maxAcceleration: 17,
        predictionError: 0.012, aimErrorDegrees: 1.3, mistakeProbability: 0.05,
        spinPreference: 0.45, topspinBias: 0.5, sidespinPreference: 0.25,
        aggressiveness: 0.42, placementWidth: 0.55, strategicPlacement: false, maxShotSpeed: 8.5)

    public static let advanced = AIProfile(
        name: "Vector", reactionDelay: 0.11, maxSpeed: 3.8, maxAcceleration: 24,
        predictionError: 0.006, aimErrorDegrees: 0.7, mistakeProbability: 0.025,
        spinPreference: 0.85, topspinBias: 0.45, sidespinPreference: 0.45,
        aggressiveness: 0.7, placementWidth: 0.85, strategicPlacement: true, maxShotSpeed: 11)
}
