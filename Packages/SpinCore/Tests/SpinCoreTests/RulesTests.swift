import XCTest
@testable import SpinCore

final class RefereeTests: XCTestCase {

    func rally(server: Side = .near) -> RallyReferee {
        var r = RallyReferee(server: server)
        XCTAssertEqual(r.paddleHit(by: server, ballZ: server.zSign * 1.5), .play)
        XCTAssertEqual(r.tableBounce(on: server), .play)
        XCTAssertEqual(r.tableBounce(on: server.opponent), .play)
        XCTAssertEqual(r.phase, .rally)
        return r
    }

    func testLegalServeStartsRally() {
        let r = rally()
        XCTAssertEqual(r.lastHitter, .near)
        XCTAssertEqual(r.strokes, 1)
    }

    func testServeMustBounceOnServersHalfFirst() {
        var r = RallyReferee(server: .near)
        _ = r.paddleHit(by: .near, ballZ: 1.5)
        XCTAssertEqual(r.tableBounce(on: .far), .point(winner: .far, reason: .serveMissedOwnHalf))
    }

    func testServeMustReachReceiversHalf() {
        var r = RallyReferee(server: .far)
        _ = r.paddleHit(by: .far, ballZ: -1.5)
        _ = r.tableBounce(on: .far)
        XCTAssertEqual(r.tableBounce(on: .far), .point(winner: .near, reason: .serveMissedReceiverHalf))
    }

    func testServeIntoFloorIsFault() {
        var r = RallyReferee(server: .near)
        _ = r.paddleHit(by: .near, ballZ: 1.5)
        _ = r.tableBounce(on: .near)
        XCTAssertEqual(r.ballDead(), .point(winner: .far, reason: .serveMissedReceiverHalf))
    }

    func testNetServeThatLandsIsALet() {
        var r = RallyReferee(server: .near)
        _ = r.paddleHit(by: .near, ballZ: 1.5)
        _ = r.tableBounce(on: .near)
        _ = r.netTouch()
        XCTAssertEqual(r.tableBounce(on: .far), .let_)
    }

    func testNetServeThatFailsIsAFault() {
        var r = RallyReferee(server: .near)
        _ = r.paddleHit(by: .near, ballZ: 1.5)
        _ = r.tableBounce(on: .near)
        _ = r.netTouch()
        XCTAssertEqual(r.tableBounce(on: .near), .point(winner: .far, reason: .serveMissedReceiverHalf))
    }

    func testReceiverMustLetServeBounce() {
        var r = RallyReferee(server: .near)
        _ = r.paddleHit(by: .near, ballZ: 1.5)
        _ = r.tableBounce(on: .near)
        XCTAssertEqual(r.paddleHit(by: .far, ballZ: -0.8), .point(winner: .near, reason: .volley))
    }

    func testValidReturnContinuesRally() {
        var r = rally()
        XCTAssertEqual(r.paddleHit(by: .far, ballZ: -1.6), .play)
        XCTAssertEqual(r.tableBounce(on: .near), .play)
        XCTAssertEqual(r.paddleHit(by: .near, ballZ: 1.6), .play)
        XCTAssertEqual(r.strokes, 3)
    }

    func testReturnMissingTableLoses() {
        var r = rally()
        _ = r.paddleHit(by: .far, ballZ: -1.6)
        XCTAssertEqual(r.ballDead(), .point(winner: .near, reason: .missedTable))
    }

    func testReturnBouncingOnOwnHalfLoses() {
        var r = rally()
        _ = r.paddleHit(by: .far, ballZ: -1.6)
        XCTAssertEqual(r.tableBounce(on: .far), .point(winner: .near, reason: .hitOwnHalf))
    }

    func testNotReturningAfterGoodBounceLoses() {
        var r = rally()
        // Server's serve bounced on far half; far never touches it.
        XCTAssertEqual(r.ballDead(), .point(winner: .near, reason: .notReturned))
    }

    func testDoubleBounceLoses() {
        var r = rally()
        XCTAssertEqual(r.tableBounce(on: .far), .point(winner: .near, reason: .doubleBounce))
    }

    func testVolleyOverTableLoses() {
        var r = rally()
        _ = r.paddleHit(by: .far, ballZ: -1.6)
        XCTAssertEqual(r.paddleHit(by: .near, ballZ: 1.2), .point(winner: .far, reason: .volley))
    }

    func testHittingBallAlreadyPastEndLineWinsForHitter() {
        var r = rally()
        _ = r.paddleHit(by: .far, ballZ: -1.6)
        // Ball sailed long without touching the near half.
        XCTAssertEqual(r.paddleHit(by: .near, ballZ: 1.6), .point(winner: .near, reason: .missedTable))
    }

    func testNetDuringRallyIsFineIfItLands() {
        var r = rally()
        _ = r.paddleHit(by: .far, ballZ: -1.6)
        XCTAssertEqual(r.netTouch(), .play)
        XCTAssertEqual(r.tableBounce(on: .near), .play)
    }

    func testNetThenNoLandingLoses() {
        var r = rally()
        _ = r.paddleHit(by: .far, ballZ: -1.6)
        _ = r.netTouch()
        // Falls back on own half.
        XCTAssertEqual(r.tableBounce(on: .far), .point(winner: .near, reason: .hitOwnHalf))
    }

    func testDoubleHitLoses() {
        var r = rally()
        _ = r.paddleHit(by: .far, ballZ: -1.6)
        XCTAssertEqual(r.paddleHit(by: .far, ballZ: -1.6), .point(winner: .near, reason: .doubleHit))
    }

    func testEventsAfterRulingAreIgnored() {
        var r = rally()
        _ = r.tableBounce(on: .far)
        XCTAssertEqual(r.phase, .finished)
        XCTAssertEqual(r.ballDead(), .play)
        XCTAssertEqual(r.paddleHit(by: .far, ballZ: -1.5), .play)
    }
}

final class ScoreKeeperTests: XCTestCase {

    func testGameToElevenWinByTwo() {
        var s = ScoreKeeper(firstServer: .near)
        for _ in 0..<10 { s.award(to: .near) }
        for _ in 0..<10 { s.award(to: .far) }
        XCTAssertEqual(s.award(to: .near), .pointAwarded)   // 11-10
        XCTAssertEqual(s.award(to: .far), .pointAwarded)    // 11-11
        XCTAssertEqual(s.award(to: .near), .pointAwarded)   // 12-11
        XCTAssertEqual(s.award(to: .near), .gameWon(by: .near)) // 13-11
        XCTAssertEqual(s.completedGames.last, .init(near: 13, far: 11))
    }

    func testStraightElevenWins() {
        var s = ScoreKeeper(firstServer: .near)
        for _ in 0..<10 { XCTAssertEqual(s.award(to: .far), .pointAwarded) }
        XCTAssertEqual(s.award(to: .far), .gameWon(by: .far))
    }

    func testServeRotatesEveryTwoPoints() {
        var s = ScoreKeeper(firstServer: .near)
        var servers: [Side] = []
        for i in 0..<8 {
            servers.append(s.server)
            s.award(to: i % 2 == 0 ? .near : .far)
        }
        XCTAssertEqual(servers, [.near, .near, .far, .far, .near, .near, .far, .far])
    }

    func testServeAlternatesEveryPointAtDeuce() {
        var s = ScoreKeeper(firstServer: .far)
        for _ in 0..<10 { s.award(to: .near); s.award(to: .far) }
        XCTAssertTrue(s.isDeuce)
        var servers: [Side] = []
        for i in 0..<4 {
            servers.append(s.server)
            s.award(to: i % 2 == 0 ? .near : .far) // stays level-ish: 11-10, 11-11, 12-11, 12-12
        }
        XCTAssertEqual(servers[0], .far)
        XCTAssertEqual(servers, [.far, .near, .far, .near])
    }

    func testBestOfThreeAndFirstServerAlternatesByGame() {
        var s = ScoreKeeper(firstServer: .near)
        for _ in 0..<11 { s.award(to: .near) }
        XCTAssertEqual(s.games(.near), 1)
        s.startNextGame()
        XCTAssertEqual(s.gameNumber, 2)
        XCTAssertEqual(s.points(.near), 0)
        XCTAssertEqual(s.server, .far, "first server alternates each game")
        for _ in 0..<10 { s.award(to: .far) }
        XCTAssertEqual(s.award(to: .far), .gameWon(by: .far))
        s.startNextGame()
        XCTAssertEqual(s.server, .near)
        for _ in 0..<10 { s.award(to: .near) }
        XCTAssertEqual(s.award(to: .near), .matchWon(by: .near))
        XCTAssertEqual(s.matchWinner, .near)
        // Further points are ignored.
        XCTAssertEqual(s.award(to: .far), .matchWon(by: .near))
        XCTAssertEqual(s.points(.far), 0)
    }

    func testCodableRoundTrip() throws {
        var s = ScoreKeeper(firstServer: .near)
        s.award(to: .far)
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(ScoreKeeper.self, from: data), s)
    }
}

final class StateMachineTests: XCTestCase {

    func testHappyPathTransitions() {
        var m = MatchStateMachine()
        XCTAssertEqual(m.phase, .ready)
        XCTAssertTrue(m.transition(to: .serving))
        XCTAssertTrue(m.transition(to: .rally))
        XCTAssertTrue(m.transition(to: .pointEnded))
        XCTAssertTrue(m.transition(to: .serving))
        XCTAssertTrue(m.transition(to: .rally))
        XCTAssertTrue(m.transition(to: .pointEnded))
        XCTAssertTrue(m.transition(to: .gameEnded))
        XCTAssertTrue(m.transition(to: .ready))
        XCTAssertTrue(m.transition(to: .serving))
        XCTAssertTrue(m.transition(to: .rally))
        XCTAssertTrue(m.transition(to: .pointEnded))
        XCTAssertTrue(m.transition(to: .matchEnded))
        XCTAssertTrue(m.transition(to: .ready))
    }

    func testIllegalTransitionsRejected() {
        var m = MatchStateMachine()
        XCTAssertFalse(m.transition(to: .rally))
        XCTAssertFalse(m.transition(to: .pointEnded))
        XCTAssertFalse(m.transition(to: .matchEnded))
        XCTAssertEqual(m.phase, .ready)
        m.transition(to: .serving)
        m.transition(to: .rally)
        XCTAssertFalse(m.transition(to: .gameEnded), "a game can only end after a point")
        XCTAssertFalse(m.transition(to: .ready))
        m.transition(to: .pointEnded)
        XCTAssertFalse(m.transition(to: .pointEnded), "a point cannot end twice")
        XCTAssertFalse(m.transition(to: .rally))
    }

    func testTimeInPhaseResetsOnTransition() {
        var m = MatchStateMachine()
        m.tick(0.5)
        XCTAssertEqual(m.timeInPhase, 0.5, accuracy: 1e-12)
        m.transition(to: .serving)
        XCTAssertEqual(m.timeInPhase, 0)
    }
}
