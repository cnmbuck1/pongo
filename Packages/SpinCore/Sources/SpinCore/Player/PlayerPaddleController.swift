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
    /// Timing quality of the current (or last) stroke.
    public private(set) var strokeTiming: StrokeTiming?

    // Auto paddle state.
    struct AutoPlan {
        var contactTime: Double
        var contactPoint: Vec3
        var stroke: Vec3
    }
    private var autoPlan: AutoPlan?
    private var motion: PaddleMotion
    private var touchPath: [GestureInterpreter.Sample] = []
    private var incomingHitTime: Double = -100
    private var contactDone = false
    /// The shot selected for the current incoming ball.
    public private(set) var buffer = ShotBuffer()
    /// Live diagnostics for the developer overlay.
    public private(set) var diagnostics = PaddleDiagnostics()
    /// Every shot executed at contact (tests / stats).
    public private(set) var executedShots: [ShotCommand] = []
    /// Optional gameplay event log (developer diagnostics).
    public var eventLog: ((String) -> Void)?
    private var queuedServeIsDefault = false
    private var strokeScale = 1.0
    /// Lead (s) between the ideal swipe and contact.
    public static let idealLead = 0.10
    static let autoSwingDuration = 0.085

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
        motion = PaddleMotion(position: position)
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
        autoPlan = nil
        strokeTiming = nil
        buffer.clear()
        contactDone = false
        incomingHitTime = -100
        queuedServeIsDefault = false
    }

    // MARK: Swipe mapping

    /// Maps finger velocity (screen heights per second, y up) to a stroke
    /// velocity in world space (m/s).
    public func strokeVelocity(fingerVX: Double, fingerVY: Double) -> Vec3 {
        let s = settings.swipeSensitivity
        let m = settings.mapping
        let speed = (fingerVX * fingerVX + fingerVY * fingerVY).squareRoot()
        let forward = clamp((m.basePower + m.powerPerSpeed * speed) * s, 1.0, m.maxForward)
        let vertical = clamp(m.verticalBrush * fingerVY * s, -4.5, 4.5)
        let lateral = clamp(m.lateralBrush * fingerVX * s, -4.0, 4.0)
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
        if settings.scheme == .autoTrack {
            let serving = ctx.isServing(side) && ctx.refereePhase == .awaitingServe
            if !serving { return updateAuto(ctx) }
            // Serving uses the shared serve logic from a fixed stance.
            padU = 0.5; padV = 0.25
            autoPlan = nil
            // Beginner: a tap alone serves (a gentle default serve), and a
            // swipe still picks a different one.
            if settings.assist == .beginner, !ctx.ballHeld, queuedServe == nil, activeSwing == nil,
               ctx.ball.velocity.y > 0 {
                queuedServe = Vec3(0, -0.3, side.hitDirection * 5.3)
                queuedServeIsDefault = true
                strokeTiming = .good
            }
        }
        let out = updateManual(ctx)
        motion.velocity = (position - motion.position) / max(ctx.dt, 1e-6)
        motion.position = position
        return out
    }

    private func updateManual(_ ctx: DriverContext) -> DriverOutput {
        lastCtx = ctx
        tick += 1
        let now = ctx.time
        var requestToss = false
        let serving = ctx.isServing(side) && ctx.refereePhase == .awaitingServe
        if !serving || ctx.ballHeld && queuedServe == nil {
            serveLock = nil
        }
        if ctx.ballHeld { queuedServe = nil; queuedServeIsDefault = false }
        let frozen = serveLock != nil || (settings.scheme == .dragAndFlick && now < flickFreezeUntil)
        let auto = settings.scheme == .autoTrack

        // 1. Consume input up to now.
        pending.sort { $0.time < $1.time }
        while let e = pending.first, e.time <= now + 1e-9 {
            pending.removeFirst()
            switch e.phase {
            case .began:
                touching = true
                samples = [(e.time, e.screenX, e.screenY)]
                touchStartUV = auto ? (padU, padV) : (e.u, e.v)
                if !frozen && !auto { padU = e.u; padV = e.v }
                // Tap to toss.
                if serving && ctx.ballHeld { requestToss = true }
            case .moved:
                samples.append((e.time, e.screenX, e.screenY))
                if !frozen && !auto { padU = e.u; padV = e.v }
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
                if serving {
                    // One-swipe serve: toss now, strike when the ball drops.
                    if ctx.ballHeld { requestToss = true }
                    if queuedServe == nil || queuedServeIsDefault {
                        strokeTiming = serveTiming(ctx)
                    }
                    if queuedServe == nil || queuedServeIsDefault || stroke.length > queuedServe!.length {
                        queuedServeIsDefault = false
                        queuedServe = stroke
                        lastSwipeLateral = clamp(fv.0 / max(speed, 1e-6), -1, 1)
                    }
                    if serveLock == nil {
                        serveLock = touchStartUV
                        padU = touchStartUV.u
                        padV = touchStartUV.v
                    }
                } else if !auto, activeSwing == nil || now > swingUntil || stroke.length > activeSwing!.length {
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
            queuedServeIsDefault = false
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

    // MARK: Timing

    /// Serve timing: how far the swipe is from the ideal moment, which is
    /// shortly before the tossed ball drops back to the blade. Serve windows
    /// are wider than rally windows; a serve swipe is never ignored.
    private func serveTiming(_ ctx: DriverContext) -> StrokeTiming {
        let g = 9.81
        let y0 = ctx.ballHeld ? serveHoldPoint(paddle: paddle, side: side).y : ctx.ball.position.y
        let vy = ctx.ballHeld ? 2.0 : ctx.ball.velocity.y
        let h = position.y + 0.10
        // Time until the ball falls through h: y0 + vy t − g t²/2 = h.
        let disc = vy * vy + 2 * g * (y0 - h)
        let tRelease = disc > 0 ? max(0, (vy + disc.squareRoot()) / g) : 0
        let w = settings.assist.timing
        let serveWindows = TimingWindows(perfect: w.perfect * 1.8, good: w.good * 2.2, accept: .infinity)
        return serveWindows.classify(tRelease - Self.idealLead) ?? .good
    }

    // MARK: Auto paddle (Build 3)

    /// Build 3 control: the paddle intercepts every reachable ball by itself
    /// and strikes it at the real contact. A swipe made while the ball is on
    /// its way only selects the shot (it is buffered, the latest one wins,
    /// and it locks just before contact). With no swipe the paddle plays a
    /// default return. Timing changes shot quality, never whether contact
    /// happens; difficulty changes reach, tracking, timing penalties and the
    /// quality of the default return.
    private func updateAuto(_ ctx: DriverContext) -> DriverOutput {
        lastCtx = ctx
        tick += 1
        let now = ctx.time
        let config = ctx.config
        let assist = settings.assist
        queuedServe = nil
        serveLock = nil
        activeSwing = nil

        let incoming = ctx.ballIncoming(to: side)
        if incoming && ctx.lastHitTime != incomingHitTime {
            // A new incoming ball: fresh buffer, fresh contact.
            incomingHitTime = ctx.lastHitTime
            buffer.clear()
            contactDone = false
            autoPlan = nil
            intercept = nil
            strokeScale = 1
            diagnostics.lastMiss = nil
            log("incoming ball")
        }

        // 1. Input: completed gestures select the shot.
        pending.sort { $0.time < $1.time }
        while let e = pending.first, e.time <= now + 1e-9 {
            pending.removeFirst()
            switch e.phase {
            case .began:
                touching = true
                touchPath = [GestureInterpreter.Sample(t: e.time, x: e.screenX, y: e.screenY)]
            case .moved:
                touchPath.append(GestureInterpreter.Sample(t: e.time, x: e.screenX, y: e.screenY))
            case .ended, .cancelled:
                touchPath.append(GestureInterpreter.Sample(t: e.time, x: e.screenX, y: e.screenY))
                touching = false
                if e.phase == .ended { completeGesture(ctx, incoming: incoming) }
                touchPath = []
            }
        }

        // 2. Prediction (after the reaction delay) and reachability.
        if incoming && !contactDone && now - ctx.lastHitTime >= assist.reactionDelay {
            if tick % 3 == 0 || intercept == nil || interceptComputedAt < ctx.lastHitTime {
                let fresh = InterceptPlanner.intercept(ball: ctx.ball, side: side, config: config,
                                                       preferredDepth: reach.defaultDepth - 0.05,
                                                       alreadyBounced: ctx.bouncedSinceHit)
                intercept = fresh ?? (ctx.bouncedSinceHit ? intercept : nil)
                interceptComputedAt = now
            }
        } else if !incoming {
            intercept = nil
        }
        let backOff = Vec3(0, 0, side.hitDirection) * (config.ball.radius + config.paddleHalfThickness)
        var reachable = false
        if let ic = intercept, !contactDone {
            reachable = isReachable(ic.point)
            if reachable {
                if var p = autoPlan {
                    if p.contactTime - now > Self.autoSwingDuration {
                        // Follow the latest prediction until the swing starts.
                        p.contactTime = now + ic.timeFromNow
                        p.contactPoint = ic.point - backOff
                        autoPlan = p
                    }
                } else {
                    autoPlan = AutoPlan(contactTime: now + ic.timeFromNow, contactPoint: ic.point - backOff,
                                        stroke: .zero)
                    log(String(format: "intercept t=%.2f x=%.2f y=%.2f", ic.timeFromNow, ic.point.x, ic.point.y))
                }
            } else {
                if autoPlan != nil { log("intercept now out of reach") }
                autoPlan = nil
                diagnostics.lastMiss = .outOfReach
            }
        }

        // 3. Lock the shot just before contact; build the stroke.
        if var p = autoPlan, !contactDone {
            let remaining = p.contactTime - now
            if remaining <= assist.shotTiming.lock && !buffer.locked {
                buffer.lock()
                strokeScale = 1
                if assist.strokeSafety, let ic = intercept { strokeScale = safeStrokeScale(ball: ic.ball, config: config) }
                log("shot locked: \(buffer.command?.label ?? "default")" + (strokeScale < 1 ? String(format: " eased x%.2f", strokeScale) : ""))
            }
            p.stroke = currentStroke()
            autoPlan = p
        }

        // 4. Target pose and motion.
        let home = Vec3(0, 0.96, side.zSign * reach.defaultDepth)
        var target = home
        var feedForward = Vec3.zero
        var maxSpeed = assist.trackSpeed
        var maxAccel = assist.trackAcceleration
        var gain = 9.0
        var striking = false
        if let p = autoPlan {
            let remaining = p.contactTime - now
            if remaining > Self.autoSwingDuration {
                target = p.contactPoint - p.stroke * Self.autoSwingDuration
            } else if remaining > -0.12 {
                // Swing through the contact point, then follow through.
                target = p.contactPoint + p.stroke * (-remaining)
                feedForward = p.stroke
                maxSpeed = max(maxSpeed, p.stroke.length * 1.2)
                maxAccel = 110
                gain = 14
                striking = !contactDone
            } else {
                if !contactDone {
                    diagnostics.lastMiss = .lateContact
                    log("missed contact (paddle late)")
                    buffer.clear()
                    // This ball is gone: no second attempt, no phantom strike.
                    contactDone = true
                }
                autoPlan = nil
            }
        } else if let ic = intercept, !contactDone {
            // Out of reach: still lean toward the ball, inside the reach limits.
            target = ic.point - backOff + Vec3(0, 0, side.zSign * 0.22)
        } else if !incoming || contactDone {
            // Recover toward the middle while the ball is away.
            target = Vec3(position.x * 0.6, 0.96, side.zSign * reach.defaultDepth)
            maxSpeed *= 0.6
        }
        motion.steer(toward: autoClamp(target), feedForward: feedForward, dt: ctx.dt,
                     maxSpeed: maxSpeed, maxAccel: maxAccel, gain: gain)
        motion.position = autoClamp(motion.position, swing: true)
        position = motion.position
        depth = abs(position.z)

        // The blade can only touch the ball during the planned stroke, once.
        let radius = striking ? config.paddleRadius + assist.extraHitRadius : 0
        // During the stroke the blade moves along the planned swing (the
        // motion above follows it); contact uses that swing velocity so the
        // selected shot, not leftover tracking speed, decides the return.
        let velocity = striking ? (autoPlan?.stroke ?? motion.velocity) : motion.velocity
        paddle = PaddleState(position: position, velocity: velocity,
                             normal: autoNormal(stroke: autoPlan?.stroke ?? currentStroke(), at: position),
                             hitRadius: radius)

        diagnostics.interceptPoint = intercept?.point
        diagnostics.targetPosition = target
        diagnostics.actualPosition = position
        diagnostics.contactEligible = striking
        diagnostics.reachable = reachable
        diagnostics.bufferedShot = buffer.command
        diagnostics.bufferedTiming = buffer.timing
        diagnostics.timeToContact = autoPlan.map { $0.contactTime - now }
        return DriverOutput(paddle: paddle, requestToss: false)
    }

    private func isReachable(_ p: Vec3) -> Bool {
        let a = settings.assist
        return abs(p.x) <= a.lateralReach && a.heightReach.contains(p.y)
    }

    /// The selected (or default) shot as a paddle stroke, with timing applied.
    private func currentStroke() -> Vec3 {
        let cmd = buffer.command ?? settings.shots.defaultShot
        var stroke = cmd.stroke(for: side)
        stroke = Vec3(stroke.x * strokeScale, stroke.y * max(strokeScale, 0.6), stroke.z * strokeScale)
        if buffer.command != nil, let t = buffer.timing {
            stroke = stroke * (1 - (1 - t.power) * settings.assist.timingPenalty)
        }
        return stroke
    }

    /// Eases the stroke off until it can land (assisted levels only).
    private func safeStrokeScale(ball: BallState, config: PhysicsConfig) -> Double {
        let saved = strokeScale
        defer { strokeScale = saved }
        var best = (scale: 1.0, score: Double.infinity)
        for scale in [1.0, 0.85, 0.7, 0.55, 0.42] {
            strokeScale = scale
            let stroke = currentStroke()
            let goal = autoGoal(paddleX: position.x, forward: abs(stroke.z), config: config)
            let sol = ShotSolver.solve(incoming: ball, paddleVelocity: stroke, goal: goal, config: config)
            if sol.evaluation.landsLegally && sol.evaluation.score < 0.45 { return scale }
            if sol.evaluation.score < best.score { best = (scale, sol.evaluation.score) }
        }
        return best.scale
    }

    private func autoGoal(paddleX: Double, forward: Double, config: PhysicsConfig) -> ShotSolver.Goal {
        let depthFromNet = forward < 2.5 ? 0.62 : clamp(0.62 + (forward - 2.5) * 0.12, 0.62, 1.05)
        let target = Vec3(autoAimX(at: Vec3(paddleX, 0, 0)), config.table.surfaceHeight, side.opponent.zSign * depthFromNet)
        return ShotSolver.Goal(hitter: side, isServe: false, target: target)
    }

    private func completeGesture(_ ctx: DriverContext, incoming: Bool) {
        guard let cmd = GestureInterpreter.interpret(touchPath, tuning: settings.shots,
                                                     spinScale: settings.assist.spinScale) else { return }
        // Shots are taken from the opponent's hit until our contact.
        guard incoming, !contactDone else {
            log("gesture ignored (\(cmd.label)): ball not incoming")
            return
        }
        let ttc = autoPlan.map { $0.contactTime - ctx.time } ?? intercept?.timeFromNow
        let timing = ttc.map { settings.assist.shotTiming.classify(timeToContact: $0) } ?? .early
        if buffer.offer(cmd, timing: timing) {
            log("shot buffered: \(cmd.label) \(buffer.timing?.rawValue ?? "")")
        } else {
            log("gesture ignored (\(cmd.label)): shot locked")
        }
    }

    /// Blade angle while tracking: closed for topspin, open for backspin,
    /// turned toward the selected placement.
    private func autoNormal(stroke: Vec3, at position: Vec3) -> Vec3 {
        let pitch = clamp(0.12 - stroke.y * 0.11, -0.55, 0.75)
        let yaw = atan((autoAimX(at: position) - position.x) / 2.4)
        return ShotSolver.faceNormal(for: side, pitch: pitch, yaw: yaw)
    }

    private func autoAimX(at position: Vec3) -> Double {
        let cmd = buffer.command ?? settings.shots.defaultShot
        if cmd.placement == 0 { return clamp(-position.x * 0.25, -0.3, 0.3) }
        // Placement is as the player sees it: screen right is world +x for the
        // near side, and mirrored for the far side.
        return clamp(cmd.placement * 0.52 * (side == .near ? 1 : -1), -0.6, 0.6)
    }

    private func autoContactNormal(incoming: BallState, paddle: PaddleState, ctx: DriverContext) -> Vec3 {
        let config = ctx.config
        let assist = settings.assist
        let chosen = buffer.command
        let cmd = chosen ?? settings.shots.defaultShot
        let timing = chosen != nil ? buffer.timing : nil
        let goal = autoGoal(paddleX: paddle.position.x, forward: abs(paddle.velocity.z), config: config)
        let offset = incoming.position - paddle.position
        let raw = instinctiveNormal(incoming: incoming, paddleVelocity: paddle.velocity, goal: goal, config: config,
                                    offset: offset)
        let solved = ShotSolver.solve(incoming: incoming, paddleVelocity: paddle.velocity, goal: goal, config: config,
                                      contactOffset: offset)
        let penalty = assist.timingPenalty
        let accuracy = timing.map { 1 - (1 - $0.accuracy) * penalty } ?? 1
        let quality = chosen == nil ? assist.defaultReturnQuality : 1
        let hardness = clamp((incoming.velocity.length - 10) / 10, 0, 0.25)
        // The blade lands between the instinctive angle (spin ignored) and the
        // solved one; the leftover error is capped per level so a well-chosen,
        // well-timed shot is reliable and a poor one drifts.
        let a = clamp(assist.aimAssist * accuracy * quality * (1 - hardness), 0, 1)
        let (rp, ry) = ShotSolver.angles(of: raw, side: side)
        let (sp, sy) = ShotSolver.angles(of: solved.normal, side: side)
        let cap = assist.maxAimError * (2 - accuracy) * (chosen == nil ? assist.defaultReturnLooseness : 1)
        let pitch = sp + clamp((rp - sp) * (1 - a), -cap, cap)
        var yaw = sy + clamp((ry - sy) * (1 - a), -cap, cap)
        if let t = timing { yaw += t.yawError * penalty }
        let n = ShotSolver.faceNormal(for: side, pitch: pitch, yaw: yaw)
        // One authoritative contact: the shot is executed and cleared.
        contactDone = true
        strokeTiming = timing
        diagnostics.lastShot = cmd
        diagnostics.lastTiming = timing
        diagnostics.lastMiss = nil
        executedShots.append(cmd)
        log("contact: \(cmd.label) \(timing?.rawValue ?? "default")")
        buffer.clear()
        return n
    }

    private func log(_ message: String) {
        guard let hook = eventLog else { return }
        hook(String(format: "[%.3f] ", lastCtx?.time ?? 0) + message)
    }

    private func autoClamp(_ p: Vec3, swing: Bool = false) -> Vec3 {
        var r = reach
        // The auto paddle may reach in over the table for short balls.
        r.depthRange = 0.32...r.depthRange.upperBound
        if swing {
            r.yRange = (r.yRange.lowerBound - 0.08)...(r.yRange.upperBound + 0.2)
            r.depthRange = (r.depthRange.lowerBound - 0.1)...(r.depthRange.upperBound + 0.2)
            r.xRange = (r.xRange.lowerBound - 0.1)...(r.xRange.upperBound + 0.1)
        }
        return r.clampPosition(p, side: side)
    }

    // MARK: Blade angle

    /// Where the natural stroke aims laterally (x on the opponent's half).
    private func aimX(at position: Vec3) -> Double {
        let swinging = activeSwing != nil
        return clamp(-position.x * 0.3 + lastSwipeLateral * settings.mapping.lateralPlacement * (swinging ? 1 : 0.3),
                     -0.6, 0.6)
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
        if settings.scheme == .autoTrack && ctx.refereePhase != .awaitingServe {
            return autoContactNormal(incoming: incoming, paddle: paddle, ctx: ctx)
        }
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
        // Timing scales assistance; fast incoming balls are harder to place.
        let timing = strokeTiming
        let hardness = clamp((incoming.velocity.length - 10) / 10, 0, 0.25)
        let assist = settings.assist.aimAssist * (timing?.accuracy ?? 1) * (1 - hardness)
        var n = Vec3.slerp(raw, solved.normal, assist)
        if let t = timing, t.yawError != 0 {
            let (pitch, yaw) = ShotSolver.angles(of: n, side: side)
            n = ShotSolver.faceNormal(for: side, pitch: pitch, yaw: yaw + t.yawError)
        }
        return n
    }
}
