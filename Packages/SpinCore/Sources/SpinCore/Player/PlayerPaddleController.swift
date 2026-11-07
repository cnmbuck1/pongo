import Foundation

/// Turns timestamped touch input into paddle motion for the human player.
///
/// * Finger position → paddle lateral position and height (within the legal
///   reachable region).
/// * Finger swipe velocity → stroke velocity: every swipe drives the blade
///   toward the opponent, faster swipes drive harder; the swipe's vertical
///   component brushes the ball up (topspin) or down (backspin), and its
///   horizontal component brushes sideways (sidespin).
/// * Paddle depth (distance from the table) is managed automatically from
///   the predicted ball path, since a 2D touch can't express depth.
///
/// The resulting paddle velocity, contact point and blade angle then go
/// through the same collision physics as every other contact.
public final class PlayerPaddleController: PaddleDriver {

    public let side: Side
    public var settings: ControlSettings
    public var reach = PaddleReach()
    public private(set) var paddle: PaddleState

    // Touch state.
    private var pending: [InputEvent] = []
    public private(set) var touching = false
    private var padU = 0.5
    private var padV = 0.3
    private var samples: [(t: Double, x: Double, y: Double)] = []

    // Stroke state.
    public private(set) var activeSwing: Vec3?
    private var swingUntil: Double = -1
    private var flickFreezeUntil: Double = -1
    private var swingOffset: Double = 0
    private var lastSwipeLateral: Double = 0

    // One-swipe serve: a swipe while holding the ball tosses it and queues
    // the stroke, which is released automatically as the ball drops back to
    // the blade. The paddle holds where the swipe started meanwhile.
    public private(set) var queuedServe: Vec3?
    private var serveLock: (u: Double, v: Double)?
    private var touchStartUV = (u: 0.5, v: 0.3)

    // Positioning.
    private var position: Vec3
    private var depth: Double
    private var intercept: InterceptPlanner.Intercept?
    private var interceptComputedAt: Double = -1
    private var tick = 0
    private var lastCtx: DriverContext?

    /// Swipe speed (screen heights / s) above which a movement is a stroke.
    public static let swingThreshold = 0.85
    public static let maxSwingOffset = 0.38

    public init(side: Side = .near, settings: ControlSettings = ControlSettings()) {
        self.side = side
        self.settings = settings
        let r = PaddleReach()
        depth = r.defaultDepth
        position = Vec3(0, 0.96, side.zSign * r.defaultDepth)
        paddle = PaddleState(position: position, normal: Vec3(0, 0, side.hitDirection),
                             hitRadius: PhysicsConfig().paddleRadius)
    }

    /// Queue a touch event (from the UI thread via the simulation).
    public func enqueue(_ event: InputEvent) {
        pending.append(event)
    }

    public func resetForPoint(config: PhysicsConfig) {
        activeSwing = nil
        swingUntil = -1
        flickFreezeUntil = -1
        swingOffset = 0
        intercept = nil
        queuedServe = nil
        serveLock = nil
    }

    // MARK: Swipe mapping

    /// Maps finger velocity (screen heights per second, y up) to a stroke
    /// velocity in world space (m/s).
    public func strokeVelocity(fingerVX: Double, fingerVY: Double) -> Vec3 {
        let s = settings.swipeSensitivity
        let speed = (fingerVX * fingerVX + fingerVY * fingerVY).squareRoot()
        let forward = clamp((1.0 + 1.5 * speed) * s, 1.0, 9.0)
        let vertical = clamp(0.95 * fingerVY * s, -4.5, 4.5)
        let lateral = clamp(0.8 * fingerVX * s, -4.0, 4.0)
        return Vec3(lateral, vertical, side.hitDirection * forward)
    }

    private func fingerVelocity(now: Double) -> (Double, Double)? {
        guard touching, let last = samples.last, now - last.t < 0.06 else { return nil }
        guard let first = samples.first(where: { $0.t >= last.t - 0.065 }) else { return nil }
        let dt = last.t - first.t
        guard dt > 0.012 else { return nil }
        return ((last.x - first.x) / dt, (last.y - first.y) / dt)
    }

    // MARK: Update

    public func update(_ ctx: DriverContext) -> DriverOutput {
        lastCtx = ctx
        tick += 1
        let now = ctx.time
        var requestToss = false
        let serving = ctx.isServing(side) && ctx.refereePhase == .awaitingServe
        if !serving || ctx.ballHeld && queuedServe == nil {
            serveLock = nil
        }
        if ctx.ballHeld { queuedServe = nil }
        let frozen = serveLock != nil || (settings.scheme == .dragAndFlick && now < flickFreezeUntil)

        // 1. Consume input up to now.
        pending.sort { $0.time < $1.time }
        while let e = pending.first, e.time <= now + 1e-9 {
            pending.removeFirst()
            switch e.phase {
            case .began:
                touching = true
                samples = [(e.time, e.screenX, e.screenY)]
                touchStartUV = (e.u, e.v)
                if !frozen { padU = e.u; padV = e.v }
            case .moved:
                samples.append((e.time, e.screenX, e.screenY))
                if !frozen { padU = e.u; padV = e.v }
            case .ended, .cancelled:
                samples.append((e.time, e.screenX, e.screenY))
                touching = false
            }
        }
        samples.removeAll { $0.t < now - 0.2 }

        // 2. Strokes.
        let window = settings.assist.timingWindow
        if let fv = fingerVelocity(now: now) {
            let speed = (fv.0 * fv.0 + fv.1 * fv.1).squareRoot()
            if speed > Self.swingThreshold {
                var stroke = strokeVelocity(fingerVX: fv.0, fingerVY: fv.1)
                if ctx.isServing(side) {
                    // Serves are short brushing strokes: keep the pace in a
                    // servable range and damp the brush so the ball can still
                    // be driven down onto the server's own half.
                    let fwd = clamp(abs(stroke.z), 5.0, 6.2)
                    stroke = Vec3(stroke.x * 0.5, clamp(stroke.y * 0.35, -0.8, 0.4), side.hitDirection * fwd)
                }
                if serving && (ctx.ballHeld || queuedServe != nil) {
                    // One-swipe serve: toss now, strike when the ball drops.
                    if ctx.ballHeld { requestToss = true }
                    if queuedServe == nil || stroke.length > queuedServe!.length {
                        queuedServe = stroke
                        lastSwipeLateral = clamp(fv.0 / max(speed, 1e-6), -1, 1)
                    }
                    if serveLock == nil {
                        serveLock = touchStartUV
                        padU = touchStartUV.u
                        padV = touchStartUV.v
                    }
                } else if activeSwing == nil || now > swingUntil || stroke.length > activeSwing!.length {
                    activeSwing = stroke
                    lastSwipeLateral = clamp(fv.0 / max(speed, 1e-6), -1, 1)
                }
                swingUntil = now + window
                if settings.scheme == .dragAndFlick && now >= flickFreezeUntil {
                    flickFreezeUntil = now + max(window, 0.15)
                }
            }
        }
        // Release a queued serve as the tossed ball falls back to the blade.
        if let q = queuedServe, serving, !ctx.ballHeld,
           ctx.ball.velocity.y < 0, ctx.ball.position.y < position.y + 0.10 {
            activeSwing = q
            swingUntil = now + max(window, 0.15)
            queuedServe = nil
        }
        if now > swingUntil { activeSwing = nil }

        // 3. Predicted interception (for depth and positioning assistance).
        if ctx.ballIncoming(to: side) {
            if tick % 3 == 0 || intercept == nil || interceptComputedAt < ctx.lastHitTime {
                intercept = InterceptPlanner.intercept(ball: ctx.ball, side: side, config: ctx.config,
                                                       preferredDepth: reach.defaultDepth - 0.05,
                                                       alreadyBounced: ctx.bouncedSinceHit) ?? (ctx.bouncedSinceHit ? intercept : nil)
                interceptComputedAt = now
            }
        } else if ctx.isServing(side) && !ctx.ballHeld && ctx.refereePhase == .awaitingServe {
            // Own toss: help line the blade up with the falling ball.
            // Own toss: help line the blade up with the falling ball
            // (laterally only; the toss falls back to blade height).
            intercept = InterceptPlanner.Intercept(timeFromNow: 0,
                                                   point: Vec3(ctx.ball.position.x, position.y, ctx.ball.position.z),
                                                   ball: ctx.ball)
        } else {
            intercept = nil
        }

        // 4. Desired position.
        var x = reach.xRange.lowerBound + (reach.xRange.upperBound - reach.xRange.lowerBound) * clamp(padU, 0, 1)
        var y = reach.yRange.lowerBound + (reach.yRange.upperBound - reach.yRange.lowerBound) * clamp(padV, 0, 1)
        var depthTarget = reach.defaultDepth
        if let ic = intercept {
            let servingToss = ctx.isServing(side) && !ctx.ballIncoming(to: side)
            let a = servingToss ? (serveLock != nil ? 1.0 : max(settings.assist.positionAssist, 0.7))
                                : settings.assist.positionAssist
            x += (ic.point.x - x) * a
            y += (ic.point.y - y) * a
            if ctx.ballIncoming(to: side) {
                depthTarget = abs(ic.point.z) + 0.03 + 0.10
            }
        }
        let depthStep = 3.2 * ctx.dt
        depth += clamp(depthTarget - depth, -depthStep, depthStep)
        depth = clamp(depth, reach.depthRange.lowerBound, reach.depthRange.upperBound)

        if let s = activeSwing {
            swingOffset = min(Self.maxSwingOffset, swingOffset + abs(s.z) * ctx.dt)
        } else {
            swingOffset = max(0, swingOffset - 1.6 * ctx.dt)
        }

        let desired = reach.clampPosition(Vec3(x, y, side.zSign * depth), side: side)
            + Vec3(0, 0, side.hitDirection * swingOffset)
        let alpha = 1 - exp(-ctx.dt / 0.022)
        let previous = position
        position = previous + (desired - previous) * alpha
        let actualVelocity = (position - previous) / max(ctx.dt, 1e-6)

        let velocity = activeSwing ?? actualVelocity
        paddle = PaddleState(position: position, velocity: velocity,
                             normal: naturalNormal(swing: activeSwing, at: position),
                             hitRadius: ctx.config.paddleRadius + settings.assist.extraHitRadius)
        return DriverOutput(paddle: paddle, requestToss: requestToss)
    }

    // MARK: Blade angle

    /// Where the natural stroke aims laterally (x on the opponent's half).
    private func aimX(at position: Vec3) -> Double {
        clamp(-position.x * 0.3 + lastSwipeLateral * 0.45 * (activeSwing == nil ? 0.3 : 1), -0.6, 0.6)
    }

    /// The blade angle a player would naturally present for this stroke:
    /// closed for an upward brush, open for a downward brush, turned toward
    /// the aim point.
    public func naturalNormal(swing: Vec3?, at position: Vec3) -> Vec3 {
        let s = swing ?? .zero
        let pitch = clamp(0.12 - s.y * 0.11, -0.55, 0.75)
        let yaw = atan((aimX(at: position) - position.x) / 2.4)
        return ShotSolver.faceNormal(for: side, pitch: pitch, yaw: yaw)
    }

    /// The blade angle an average player would instinctively present at the
    /// moment of contact: the angle that would land the ball on the aim point
    /// *if spin did not exist* (incoming spin ignored, no Magnus curve).
    /// Reading and compensating for spin is the skill; control assistance
    /// supplies part of that compensation by blending toward the full solution.
    public func instinctiveNormal(incoming: BallState, paddleVelocity: Vec3, goal: ShotSolver.Goal,
                                  config: PhysicsConfig, offset: Vec3 = .zero) -> Vec3 {
        var spinless = config
        spinless.aero.magnusCoefficient = 0
        var ball = incoming
        ball.spin = .zero
        let base = ShotSolver.solve(incoming: ball, paddleVelocity: paddleVelocity, goal: goal, config: spinless,
                                    contactOffset: offset).normal
        // The swipe direction also tilts the blade: brushing up closes the
        // face, brushing down opens it (this is how a player compensates).
        let (pitch, yaw) = ShotSolver.angles(of: base, side: side)
        let tilt = clamp(-paddleVelocity.y * 0.05, -0.2, 0.2)
        return ShotSolver.faceNormal(for: side, pitch: pitch + tilt, yaw: yaw)
    }

    public func contactNormal(incoming: BallState, paddle: PaddleState, ctx: DriverContext) -> Vec3 {
        let config = ctx.config
        let isServe = ctx.refereePhase == .awaitingServe
        let forward = abs(paddle.velocity.z)
        let depthFromNet = isServe ? 0.9 : (forward < 2.5 ? 0.6 : clamp(0.6 + (forward - 2.5) * 0.12, 0.6, 1.1))
        let target = Vec3(aimX(at: paddle.position), config.table.surfaceHeight, side.opponent.zSign * depthFromNet)
        let goal = ShotSolver.Goal(hitter: side, isServe: isServe, target: target)
        let raw = instinctiveNormal(incoming: incoming, paddleVelocity: paddle.velocity, goal: goal, config: config,
                                    offset: incoming.position - paddle.position)
        let solved = ShotSolver.solve(incoming: incoming, paddleVelocity: paddle.velocity, goal: goal, config: config,
                                      contactOffset: incoming.position - paddle.position)
        // The stroke is consumed by the contact.
        swingUntil = min(swingUntil, ctx.time + 0.02)
        let assist = settings.assist.aimAssist
        return Vec3.slerp(raw, solved.normal, assist)
    }
}
