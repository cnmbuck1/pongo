import Foundation

/// High-level match states. Transitions are validated so that scoring code
/// cannot, for example, award a point twice or serve during a rally.
public enum MatchPhase: String, Codable, CaseIterable {
    case ready        // pre-game intro ("Game 1")
    case serving      // server holding / tossing the ball
    case rally        // ball in play after the serve is struck
    case pointEnded   // ruling made, brief pause before the next serve
    case gameEnded    // game result shown
    case matchEnded   // final result
}

public struct MatchStateMachine: Codable, Equatable {
    public private(set) var phase: MatchPhase = .ready
    /// Seconds spent in the current phase.
    public private(set) var timeInPhase: Double = 0

    public init() {}

    public static let allowed: [MatchPhase: Set<MatchPhase>] = [
        .ready: [.serving],
        .serving: [.rally, .pointEnded, .serving],      // serve struck; fault; let / re-toss
        .rally: [.pointEnded, .serving],                // ruling; let -> replay serve
        .pointEnded: [.serving, .gameEnded, .matchEnded],
        .gameEnded: [.ready],
        .matchEnded: [.ready]                           // restart
    ]

    public func canTransition(to next: MatchPhase) -> Bool {
        Self.allowed[phase]?.contains(next) ?? false
    }

    /// Performs a transition. Returns false (and stays put) if illegal.
    @discardableResult
    public mutating func transition(to next: MatchPhase) -> Bool {
        guard canTransition(to: next) else { return false }
        phase = next
        timeInPhase = 0
        return true
    }

    public mutating func tick(_ dt: Double) { timeInPhase += dt }

    /// Hard reset for a brand-new match.
    public mutating func reset() {
        phase = .ready
        timeInPhase = 0
    }
}
