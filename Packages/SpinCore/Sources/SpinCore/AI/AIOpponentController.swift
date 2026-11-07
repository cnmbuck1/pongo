import Foundation

/// Computer opponent.
///
/// Pipeline per incoming shot:
/// 1. Wait `reactionDelay` after the opponent's contact.
/// 2. Predict the interception point with the full physics (spin included).
/// 3. Choose a target and a stroke (swing velocity: speed + brushing for spin).
/// 4. Move the paddle with speed/acceleration limits to a ready point behind
///    the interception, then swing through it.
/// 5. At contact, choose the blade angle with `ShotSolver` for the *actual*
///    paddle velocity, plus aim noise.
///
/// The AI never touches the ball directly; it only moves its paddle.
public final class AIOpponentController: PaddleDriver {

    public let side: Side
    public var profile: AIProfile
    public private(set) var paddle: PaddleState
    public var reach = PaddleReach()
    private var rng: RandomSource
    private var motion: PaddleMotion

    /// Stroke duration from ready point to contact.
    private let swingDuration = 0.085
    private let swingAcceleration = 110.0

    struct Plan {
        var contactTime: Double          // absolute sim time
        var contactPoint: Vec3           // where the paddle should meet the ball
        var swingVelocity: Vec3
        var goal: ShotSolver.Goal
        var faceNormal: Vec3
        var aimErrorScale: Double
        var refined: Bool
    }
    private var plan: Plan? {
        didSet { if let p = plan { debugLog?("plan t=\(p.contactTime) cp=\(p.contactPoint) swing=\(p.swingVelocity) serve=\(p.goal.isServe) target=\(p.goal.target)") } }
    }
    /// Optional diagnostics hook (tests / tuning).
    public var debugLog: ((String) -> Void)?
    private var plannedForHitTime: Double = -1
    private var serveWait: Double = 0
    private var serveDelay: Double = 1.1
    private var stance = Vec3.zero
    private var lastCtx: DriverContext?

    public init(side: Side, profile: AIProfile, seed: UInt64 = 0xC0FFEE) {
        self.side = side
        self.profile = profile
        self.rng = RandomSource(seed: seed)
        let home = Vec3(0, 0.95, side.zSign * 1.75)
        motion = PaddleMotion(position: home)
        paddle = PaddleState(position: home, normal: Vec3(0, 0, side.hitDirection), hitRadius: PhysicsConfig().paddleRadius)
    }

    public func resetForPoint(config: PhysicsConfig) {
        plan = nil
        plannedForHitTime = -1
        serveWait = 0
        serveDelay = 0.9 + rng.uniform(0, 0.6)
        stance = Vec3(rng.uniform(-0.35, 0.35), 0.92, side.zSign * reach.defaultDepth)
    }

    private var home: Vec3 { Vec3(0, 0.98, side.zSign * 1.78) }

    public func update(_ ctx: DriverContext) -> DriverOutput {
        lastCtx = ctx
        let config = ctx.config
        var requestToss = false
        var target = home
        var feedForward = Vec3.zero
        var maxSpeed = profile.maxSpeed
        var maxAccel = profile.maxAcceleration
        var gain = 9.0

        if ctx.isServing(side) && ctx.ballHeld {
            // Serve stance; toss after a short pause.
            target = stance
            serveWait += ctx.dt
            if serveWait >= serveDelay, (motion.position - stance).length < 0.03 { requestToss = true }
            plan = nil
        } else if ctx.isServing(side) && ctx.refereePhase == .awaitingServe {
            if plan == nil { planServe(ctx) }
        } else if ctx.ballIncoming(to: side) {
            if plannedForHitTime != ctx.lastHitTime && ctx.time - ctx.lastHitTime >= profile.reactionDelay {
                planReturn(ctx, refine: false)
                plannedForHitTime = ctx.lastHitTime
            } else if let p = plan, !p.refined, p.contactTime - ctx.time < 0.32, p.contactTime - ctx.time > 0.15 {
                // A second look closer to the ball improves the estimate.
                planReturn(ctx, refine: true)
            }
        } else if ctx.lastHitter == side, let p = plan, ctx.time > p.contactTime + 0.08 {
            plan = nil
        }

        if let p = plan {
            let remaining = p.contactTime - ctx.time
            if remaining > swingDuration {
                target = p.contactPoint - p.swingVelocity * swingDuration
                // Arrive a little early, then hold.
            } else if remaining > -0.12 {
                // Stroke: follow the swing line through the contact point.
                target = p.contactPoint + p.swingVelocity * (-remaining)
                feedForward = p.swingVelocity
                maxSpeed = max(maxSpeed, p.swingVelocity.length * 1.2)
                maxAccel = swingAcceleration
                gain = 14
            } else {
                plan = nil
            }
        }

        let clamped = reachClamp(target)
        motion.steer(toward: clamped, feedForward: feedForward, dt: ctx.dt,
                     maxSpeed: maxSpeed, maxAccel: maxAccel, gain: gain)
        motion.position = reachClamp(motion.position, allowSwing: true)
        let normal = plan?.faceNormal ?? Vec3(0, 0, side.hitDirection)
        paddle = PaddleState(position: motion.position, velocity: motion.velocity, normal: normal,
                             hitRadius: config.paddleRadius)
        return DriverOutput(paddle: paddle, requestToss: requestToss)
    }

    private func reachClamp(_ p: Vec3, allowSwing: Bool = false) -> Vec3 {
        var r = reach
        if allowSwing {
            r.yRange = (r.yRange.lowerBound - 0.08)...(r.yRange.upperBound + 0.15)
            r.depthRange = (r.depthRange.lowerBound - 0.1)...(r.depthRange.upperBound + 0.2)
            r.xRange = (r.xRange.lowerBound - 0.1)...(r.xRange.upperBound + 0.1)
        }
        return r.clampPosition(p, side: side)
    }

    // MARK: Planning

    private func chooseTarget(ctx: DriverContext) -> Vec3 {
        let opp = side.opponent
        let width = profile.placementWidth * 0.62
        var x = rng.uniform(-1, 1) * width
        if profile.strategicPlacement {
            let oppX = ctx.opponentPaddle.position.x
            x = (oppX > 0 ? -1 : 1) * rng.uniform(0.25, 1.0) * width
        }
        let depth = 0.55 + profile.aggressiveness * 0.45 + rng.uniform(-0.15, 0.2)
        return Vec3(x, ctx.config.table.surfaceHeight, opp.zSign * clamp(depth, 0.35, 1.15))
    }

    private func chooseSwing(forReturn: Bool) -> Vec3 {
        let dir = side.hitDirection
        var forward: Double
        var vertical: Double
        var lateral = 0.0
        if forReturn {
            forward = (1.6 + profile.aggressiveness * 4.6) * rng.uniform(0.85, 1.1)
            // Pick topspin vs backspin according to the bias.
            let wantsTop = rng.uniform(-1, 1) < profile.topspinBias
            let brush = profile.spinPreference * rng.uniform(0.5, 1.0) * 2.8
            vertical = wantsTop ? brush : -brush * 0.8
            if !wantsTop { forward *= 0.75 }
        } else {
            forward = (4.6 + profile.aggressiveness * 1.2) * rng.uniform(0.92, 1.08)
            // Serves: mostly backspin or float, sometimes topspin.
            vertical = (rng.chance(0.65) ? -1 : 0.6) * profile.spinPreference * rng.uniform(0.6, 1.0) * 2.4
        }
        if rng.chance(profile.sidespinPreference) {
            lateral = (rng.chance(0.5) ? -1 : 1) * profile.spinPreference * rng.uniform(1.0, 2.6)
        }
        return Vec3(lateral, vertical, dir * forward)
    }

    private func planServe(_ ctx: DriverContext) {
        guard let ic = InterceptPlanner.tossIntercept(ball: ctx.ball, config: ctx.config,
                                                     contactHeight: ctx.ball.position.y - 0.03) else { return }
        let target = Vec3(rng.uniform(-0.45, 0.45) * profile.placementWidth / 0.5 * 0.5,
                          ctx.config.table.surfaceHeight,
                          side.opponent.zSign * rng.uniform(0.7, 1.15))
        let goal = ShotSolver.Goal(hitter: side, isServe: true, target: target)
        var swing = chooseSwing(forReturn: false)
        var best = ShotSolver.solve(incoming: ic.ball, paddleVelocity: swing, goal: goal, config: ctx.config)
        if !best.evaluation.landsLegally {
            // Fall back to a plain, gentle serve.
            let plain = Vec3(0, -0.3, side.hitDirection * 5.2)
            let alt = ShotSolver.solve(incoming: ic.ball, paddleVelocity: plain, goal: goal, config: ctx.config)
            if alt.evaluation.score < best.evaluation.score { best = alt; swing = plain }
        }
        let contactPoint = ic.point - best.normal * (ctx.config.ball.radius + ctx.config.paddleHalfThickness)
        plan = Plan(contactTime: ctx.time + ic.timeFromNow, contactPoint: contactPoint, swingVelocity: swing,
                    goal: goal, faceNormal: best.normal, aimErrorScale: 0.6, refined: true)
    }

    private func planReturn(_ ctx: DriverContext, refine: Bool) {
        guard let ic = InterceptPlanner.intercept(ball: ctx.ball, side: side, config: ctx.config,
                                                  preferredDepth: reach.defaultDepth - 0.05,
                                                  alreadyBounced: ctx.bouncedSinceHit) else {
            // Ball is going out (or into the net): let it go. A failed
            // refinement keeps the original plan.
            if !refine { plan = nil }
            return
        }
        var aimScale = 1.0
        var errorOffset = Vec3(rng.gaussian(sd: profile.predictionError),
                               rng.gaussian(sd: profile.predictionError),
                               rng.gaussian(sd: profile.predictionError * 0.5))
        if refine, let old = plan {
            // Keep the chosen stroke and target, update the geometry.
            aimScale = old.aimErrorScale
            errorOffset = errorOffset * 0.5
            let face = ShotSolver.solve(incoming: ic.ball, paddleVelocity: old.swingVelocity, goal: old.goal,
                                        config: ctx.config).normal
            let cp = ic.point + errorOffset - face * (ctx.config.ball.radius + ctx.config.paddleHalfThickness)
            plan = Plan(contactTime: ctx.time + ic.timeFromNow, contactPoint: cp, swingVelocity: old.swingVelocity,
                        goal: old.goal, faceNormal: face, aimErrorScale: aimScale, refined: true)
            return
        }
        if rng.chance(profile.mistakeProbability) {
            if rng.chance(0.5) {
                // Misjudges the ball.
                errorOffset += Vec3(rng.uniform(-1, 1) * 0.11, rng.uniform(-1, 1) * 0.09, 0)
            } else {
                aimScale = 5
            }
        }
        let goal = ShotSolver.Goal(hitter: side, isServe: false, target: chooseTarget(ctx: ctx))
        let base = chooseSwing(forReturn: true)
        var best: (ShotSolver.Solution, Vec3, Double)?
        // Back off swing speed until a stroke that lands (at a pace this
        // profile is comfortable with) is found.
        for scale in [1.0, 0.8, 0.62, 0.45, 0.3, 0.15] {
            let swing = Vec3(base.x * scale, base.y * max(scale, 0.6), base.z * scale)
            let sol = ShotSolver.solve(incoming: ic.ball, paddleVelocity: swing, goal: goal, config: ctx.config)
            let out = PaddleCollision.strike(ball: ic.ball, paddleVelocity: swing, faceNormal: sol.normal, config: ctx.config)
            let pace = out.velocity.length
            let penalty = sol.evaluation.score + max(0, pace - profile.maxShotSpeed) * 0.25
            if best == nil || penalty < best!.2 { best = (sol, swing, penalty) }
            if sol.evaluation.landsLegally && sol.evaluation.score < 0.45 && pace <= profile.maxShotSpeed { break }
        }
        let (sol, swing, _) = best!
        let cp = ic.point + errorOffset - sol.normal * (ctx.config.ball.radius + ctx.config.paddleHalfThickness)
        plan = Plan(contactTime: ctx.time + ic.timeFromNow, contactPoint: cp, swingVelocity: swing,
                    goal: goal, faceNormal: sol.normal, aimErrorScale: aimScale, refined: false)
    }

    // MARK: Contact

    public func contactNormal(incoming: BallState, paddle: PaddleState, ctx: DriverContext) -> Vec3 {
        let config = (lastCtx ?? ctx).config
        let goal = plan?.goal ?? ShotSolver.Goal(hitter: side, isServe: ctx.refereePhase == .awaitingServe,
                                                 target: Vec3(0, config.table.surfaceHeight, side.opponent.zSign * 0.8))
        let sol = ShotSolver.solve(incoming: incoming, paddleVelocity: paddle.velocity, goal: goal, config: config,
                                   contactOffset: incoming.position - paddle.position)
        let scale = plan?.aimErrorScale ?? 1
        let deg = Double.pi / 180
        let (p, y) = ShotSolver.angles(of: sol.normal, side: side)
        let pitch = p + rng.gaussian(sd: profile.aimErrorDegrees * scale * deg)
        let yaw = y + rng.gaussian(sd: profile.aimErrorDegrees * scale * deg)
        return ShotSolver.faceNormal(for: side, pitch: pitch, yaw: yaw)
    }
}
