import Foundation

/// Something the presentation layer (rendering, audio, haptics, HUD) may
/// want to react to. The simulation never calls into presentation code.
public enum GameEvent: Equatable {
    case physics(PhysicsEvent)
    case serveTossed(Side)
    case point(winner: Side, reason: PointReason)
    case letCalled
    case gameWon(by: Side, game: Int)
    case matchWon(by: Side)
    case phaseChanged(MatchPhase)
}

public enum GameMode: String, Codable {
    /// Scored match against the AI.
    case match
    /// Unscored practice: the AI always serves, enhanced spin feedback.
    case training
}

public struct GameSetup: Codable, Equatable {
    public var mode: GameMode = .match
    public var difficulty: AIDifficulty = .intermediate
    public var controls = ControlSettings()
    public var format = MatchFormat()
    public var firstServer: Side = .near
    public var seed: UInt64 = 2026
    public var physics = PhysicsConfig()

    public init() {}
}

/// Serializable summary of the match (for UI, save/restore and future
/// network sync).
public struct MatchSnapshot: Codable, Equatable {
    public var phase: MatchPhase
    public var score: ScoreKeeper
    public var referee: RallyReferee
    public var stats: MatchStats
    public var ball: BallState
    public var ballHeld: Bool
    public var time: Double
}

/// Information about the most recent paddle contact (training overlay).
public struct ContactReport: Equatable {
    public var side: Side
    public var time: Double
    public var paddleSpeed: Double
    public var ballSpeed: Double
    public var spin: SpinReading
    public var point: Vec3
}

/// Owns the whole game simulation: physics world, both paddle drivers, rules,
/// score and the match state machine. Advance it with `advance(by:)` from any
/// render loop; it always simulates in fixed timesteps.
public final class GameSimulation {

    public private(set) var setup: GameSetup
    public private(set) var world: PhysicsWorld
    public private(set) var referee: RallyReferee
    public private(set) var score: ScoreKeeper
    public private(set) var machine = MatchStateMachine()
    public private(set) var stats = MatchStats()
    public private(set) var lastContact: ContactReport?
    /// Recent table bounce points (training overlay).
    public private(set) var recentBounces: [Vec3] = []

    public let nearDriver: PaddleDriver
    public let farDriver: PaddleDriver
    /// The human controller if the near side is human-controlled.
    public var player: PlayerPaddleController? { nearDriver as? PlayerPaddleController }

    private var clock: FixedStepClock
    private var pendingEvents: [GameEvent] = []
    private var lastHitTime: Double = -10
    private var lastEventTime: Double = 0
    private var tossTime: Double = -1
    private var pendingOutcome: ScoreKeeper.Outcome?
    private var replayPoint = false
    private var nearReturnPending = false

    public var readyDuration = 1.3
    public var pointPause = 1.25
    public var gamePause = 2.2

    public var time: Double { world.time }
    public var phase: MatchPhase { machine.phase }
    public var dt: Double { setup.physics.fixedTimestep }

    /// Standard human-vs-AI game.
    public convenience init(setup: GameSetup) {
        let human = PlayerPaddleController(side: .near, settings: setup.controls)
        let ai = AIOpponentController(side: .far, profile: setup.difficulty.profile, seed: setup.seed)
        self.init(setup: setup, near: human, far: ai)
    }

    /// Any pair of drivers (e.g. AI vs AI for tests or attract mode).
    public init(setup: GameSetup, near: PaddleDriver, far: PaddleDriver) {
        var s = setup
        if s.mode == .training { s.firstServer = .far }
        self.setup = s
        self.nearDriver = near
        self.farDriver = far
        self.world = PhysicsWorld(config: s.physics)
        self.score = ScoreKeeper(format: s.format, firstServer: s.firstServer)
        self.referee = RallyReferee(server: s.firstServer, tableHalfLength: s.physics.table.halfLength)
        self.clock = FixedStepClock(step: s.physics.fixedTimestep)
        beginPoint()
    }

    public func driver(_ side: Side) -> PaddleDriver { side == .near ? nearDriver : farDriver }

    /// Current server (training: the AI always feeds).
    public var server: Side { setup.mode == .training ? .far : score.server }

    // MARK: Control

    /// Queue a touch for the human player at the current simulation time.
    public func handleInput(phase: InputEvent.Phase, u: Double, v: Double, screenX: Double, screenY: Double) {
        player?.enqueue(InputEvent(phase: phase, time: world.time, u: u, v: v, screenX: screenX, screenY: screenY))
    }

    public func enqueue(_ event: InputEvent) { player?.enqueue(event) }

    /// Restart the match from 0–0.
    public func restartMatch() {
        world = PhysicsWorld(config: setup.physics)
        score = ScoreKeeper(format: setup.format, firstServer: setup.firstServer)
        stats = MatchStats()
        machine.reset()
        pendingOutcome = nil
        lastContact = nil
        recentBounces = []
        beginPoint()
        pendingEvents.append(.phaseChanged(.ready))
    }

    public func setDifficulty(_ d: AIDifficulty) {
        setup.difficulty = d
        (farDriver as? AIOpponentController)?.profile = d.profile
    }

    public func setControls(_ c: ControlSettings) {
        setup.controls = c
        player?.settings = c
    }

    /// Returns and clears events produced since the last call.
    public func drainEvents() -> [GameEvent] {
        defer { pendingEvents.removeAll() }
        return pendingEvents
    }

    /// Advance by real elapsed time; runs 0 or more fixed steps.
    public func advance(by elapsed: Double) {
        let n = clock.advance(by: elapsed)
        for _ in 0..<n { step() }
    }

    public var renderAlpha: Double { clock.alpha }

    public func snapshot() -> MatchSnapshot {
        MatchSnapshot(phase: machine.phase, score: score, referee: referee, stats: stats,
                      ball: world.ball, ballHeld: world.ballHeld, time: world.time)
    }

    // MARK: Simulation step

    private func beginPoint() {
        referee = RallyReferee(server: server, tableHalfLength: setup.physics.table.halfLength)
        nearDriver.resetForPoint(config: setup.physics)
        farDriver.resetForPoint(config: setup.physics)
        world.resetContacts()
        let sp = driver(server).paddle
        world.hold(at: serveHoldPoint(paddle: sp, side: server))
        tossTime = -1
        lastHitTime = -10
        nearReturnPending = false
        recentBounces = []
    }

    private func transition(_ p: MatchPhase) {
        if machine.transition(to: p) { pendingEvents.append(.phaseChanged(p)) }
    }

    private func context(for side: Side) -> DriverContext {
        var ctx = DriverContext(time: world.time, dt: dt, ball: world.ball, ballHeld: world.ballHeld,
                                phase: machine.phase, refereePhase: referee.phase, server: server,
                                lastHitter: referee.lastHitter, lastHitTime: lastHitTime, config: setup.physics,
                                opponentPaddle: driver(side.opponent).paddle)
        ctx.bouncedSinceHit = referee.phase == .rally && referee.bouncedOnReceiver
        return ctx
    }

    /// One fixed timestep.
    public func step() {
        machine.tick(dt)
        switch machine.phase {
        case .ready:
            if machine.timeInPhase >= readyDuration {
                beginPoint()
                transition(.serving)
            }
        case .pointEnded:
            if machine.timeInPhase >= pointPause { finishPoint() }
        case .gameEnded:
            if machine.timeInPhase >= gamePause {
                score.startNextGame()
                transition(.ready)
            }
        case .serving, .rally, .matchEnded:
            break
        }

        let nearCtx = context(for: .near)
        let farCtx = context(for: .far)
        let nearOut = nearDriver.update(nearCtx)
        let farOut = farDriver.update(farCtx)

        // Server holds the ball in front of the blade until the toss.
        if machine.phase == .serving || machine.phase == .ready {
            if world.ballHeld {
                let sp = server == .near ? nearOut.paddle : farOut.paddle
                world.hold(at: serveHoldPoint(paddle: sp, side: server))
                let wantsToss = server == .near ? nearOut.requestToss : farOut.requestToss
                if machine.phase == .serving && wantsToss {
                    world.release(velocity: Vec3(0, 2.0, 0))
                    tossTime = world.time
                    lastEventTime = world.time
                    pendingEvents.append(.serveTossed(server))
                }
            }
        }

        let events = world.step(near: nearOut.paddle, far: farOut.paddle, faceNormal: { [unowned self] side, incoming, paddle in
            let ctx = side == .near ? nearCtx : farCtx
            return self.driver(side).contactNormal(incoming: incoming, paddle: paddle, ctx: ctx)
        }, outgoing: { [unowned self] side, incoming, paddle in
            let ctx = side == .near ? nearCtx : farCtx
            return self.driver(side).outgoingBall(incoming: incoming, paddle: paddle, ctx: ctx)
        })

        for e in events { process(e) }

        // Dropped toss: re-hold the ball (no penalty in this prototype).
        if machine.phase == .serving && !world.ballHeld && referee.phase == .awaitingServe {
            let sp = driver(server).paddle
            if world.ball.position.y < sp.position.y - 0.25 || world.time - tossTime > 2.5 {
                world.hold(at: serveHoldPoint(paddle: sp, side: server))
                tossTime = -1
            }
        }

        // Safety nets: ball left the arena or play stalled.
        if machine.phase == .rally {
            let p = world.ball.position
            if abs(p.z) > 7 || abs(p.x) > 6 || world.time - lastEventTime > 3.5 {
                apply(referee.ballDead())
            }
        }
    }

    private func process(_ e: PhysicsEvent) {
        pendingEvents.append(.physics(e))
        lastEventTime = e.time
        if e.kind == .paddleHit, let side = e.side {
            lastHitTime = e.time
            let paddle = driver(side).paddle
            lastContact = ContactReport(side: side, time: e.time, paddleSpeed: paddle.velocity.length,
                                        ballSpeed: e.ballAfter.velocity.length,
                                        spin: SpinReading(ball: e.ballAfter), point: e.point)
            if machine.phase == .rally || machine.phase == .serving {
                stats.fastestShot = max(stats.fastestShot, e.ballAfter.velocity.length)
                stats.maxSpin = max(stats.maxSpin, e.ballAfter.spin.length)
            }
        }
        if e.kind == .tableBounce {
            recentBounces.append(e.point)
            if recentBounces.count > 6 { recentBounces.removeFirst() }
        }

        switch machine.phase {
        case .serving:
            if referee.phase == .awaitingServe {
                // Before the serve is struck only the server's paddle matters;
                // a toss landing on the table/floor is simply re-tossed.
                guard e.kind == .paddleHit else { return }
                guard e.side == server else { return }
                let ruling = referee.handle(e)
                transition(.rally)
                apply(ruling)
            }
        case .rally:
            let ruling = referee.handle(e)
            if ruling == .play {
                if e.kind == .paddleHit { nearReturnPending = e.side == .near }
                if e.kind == .tableBounce, e.side == .far, nearReturnPending {
                    stats.successfulReturns += 1
                    nearReturnPending = false
                }
            }
            apply(ruling)
        default:
            break
        }
    }

    private func apply(_ ruling: RefereeRuling) {
        switch ruling {
        case .play:
            return
        case .let_:
            pendingEvents.append(.letCalled)
            replayPoint = true
            pendingOutcome = nil
            transition(.pointEnded)
        case let .point(winner, reason):
            stats.recordPoint(winner: winner, strokes: referee.strokes)
            pendingEvents.append(.point(winner: winner, reason: reason))
            replayPoint = false
            if setup.mode == .match {
                let outcome = score.award(to: winner)
                pendingOutcome = outcome
                switch outcome {
                case let .gameWon(by: s): pendingEvents.append(.gameWon(by: s, game: score.gameNumber))
                case let .matchWon(by: s): pendingEvents.append(.matchWon(by: s))
                case .pointAwarded: break
                }
            } else {
                pendingOutcome = .pointAwarded
            }
            transition(.pointEnded)
        }
    }

    private func finishPoint() {
        let outcome = pendingOutcome
        pendingOutcome = nil
        if replayPoint {
            replayPoint = false
            beginPoint()
            transition(.serving)
            return
        }
        switch outcome {
        case .matchWon?:
            transition(.matchEnded)
            world.ballHeld = true
        case .gameWon?:
            transition(.gameEnded)
            world.ballHeld = true
        default:
            beginPoint()
            transition(.serving)
        }
    }
}
