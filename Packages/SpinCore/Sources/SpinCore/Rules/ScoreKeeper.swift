import Foundation

/// Match format. Defaults: games to 11, win by 2, best of 3, serve changes
/// every 2 points, every point from 10–10.
public struct MatchFormat: Codable, Equatable {
    public var pointsToWinGame: Int = 11
    public var winByMargin: Int = 2
    public var gamesToWinMatch: Int = 2
    public var servesPerTurn: Int = 2

    public init() {}

    public init(pointsToWinGame: Int, winByMargin: Int = 2, gamesToWinMatch: Int, servesPerTurn: Int = 2) {
        self.pointsToWinGame = pointsToWinGame
        self.winByMargin = winByMargin
        self.gamesToWinMatch = gamesToWinMatch
        self.servesPerTurn = servesPerTurn
    }

    public var bestOf: Int { gamesToWinMatch * 2 - 1 }
}

/// Points, games and serve rotation.
public struct ScoreKeeper: Codable, Equatable {

    public enum Outcome: Equatable {
        case pointAwarded
        case gameWon(by: Side)
        case matchWon(by: Side)
    }

    public let format: MatchFormat
    public private(set) var nearPoints = 0
    public private(set) var farPoints = 0
    public private(set) var nearGames = 0
    public private(set) var farGames = 0
    /// 1-based.
    public private(set) var gameNumber = 1
    public let matchFirstServer: Side
    public private(set) var gameFirstServer: Side
    public private(set) var matchWinner: Side?
    /// Final points of each completed game (near, far).
    public private(set) var completedGames: [GameResult] = []

    public struct GameResult: Codable, Equatable {
        public var near: Int
        public var far: Int
    }

    public init(format: MatchFormat = MatchFormat(), firstServer: Side) {
        self.format = format
        self.matchFirstServer = firstServer
        self.gameFirstServer = firstServer
    }

    public func points(_ side: Side) -> Int { side == .near ? nearPoints : farPoints }
    public func games(_ side: Side) -> Int { side == .near ? nearGames : farGames }

    /// Who serves the next point.
    public var server: Side {
        let total = nearPoints + farPoints
        let deuceStart = 2 * (format.pointsToWinGame - 1)
        let turn: Int
        if nearPoints >= format.pointsToWinGame - 1 && farPoints >= format.pointsToWinGame - 1 {
            // Alternate every point from deuce (10–10 by default).
            turn = deuceStart / format.servesPerTurn + (total - deuceStart)
        } else {
            turn = total / format.servesPerTurn
        }
        return turn % 2 == 0 ? gameFirstServer : gameFirstServer.opponent
    }

    public var isDeuce: Bool {
        nearPoints >= format.pointsToWinGame - 1 && farPoints >= format.pointsToWinGame - 1
    }

    /// Awards a point. Ignored once the match is over.
    @discardableResult
    public mutating func award(to side: Side) -> Outcome {
        guard matchWinner == nil else { return .matchWon(by: matchWinner!) }
        if side == .near { nearPoints += 1 } else { farPoints += 1 }
        let mine = points(side), theirs = points(side.opponent)
        guard mine >= format.pointsToWinGame, mine - theirs >= format.winByMargin else { return .pointAwarded }

        completedGames.append(GameResult(near: nearPoints, far: farPoints))
        if side == .near { nearGames += 1 } else { farGames += 1 }
        if games(side) >= format.gamesToWinMatch {
            matchWinner = side
            return .matchWon(by: side)
        }
        return .gameWon(by: side)
    }

    /// Begins the next game: points reset and the first server alternates.
    public mutating func startNextGame() {
        guard matchWinner == nil else { return }
        nearPoints = 0
        farPoints = 0
        gameNumber += 1
        gameFirstServer = (gameNumber % 2 == 1) ? matchFirstServer : matchFirstServer.opponent
    }
}
