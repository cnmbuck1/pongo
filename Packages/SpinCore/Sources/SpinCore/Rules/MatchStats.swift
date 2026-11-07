import Foundation

/// Rally statistics shown on the results screen.
public struct MatchStats: Codable, Equatable {
    public var pointsPlayed = 0
    public var totalRallyStrokes = 0
    public var longestRally = 0
    /// Returns by the human player that landed legally on the opponent's half.
    public var successfulReturns = 0
    public var nearPointsWon = 0
    public var farPointsWon = 0
    public var fastestShot: Double = 0
    public var maxSpin: Double = 0

    public init() {}

    public var averageRally: Double {
        pointsPlayed == 0 ? 0 : Double(totalRallyStrokes) / Double(pointsPlayed)
    }

    public mutating func recordPoint(winner: Side, strokes: Int) {
        pointsPlayed += 1
        totalRallyStrokes += strokes
        longestRally = max(longestRally, strokes)
        if winner == .near { nearPointsWon += 1 } else { farPointsWon += 1 }
    }
}
