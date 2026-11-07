import XCTest
@testable import SpinCore

/// Headless integration tests: the full simulation (physics + rules + AI +
/// touch input) runs exactly as it does in the app, minus rendering.
final class GameplayTests: XCTestCase {

    private func runAIMatch(_ d: AIDifficulty, seed: UInt64, maxSeconds: Double = 900)
        -> (sim: GameSimulation, strokes: [Int]) {
        var setup = GameSetup()
        setup.difficulty = d
        let sim = GameSimulation(setup: setup,
                                 near: AIOpponentController(side: .near, profile: d.profile, seed: seed),
                                 far: AIOpponentController(side: .far, profile: d.profile, seed: seed &+ 2))
        var strokes: [Int] = []
        var ticks = 0
        while Double(ticks) * sim.dt < maxSeconds && sim.phase != .matchEnded {
            let s = sim.referee.strokes
            sim.step(); ticks += 1
            for e in sim.drainEvents() { if case .point = e { strokes.append(s) } }
        }
        return (sim, strokes)
    }

    func testAIvsAIPlaysCompleteMatchWithRealRallies() {
        let (sim, strokes) = runAIMatch(.intermediate, seed: 7)
        XCTAssertEqual(sim.phase, .matchEnded)
        XCTAssertNotNil(sim.score.matchWinner)
        // Every completed game is a legal table-tennis score.
        for g in sim.score.completedGames {
            let hi = max(g.near, g.far), lo = min(g.near, g.far)
            XCTAssertGreaterThanOrEqual(hi, 11)
            XCTAssertGreaterThanOrEqual(hi - lo, 2)
            if hi > 11 { XCTAssertEqual(hi - lo, 2) }
        }
        let avg = Double(strokes.reduce(0, +)) / Double(max(strokes.count, 1))
        XCTAssertGreaterThan(avg, 4.0, "AI should sustain rallies (avg strokes per point)")
        XCTAssertGreaterThanOrEqual(strokes.max() ?? 0, 12)
        XCTAssertEqual(sim.stats.pointsPlayed, strokes.count)
    }

    func testDifficultyChangesOutcomeNotPhysics() {
        // Advanced beats beginner over a match; physics config identical.
        var setup = GameSetup()
        let sim = GameSimulation(setup: setup,
                                 near: AIOpponentController(side: .near, profile: .advanced, seed: 3),
                                 far: AIOpponentController(side: .far, profile: .beginner, seed: 4))
        setup.physics = PhysicsConfig()
        XCTAssertEqual(sim.setup.physics, setup.physics)
        var ticks = 0
        while ticks < 240 * 900 && sim.phase != .matchEnded { sim.step(); _ = sim.drainEvents(); ticks += 1 }
        XCTAssertEqual(sim.score.matchWinner, .near)
    }

    func testSimulationIsDeterministic() {
        let a = runAIMatch(.advanced, seed: 99, maxSeconds: 40).sim.snapshot()
        let b = runAIMatch(.advanced, seed: 99, maxSeconds: 40).sim.snapshot()
        XCTAssertEqual(a, b)
    }

    func testSnapshotIsSerializable() throws {
        let sim = runAIMatch(.beginner, seed: 1, maxSeconds: 20).sim
        let data = try JSONEncoder().encode(sim.snapshot())
        let back = try JSONDecoder().decode(MatchSnapshot.self, from: data)
        XCTAssertEqual(back, sim.snapshot())
    }

    func testHumanSwipeControlsSustainRallies() {
        var setup = GameSetup()
        setup.controls.assist = .standard
        setup.difficulty = .intermediate
        let sim = GameSimulation(setup: setup)
        let bot = ScriptedTouchPlayer(sim: sim, swipeVX: 0, swipeVY: -2.2, leadTime: 0.45)
        var ticks = 0
        while ticks < 240 * 150 && sim.phase != .matchEnded { bot.tick(); sim.step(); _ = sim.drainEvents(); ticks += 1 }
        XCTAssertGreaterThan(sim.stats.successfulReturns, 25, "touch-driven paddle must return balls")
        XCTAssertGreaterThan(sim.score.points(.near) + sim.score.games(.near) * 11, 0, "player should win some points")
    }

    private func returns(scheme: ControlScheme, assist: AssistLevel, leadTime: Double = 0.11,
                         swipes: Bool = true, seconds: Double = 90, swipeVY: Double = 1.6) -> Int {
        var setup = GameSetup()
        setup.controls.scheme = scheme
        setup.controls.assist = assist
        setup.difficulty = .beginner
        let sim = GameSimulation(setup: setup)
        let bot = ScriptedTouchPlayer(sim: sim, swipeVX: 0, swipeVY: swipeVY, leadTime: leadTime)
        bot.rallySwipes = swipes
        var ticks = 0
        while ticks < Int(240 * seconds) && sim.phase != .matchEnded {
            bot.tick(); sim.step(); _ = sim.drainEvents(); ticks += 1
        }
        return sim.stats.successfulReturns
    }

    func testAutoPaddleReturnsSelectedShots() {
        // Swipes made well before contact select the shot; the paddle
        // executes it. Expert is harder (slower tracking, later reaction,
        // stronger timing penalties, less blade assistance).
        XCTAssertGreaterThan(returns(scheme: .autoTrack, assist: .beginner, leadTime: 0.45), 25)
        XCTAssertGreaterThan(returns(scheme: .autoTrack, assist: .standard, leadTime: 0.45), 20)
        XCTAssertGreaterThan(returns(scheme: .autoTrack, assist: .expert, leadTime: 0.45), 4)
        XCTAssertGreaterThan(returns(scheme: .autoTrack, assist: .standard, leadTime: 0.45, swipeVY: -2.2), 20,
                             "backspin")
    }

    func testTimingWindowsClassify() {
        let w = AssistLevel.standard.timing
        XCTAssertEqual(w.classify(0.01), .perfect)
        XCTAssertEqual(w.classify(-0.08), .good)
        XCTAssertEqual(w.classify(0.2), .early)
        XCTAssertEqual(w.classify(-0.2), .late)
        XCTAssertNil(w.classify(0.5))
        XCTAssertGreaterThan(AssistLevel.beginner.timing.good, AssistLevel.expert.timing.good)
    }

    func testFingerPaddleSchemeStillReturns() {
        XCTAssertGreaterThan(returns(scheme: .swipe, assist: .standard, swipeVY: -2.2), 10)
    }

    func testPlayerServeWithSwipeIsLegalMostOfTheTime() {
        var setup = GameSetup()
        setup.controls.assist = .standard
        let sim = GameSimulation(setup: setup)
        let bot = ScriptedTouchPlayer(sim: sim, swipeVX: 1.8, swipeVY: 1.0)
        var serves = 0, faults = 0
        var ticks = 0
        while ticks < 240 * 120 {
            bot.tick(); sim.step(); ticks += 1
            for e in sim.drainEvents() {
                if case let .physics(p) = e, p.kind == .paddleHit, p.side == .near, sim.referee.strokes == 1 { serves += 1 }
                if case let .point(_, r) = e, [.serveMissedOwnHalf, .serveMissedReceiverHalf, .serveFault].contains(r),
                   sim.referee.server == .near { faults += 1 }
            }
        }
        XCTAssertGreaterThan(serves, 5)
        XCTAssertLessThan(Double(faults), Double(serves) * 0.5)
    }

    func testTapTossesAndSwipeServes() {
        let sim = GameSimulation(setup: GameSetup())
        func swipe() {
            var y = 0.25
            sim.handleInput(phase: .began, u: 0.5, v: 0.3, screenX: 0.5, screenY: y)
            for _ in 0..<6 {
                for _ in 0..<4 { sim.step() }
                y += 2.6 / 60
                sim.handleInput(phase: .moved, u: 0.5, v: 0.3, screenX: 0.5, screenY: y)
            }
            sim.handleInput(phase: .ended, u: 0.5, v: 0.3, screenX: 0.5, screenY: y)
            sim.step()
        }
        // Ready phase: a swipe must not toss.
        swipe()
        XCTAssertTrue(sim.world.ballHeld)
        while sim.phase == .ready { sim.step() }
        XCTAssertEqual(sim.phase, .serving)
        // A tap while serving tosses the ball...
        sim.handleInput(phase: .began, u: 0.5, v: 0.3, screenX: 0.5, screenY: 0.3)
        sim.step()
        XCTAssertFalse(sim.world.ballHeld, "a tap during own serve tosses the ball")
        sim.handleInput(phase: .ended, u: 0.5, v: 0.3, screenX: 0.5, screenY: 0.3)
        // ...and with no swipe the toss drops and is held again, no point lost.
        for _ in 0..<(240 * 3) { sim.step() }
        XCTAssertTrue(sim.world.ballHeld)
        XCTAssertEqual(sim.referee.strokes, 0)
        // One swipe tosses and then strikes the ball automatically.
        swipe()
        XCTAssertFalse(sim.world.ballHeld, "a swipe during own serve tosses the ball")
        var struck = false
        for _ in 0..<(240 * 2) {
            sim.step()
            if sim.referee.strokes >= 1 { struck = true; break }
        }
        XCTAssertTrue(struck, "the queued serve stroke hits the tossed ball")
    }

    func testSwipeDirectionMapsToSpin() {
        let player = PlayerPaddleController()
        let config = PhysicsConfig()
        let incoming = BallState(position: Vec3(0, 1.0, 1.58), velocity: Vec3(0, -0.3, 4))
        let face = ShotSolver.faceNormal(for: .near, pitch: 0.1, yaw: 0)
        func spinFor(_ vx: Double, _ vy: Double) -> SpinReading {
            let stroke = player.strokeVelocity(fingerVX: vx, fingerVY: vy)
            return SpinReading(ball: PaddleCollision.strike(ball: incoming, paddleVelocity: stroke, faceNormal: face, config: config))
        }
        XCTAssertGreaterThan(spinFor(0, 3).topspin, 40, "upward swipe → topspin")
        XCTAssertLessThan(spinFor(0, -3).topspin, -40, "downward swipe → backspin")
        XCTAssertGreaterThan(abs(spinFor(3, 0).sidespin), 30, "sideways swipe → sidespin")
        // Faster swipe = harder shot; slow = soft.
        XCTAssertGreaterThan(player.strokeVelocity(fingerVX: 0, fingerVY: 4).length,
                             player.strokeVelocity(fingerVX: 0, fingerVY: 1).length + 3)
    }

    func testPaddleStaysInsideReachableRegion() {
        let sim = GameSimulation(setup: GameSetup())
        for i in 0..<480 {
            let u = i % 2 == 0 ? -3.0 : 4.0
            sim.handleInput(phase: i == 0 ? .began : .moved, u: u, v: 5, screenX: u, screenY: 5)
            sim.step()
            let p = sim.nearDriver.paddle.position
            let r = PaddleReach()
            XCTAssertTrue(r.xRange.contains(p.x) && p.y <= r.yRange.upperBound + 1e-6)
        }
    }

    func testServeRotationInLiveMatch() {
        let (sim, _) = runAIMatch(.intermediate, seed: 21, maxSeconds: 60)
        // Server derives from score; check rule consistency at the current score.
        let total = sim.score.nearPoints + sim.score.farPoints
        if !sim.score.isDeuce {
            let expected = (total / 2) % 2 == 0 ? sim.score.gameFirstServer : sim.score.gameFirstServer.opponent
            XCTAssertEqual(sim.score.server, expected)
        }
    }

    func testRestartMatchResets() {
        let sim = runAIMatch(.beginner, seed: 5, maxSeconds: 60).sim
        XCTAssertGreaterThan(sim.stats.pointsPlayed, 0)
        sim.restartMatch()
        XCTAssertEqual(sim.phase, .ready)
        XCTAssertEqual(sim.score.nearPoints + sim.score.farPoints, 0)
        XCTAssertEqual(sim.stats.pointsPlayed, 0)
    }

    func testTrainingModeNeverEndsAndAIAlwaysServes() {
        var setup = GameSetup()
        setup.mode = .training
        let sim = GameSimulation(setup: setup)
        var servers: Set<Side> = []
        for _ in 0..<(240 * 40) {
            sim.step()
            for e in sim.drainEvents() { if case let .serveTossed(s) = e { servers.insert(s) } }
        }
        XCTAssertEqual(servers, [.far])
        XCTAssertNotEqual(sim.phase, .matchEnded)
        XCTAssertEqual(sim.score.nearPoints + sim.score.farPoints, 0)
    }
}
