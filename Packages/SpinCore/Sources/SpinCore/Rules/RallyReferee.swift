import Foundation

/// Why a point ended. Used for HUD call-outs and statistics.
public enum PointReason: String, Codable, Equatable {
    case serveMissedOwnHalf        // serve did not bounce on the server's half first
    case serveMissedReceiverHalf   // serve bounced on own half but not on receiver's
    case serveFault                // serve went into the net / off the table
    case doubleBounce              // ball bounced twice on a player's half
    case missedTable               // return did not land on the opponent's half
    case hitOwnHalf                // return bounced on the hitter's own half
    case volley                    // ball struck before it bounced
    case doubleHit                 // same player struck the ball twice
    case netNoReturn               // hit the net and did not land on the far half
    case notReturned               // ball left play after a good bounce
}

/// The referee's ruling after an event.
public enum RefereeRuling: Equatable {
    case play
    case point(winner: Side, reason: PointReason)
    /// Legal serve that touched the net: replay the point.
    case let_
}

/// Applies table-tennis rally rules to the stream of physics events.
///
/// Pure value type with no knowledge of physics internals; it only sees
/// "paddle hit by X", "bounce on half Y", "net", "floor". This keeps the
/// rules exhaustively unit testable.
public struct RallyReferee: Codable, Equatable {

    public enum Phase: String, Codable {
        /// Ball tossed or held, server yet to strike.
        case awaitingServe
        /// Serve struck, must bounce on server's half.
        case serveNeedsServerBounce
        /// Serve bounced on server's half, must bounce on receiver's half.
        case serveNeedsReceiverBounce
        /// Normal rally.
        case rally
        /// A ruling has been made; further events are ignored.
        case finished
    }

    public private(set) var phase: Phase = .awaitingServe
    public private(set) var server: Side
    public private(set) var lastHitter: Side?
    /// During a rally: has the ball bounced on the receiving half since the last hit?
    public private(set) var bouncedOnReceiver = false
    public private(set) var netTouchedOnServe = false
    /// Number of paddle strikes in this rally (serve included).
    public private(set) var strokes = 0
    public let tableHalfLength: Double

    public init(server: Side, tableHalfLength: Double = TableGeometry().halfLength) {
        self.server = server
        self.tableHalfLength = tableHalfLength
    }

    public var receiver: Side { server.opponent }

    private mutating func finish(_ winner: Side, _ reason: PointReason) -> RefereeRuling {
        phase = .finished
        return .point(winner: winner, reason: reason)
    }

    /// A paddle struck the ball. `ballZ` is where it was struck.
    public mutating func paddleHit(by side: Side, ballZ: Double) -> RefereeRuling {
        switch phase {
        case .finished:
            return .play
        case .awaitingServe:
            guard side == server else { return finish(server, .volley) }
            phase = .serveNeedsServerBounce
            lastHitter = side
            strokes = 1
            return .play
        case .serveNeedsServerBounce:
            // Struck again before the serve bounced.
            return side == server ? finish(receiver, .doubleHit) : finish(server, .volley)
        case .serveNeedsReceiverBounce:
            if side == server { return finish(receiver, .doubleHit) }
            // Receiver struck the serve before it bounced on their half.
            if beyondEndLine(ballZ, of: side) { return finish(receiver, .serveMissedReceiverHalf) }
            return finish(server, .volley)
        case .rally:
            guard let last = lastHitter else { return .play }
            if side == last { return finish(side.opponent, .doubleHit) }
            if !bouncedOnReceiver {
                // Ball already past the end line: the shot was going out anyway.
                if beyondEndLine(ballZ, of: side) { return finish(side, .missedTable) }
                return finish(side.opponent, .volley)
            }
            lastHitter = side
            bouncedOnReceiver = false
            strokes += 1
            return .play
        }
    }

    /// The ball bounced on the playing surface of `half`.
    public mutating func tableBounce(on half: Side) -> RefereeRuling {
        switch phase {
        case .finished, .awaitingServe:
            return .play
        case .serveNeedsServerBounce:
            if half == server { phase = .serveNeedsReceiverBounce; return .play }
            return finish(receiver, .serveMissedOwnHalf)
        case .serveNeedsReceiverBounce:
            if half == receiver {
                if netTouchedOnServe { phase = .finished; return .let_ }
                phase = .rally
                bouncedOnReceiver = true
                return .play
            }
            return finish(receiver, .serveMissedReceiverHalf)
        case .rally:
            guard let last = lastHitter else { return .play }
            if half == last { return finish(last.opponent, .hitOwnHalf) }
            if bouncedOnReceiver { return finish(last, .doubleBounce) }
            bouncedOnReceiver = true
            return .play
        }
    }

    public mutating func netTouch() -> RefereeRuling {
        if phase == .serveNeedsServerBounce || phase == .serveNeedsReceiverBounce { netTouchedOnServe = true }
        return .play
    }

    /// The ball hit the floor, the table side, or otherwise left play.
    public mutating func ballDead() -> RefereeRuling {
        switch phase {
        case .finished, .awaitingServe:
            return .play
        case .serveNeedsServerBounce:
            return finish(receiver, netTouchedOnServe ? .serveFault : .serveMissedOwnHalf)
        case .serveNeedsReceiverBounce:
            return finish(receiver, netTouchedOnServe ? .serveFault : .serveMissedReceiverHalf)
        case .rally:
            guard let last = lastHitter else { return .play }
            if bouncedOnReceiver { return finish(last, .notReturned) }
            return finish(last.opponent, .missedTable)
        }
    }

    /// Convenience: route a physics event.
    public mutating func handle(_ event: PhysicsEvent) -> RefereeRuling {
        switch event.kind {
        case .paddleHit: return paddleHit(by: event.side ?? .near, ballZ: event.point.z)
        case .tableBounce: return tableBounce(on: event.side ?? Side.of(z: event.point.z))
        case .netTouch: return netTouch()
        case .floorHit: return ballDead()
        }
    }

    private func beyondEndLine(_ z: Double, of side: Side) -> Bool {
        z * side.zSign > tableHalfLength
    }
}
