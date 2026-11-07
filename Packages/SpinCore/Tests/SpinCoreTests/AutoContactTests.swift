import XCTest
@testable import SpinCore

/// Build 3 Phase 1 acceptance tests: automatic interception and contact,
/// shot buffering, reach limits and single authoritative contact.
final class AutoContactTests: XCTestCase {

    // MARK: Helpers

    /// A swipe path from (0.5, 0.3) moving by (dx, dy) screen heights over `duration`.
    private func path(dx: Double, dy: Double, duration: Double = 0.1, bow: Double = 0, t0: Double = 0)
        -> [GestureInterpreter.Sample] {
        (0...6).map { i in
            let f = Double(i) / 6
            // A bow bends the path sideways (perpendicular), peaking mid-swipe.
            let len = (dx * dx + dy * dy).squareRoot()
            let px = len > 0 ? dy / len : 0, py = len > 0 ? -dx / len : 0
            let b = bow * sin(f * .pi)
            return GestureInterpreter.Sample(t: t0 + duration * f, x: 0.5 + dx * f + px * b, y: 0.3 + dy * f + py * b)
        }
    }

    /// Injects a swipe into the simulation as touch events, starting now.
    private func swipe(_ sim: GameSimulation, dx: Double, dy: Double, frames: Int = 6, bow: Double = 0) {
        let pts = path(dx: dx, dy: dy, bow: bow)
        sim.handleInput(phase: .began, u: 0.5, v: 0.3, screenX: pts[0].x, screenY: pts[0].y)
        for i in 1..<pts.count {
            for _ in 0..<(frames * 4 / 6) { sim.step(); _ = sim.drainEvents() }
            sim.handleInput(phase: i == pts.count - 1 ? .ended : .moved, u: 0.5, v: 0.3,
                            screenX: pts[i].x, screenY: pts[i].y)
        }
        sim.step(); _ = sim.drainEvents()   // the gesture completes on the next tick
    }

    private func setup(assist: AssistLevel, difficulty: AIDifficulty = .beginner, mode: GameMode = .match) -> GameSimulation {
        var s = GameSetup()
        s.controls.scheme = .autoTrack
        s.controls.assist = assist
        s.difficulty = difficulty
        s.mode = mode
        return GameSimulation(setup: s)
    }

    /// Runs a match where the player never swipes during rallies (only taps
    /// to serve). Returns successful returns and per-point stroke counts.
    private func noGestureMatch(assist: AssistLevel, difficulty: AIDifficulty = .beginner,
                                seconds: Double = 150) -> (returns: Int, strokes: [Int], sim: GameSimulation) {
        let sim = setup(assist: assist, difficulty: difficulty)
        var strokes: [Int] = []
        var lastTap = -10.0
        var ticks = 0
        while Double(ticks) * sim.dt < seconds && sim.phase != .matchEnded {
            if sim.phase == .serving && sim.server == .near && sim.world.ballHeld && sim.time - lastTap > 1.0 {
                lastTap = sim.time
                if assist == .beginner {
                    // Beginner: a tap alone serves.
                    sim.handleInput(phase: .began, u: 0.5, v: 0.3, screenX: 0.5, screenY: 0.3)
                    sim.handleInput(phase: .ended, u: 0.5, v: 0.3, screenX: 0.5, screenY: 0.3)
                } else {
                    swipe(sim, dx: 0, dy: 0.2)
                }
            }
            let s = sim.referee.strokes
            sim.step(); ticks += 1
            for e in sim.drainEvents() { if case .point = e { strokes.append(s) } }
        }
        return (sim.stats.successfulReturns, strokes, sim)
    }

    /// Steps a training sim until the CPU has just hit the ball toward the player.
    private func waitForCPUHit(_ sim: GameSimulation, limit: Double = 8) -> Bool {
        let start = sim.time
        while sim.time - start < limit {
            sim.step()
            for e in sim.drainEvents() {
                if case let .physics(p) = e, p.kind == .paddleHit, p.side == .far { return true }
            }
        }
        return false
    }

    /// Steps until the near paddle hits (true) or the point ends (false).
    private func waitForPlayerContact(_ sim: GameSimulation, limit: Double = 3) -> PhysicsEvent? {
        let start = sim.time
        while sim.time - start < limit {
            sim.step()
            for e in sim.drainEvents() {
                if case let .physics(p) = e, p.kind == .paddleHit, p.side == .near { return p }
                if case .point = e { return nil }
            }
        }
        return nil
    }

    // MARK: Gesture interpretation

    func testGestureMapping() {
        func kind(_ dx: Double, _ dy: Double, duration: Double = 0.1, bow: Double = 0) -> ShotCommand? {
            GestureInterpreter.interpret(path(dx: dx, dy: dy, duration: duration, bow: bow))
        }
        XCTAssertEqual(kind(0, 0.18, duration: 0.15)?.kind, .topspin, "short upward swipe → light topspin")
        XCTAssertEqual(kind(0, 0.35, duration: 0.09)?.kind, .powerTopspin, "fast upward swipe → power topspin")
        XCTAssertEqual(kind(0, -0.2)?.kind, .backspin)
        XCTAssertEqual(kind(-0.25, 0)?.kind, .left)
        XCTAssertEqual(kind(0.25, 0.02)?.kind, .right)
        // Straight sideways swipes place the ball without strong sidespin.
        XCTAssertEqual(kind(0.25, 0)?.sideBrush, 0)
        let diagUp = kind(-0.2, 0.2)
        XCTAssertEqual(diagUp?.kind, .topspin)
        XCTAssertLessThan(diagUp?.placement ?? 0, -0.5, "diagonal up-left → topspin to the left")
        let diagDown = kind(0.2, -0.2)
        XCTAssertEqual(diagDown?.kind, .backspin)
        XCTAssertGreaterThan(diagDown?.placement ?? 0, 0.5)
        // A clearly curved brush is sidespin.
        let curved = kind(0.25, 0, bow: 0.08)
        XCTAssertEqual(curved?.kind, .sidespin)
        XCTAssertGreaterThan(abs(curved?.sideBrush ?? 0), 1.0)
        // Taps and crawls are not shots.
        XCTAssertNil(kind(0.01, 0.01))
        XCTAssertNil(kind(0, 0.05, duration: 0.5))
        // Faster swipes hit harder.
        XCTAssertGreaterThan(kind(0, -0.3, duration: 0.07)!.forward, kind(0, -0.15, duration: 0.2)!.forward)
    }

    func testShotBufferReplacesUntilLock() {
        var b = ShotBuffer()
        let top = ShotCommand(kind: .topspin, brush: 1.5, forward: 3)
        let back = ShotCommand(kind: .backspin, brush: -1.5, forward: 2)
        b.offer(back, timing: .early)
        b.offer(top, timing: .perfect)
        XCTAssertEqual(b.command?.kind, .topspin, "a later gesture replaces the earlier one")
        b.lock()
        XCTAssertFalse(b.offer(back, timing: .good), "no replacement after the lock")
        XCTAssertEqual(b.command?.kind, .topspin)
        b.clear()
        XCTAssertNil(b.command)
        b.lock()
        XCTAssertTrue(b.offer(back, timing: .good), "a first gesture after the lock is taken late")
        XCTAssertEqual(b.timing, .late)
    }

    func testTimingIsAQualityModifier() {
        let w = AssistLevel.standard.shotTiming
        XCTAssertEqual(w.classify(timeToContact: w.lock + 0.05), .perfect)
        XCTAssertEqual(w.classify(timeToContact: w.lock + w.good - 0.01), .good)
        XCTAssertEqual(w.classify(timeToContact: 1.2), .early)
        XCTAssertEqual(w.classify(timeToContact: w.lock - 0.02), .late)
        XCTAssertGreaterThan(AssistLevel.beginner.shotTiming.good, AssistLevel.expert.shotTiming.good)
        XCTAssertLessThan(AssistLevel.beginner.timingPenalty, AssistLevel.expert.timingPenalty)
    }

    // MARK: Phase 1 acceptance

    func testBeginnerRalliesWithoutAnyGesture() {
        let (returns, strokes, _) = noGestureMatch(assist: .beginner)
        let rallies = strokes.filter { $0 >= 2 }
        let avg = Double(rallies.reduce(0, +)) / Double(max(rallies.count, 1))
        print("Beginner, no gestures: returns=\(returns) points=\(strokes.count) avg strokes=\(avg) max=\(strokes.max() ?? 0)")
        XCTAssertGreaterThan(returns, 40, "reachable balls are returned with no gesture at all")
        XCTAssertGreaterThanOrEqual(avg, 5, "regular rallies of 5+ total exchanges")
    }

    func testDifficultyChangesNoGestureOutcome() {
        // Same opponent for all three; only the player's assistance changes.
        // Success = share of the player's turns that ended in a good return.
        func success(_ assist: AssistLevel) -> Double {
            let r = noGestureMatch(assist: assist, difficulty: .intermediate, seconds: 150)
            let lost = r.sim.score.points(.far) + r.sim.score.games(.far) * 11
            return Double(r.returns) / Double(max(r.returns + lost, 1))
        }
        let b = success(.beginner), i = success(.standard), a = success(.expert)
        print("no-gesture success vs Intermediate CPU: beginner \(b) standard \(i) expert \(a)")
        XCTAssertGreaterThan(b, 0.9)
        XCTAssertGreaterThan(b, i)
        XCTAssertGreaterThan(i, a)
    }

    func testEarlyGestureExecutesBufferedShot() {
        for (dy, expected) in [(0.2, ShotKind.topspin), (-0.2, ShotKind.backspin)] {
            let sim = setup(assist: .beginner, mode: .training)
            var executed = 0, attempts = 0
            for _ in 0..<6 {
                guard waitForCPUHit(sim) else { break }
                for _ in 0..<24 { sim.step(); _ = sim.drainEvents() }   // 0.1 s after the CPU hit
                swipe(sim, dx: 0, dy: dy)
                attempts += 1
                let buffered = sim.player?.buffer.command?.kind
                guard let hit = waitForPlayerContact(sim) else { continue }
                XCTAssertEqual(buffered, expected)
                XCTAssertEqual(sim.player?.executedShots.last?.kind, expected)
                let spin = SpinReading(ball: hit.ballAfter)
                if expected == .topspin { XCTAssertGreaterThan(spin.topspin, 0) } else { XCTAssertLessThan(spin.topspin, 0) }
                XCTAssertNil(sim.player?.buffer.command, "the shot is cleared after execution")
                executed += 1
            }
            XCTAssertGreaterThanOrEqual(executed, attempts - 1, "\(expected): \(executed)/\(attempts)")
            XCTAssertGreaterThan(executed, 3)
        }
    }

    func testLaterGestureReplacesEarlierOne() {
        let sim = setup(assist: .beginner, mode: .training)
        XCTAssertTrue(waitForCPUHit(sim))
        swipe(sim, dx: 0, dy: -0.2)      // backspin first...
        XCTAssertEqual(sim.player?.buffer.command?.kind, .backspin)
        swipe(sim, dx: 0, dy: 0.2)       // ...then topspin
        XCTAssertEqual(sim.player?.buffer.command?.kind, .topspin)
        XCTAssertNotNil(waitForPlayerContact(sim))
        XCTAssertEqual(sim.player?.executedShots.last?.kind, .topspin)
    }

    func testGestureBeforeCPUHitIsNotCarriedOver() {
        let sim = setup(assist: .beginner, mode: .training)
        // Swipe while the CPU is still preparing its serve: not incoming yet.
        for _ in 0..<(240 * 2) { sim.step(); _ = sim.drainEvents() }
        swipe(sim, dx: 0, dy: -0.2)
        XCTAssertNil(sim.player?.buffer.command)
        XCTAssertTrue(waitForCPUHit(sim))
        XCTAssertNotNil(waitForPlayerContact(sim))
        XCTAssertEqual(sim.player?.executedShots.last?.kind, .standard, "no gesture → default return")
    }

    // MARK: Direct physics harness (single incoming ball)

    private struct Flight {
        var hits = 0
        var maxStep = 0.0
        var hitPoint: Vec3?
        var paddleAtHit: Vec3?
        var hitRadiusAfterPass = 0.0
        var nearBounce: Vec3?
    }

    /// Fires one ball from the far side at the player's paddle and runs the
    /// real physics + player controller for 1.6 s.
    private func fly(ball start: BallState, assist: AssistLevel, gestureAt: Double? = nil,
                     gesture: [GestureInterpreter.Sample]? = nil) -> (Flight, PlayerPaddleController) {
        var settings = ControlSettings()
        settings.assist = assist
        let player = PlayerPaddleController(side: .near, settings: settings)
        let config = PhysicsConfig()
        var world = PhysicsWorld(config: config)
        world.release(velocity: .zero)
        world.ball = start
        let far = PaddleState(position: Vec3(0, 0.9, -2.5), normal: .unitZ, hitRadius: 0)
        var bounced = false
        var f = Flight()
        var prev = player.paddle.position
        var lastHitter: Side? = .far
        var injected = false
        for i in 0..<Int(1.6 / config.fixedTimestep) {
            let t = world.time
            if let g = gesture, let at = gestureAt, !injected, t >= at {
                injected = true
                for s in g {
                    player.enqueue(InputEvent(phase: s == g.first! ? .began : (s == g.last! ? .ended : .moved),
                                              time: t + s.t, u: 0.5, v: 0.3, screenX: s.x, screenY: s.y))
                }
            }
            var ctx = DriverContext(time: t, dt: config.fixedTimestep, ball: world.ball, ballHeld: false,
                                    phase: .rally, refereePhase: .rally, server: .far, lastHitter: lastHitter,
                                    lastHitTime: 0, config: config, opponentPaddle: far)
            ctx.bouncedSinceHit = bounced
            let out = player.update(ctx)
            if i > 0 { f.maxStep = max(f.maxStep, (out.paddle.position - prev).length) }
            prev = out.paddle.position
            let events = world.step(near: out.paddle, far: far) { _, incoming, paddle in
                player.contactNormal(incoming: incoming, paddle: paddle, ctx: ctx)
            }
            for e in events {
                if e.kind == .tableBounce && e.side == .near { bounced = true; f.nearBounce = e.point }
                if e.kind == .paddleHit && e.side == .near {
                    f.hits += 1; f.hitPoint = e.point; f.paddleAtHit = out.paddle.position
                    lastHitter = .near
                }
            }
            if f.hits == 0 && world.ball.position.z > 2.6 { f.hitRadiusAfterPass = max(f.hitRadiusAfterPass, out.paddle.hitRadius) }
        }
        return (f, player)
    }

    private let central = BallState(position: Vec3(0.1, 1.0, -1.45), velocity: Vec3(-0.05, 1.6, 4.6))

    func testReachableBallIsHitExactlyOnceAtThePaddle() {
        for assist in AssistLevel.allCases {
            let (f, _) = fly(ball: central, assist: assist)
            XCTAssertEqual(f.hits, 1, "\(assist): one contact, no duplicates")
            if let h = f.hitPoint, let p = f.paddleAtHit {
                XCTAssertLessThan((h - p).length, 0.15, "\(assist): contact happens at the paddle")
            }
            // No teleporting: per-tick moves stay within a fast real stroke.
            XCTAssertLessThan(f.maxStep, 0.06, "\(assist): paddle must move smoothly")
        }
    }

    func testUnreachableBallIsNotReturnedAndLeavesNoPhantomStrike() {
        // Legal balls (they bounce on the player's half) that kick ever wider.
        var outOfReach = 0, returned = 0
        for vx in stride(from: 1.0, through: 4.6, by: 0.2) {
            let ball = BallState(position: Vec3(-1.0, 1.0, -1.45), velocity: Vec3(vx, 1.6, 4.6))
            let (f, player) = fly(ball: ball, assist: .expert)
            guard let bounce = f.nearBounce, abs(bounce.x) < 0.76 else { continue }
            if f.hits == 0 {
                // Too wide or too fast to reach: a legitimate miss with a reason.
                outOfReach += 1
                XCTAssertNotNil(player.diagnostics.lastMiss, "vx \(vx): a miss always has a reason")
                XCTAssertEqual(f.hitRadiusAfterPass, 0, "vx \(vx): no delayed phantom strike")
            } else {
                XCTAssertEqual(f.hits, 1, "vx \(vx): reachable balls are returned once")
                returned += 1
            }
        }
        print("wide balls: returned \(returned), out of reach \(outOfReach)")
        XCTAssertGreaterThan(outOfReach, 0)
        XCTAssertGreaterThan(returned, 0)
    }

    func testPaddleOrientationFollowsSelectedShot() {
        // Topspin closes the blade (normal tilts down), backspin opens it.
        let top = fly(ball: central, assist: .standard, gestureAt: 0.1, gesture: path(dx: 0, dy: 0.2)).1
        let back = fly(ball: central, assist: .standard, gestureAt: 0.1, gesture: path(dx: 0, dy: -0.2)).1
        XCTAssertEqual(top.executedShots.last?.kind, .topspin)
        XCTAssertEqual(back.executedShots.last?.kind, .backspin)
        func faceY(_ g: [GestureInterpreter.Sample]) -> Double {
            var settings = ControlSettings(); settings.assist = .standard
            let p = PlayerPaddleController(side: .near, settings: settings)
            let config = PhysicsConfig()
            var ball = central
            let far = PaddleState(position: Vec3(0, 0.9, -2.5), normal: .unitZ, hitRadius: 0)
            for s in g {
                p.enqueue(InputEvent(phase: s == g.first! ? .began : (s == g.last! ? .ended : .moved),
                                     time: 0, u: 0.5, v: 0.3, screenX: s.x, screenY: s.y))
            }
            var out: DriverOutput!
            for i in 0..<60 {
                let ctx = DriverContext(time: Double(i) / 240, dt: 1.0 / 240, ball: ball, ballHeld: false,
                                        phase: .rally, refereePhase: .rally, server: .far, lastHitter: .far,
                                        lastHitTime: 0, config: config, opponentPaddle: far)
                out = p.update(ctx)
                BallPhysics.integrate(&ball, h: 1.0 / 240, aero: config.aero)
            }
            return out.paddle.normal.y
        }
        XCTAssertLessThan(faceY(path(dx: 0, dy: 0.2)), faceY(path(dx: 0, dy: -0.2)))
    }
}
