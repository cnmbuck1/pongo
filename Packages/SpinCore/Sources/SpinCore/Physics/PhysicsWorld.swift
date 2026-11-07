import Foundation

/// The physical world: one ball, two paddles, table, net and floor.
///
/// The world knows nothing about rules, AI or input. Each call to `step`
/// advances exactly one fixed timestep. Collisions use swept sub-steps so a
/// fast ball cannot tunnel through the paddle, net or table.
public struct PhysicsWorld: Codable {
    public var config: PhysicsConfig
    public var ball: BallState
    /// When true the ball is held (e.g. by the server before the toss) and
    /// does not move under physics.
    public var ballHeld: Bool = true
    public private(set) var time: Double = 0
    public private(set) var nearPaddle: PaddleState
    public private(set) var farPaddle: PaddleState
    private var lastContactTime: [Side: Double] = [:]

    public init(config: PhysicsConfig = PhysicsConfig()) {
        self.config = config
        let t = config.table
        ball = BallState(position: Vec3(0, t.surfaceHeight + 0.3, t.halfLength + 0.2))
        nearPaddle = PaddleState(position: Vec3(0, 0.95, t.halfLength + 0.2), normal: -.unitZ,
                                 hitRadius: config.paddleRadius)
        farPaddle = PaddleState(position: Vec3(0, 0.95, -t.halfLength - 0.2), normal: .unitZ,
                                hitRadius: config.paddleRadius)
    }

    public func paddle(_ side: Side) -> PaddleState { side == .near ? nearPaddle : farPaddle }

    /// Called at the moment of a paddle impact so the paddle's controller can
    /// supply the final face orientation. Returns the face normal to use.
    public typealias FaceNormalProvider = (_ side: Side, _ incoming: BallState, _ paddle: PaddleState) -> Vec3

    /// Advances one fixed timestep.
    /// - Parameters:
    ///   - near/far: paddle states at the *end* of this tick. Paddle motion is
    ///     interpolated linearly from the previous tick during sub-steps.
    public mutating func step(near: PaddleState, far: PaddleState,
                              faceNormal: FaceNormalProvider) -> [PhysicsEvent] {
        let dt = config.fixedTimestep
        let prevNear = nearPaddle, prevFar = farPaddle
        nearPaddle = near
        farPaddle = far
        var events: [PhysicsEvent] = []
        defer { time += dt }

        guard !ballHeld else { return events }

        // Sub-step count from the largest relative speed.
        let vb = ball.velocity
        let rel = max(vb.length, (vb - near.velocity).length, (vb - far.velocity).length)
        let n = BallPhysics.substepCount(relativeSpeed: rel, dt: dt, maxTravel: config.maxSubstepTravel)
        let h = dt / Double(n)

        for i in 0..<n {
            let f = Double(i + 1) / Double(n)
            let tNow = time + h * Double(i + 1)
            BallPhysics.integrate(&ball, h: h, aero: config.aero)

            for side in Side.allCases {
                let prev = side == .near ? prevNear : prevFar
                let cur = side == .near ? near : far
                if let last = lastContactTime[side], tNow - last < config.paddleContactCooldown { continue }
                var p = cur
                p.position = Vec3.lerp(prev.position, cur.position, f)
                p.normal = Vec3.slerp(prev.normal, cur.normal, f)
                guard let lateral = PaddleCollision.detect(ball: ball, paddle: p, config: config) else { continue }
                let incoming = ball
                let face = faceNormal(side, incoming, p)
                if let res = PaddleCollision.resolve(ball: &ball, paddle: p, faceNormal: face,
                                                     lateralOffset: lateral, config: config) {
                    lastContactTime[side] = tNow
                    events.append(PhysicsEvent(kind: .paddleHit, side: side, point: ball.position,
                                               impactSpeed: res.normalSpeed, ballAfter: ball, time: tNow))
                }
            }
            BallPhysics.collideStatic(&ball, config: config, time: tNow, events: &events)
        }
        return events
    }

    /// Places the ball (held) at a position.
    public mutating func hold(at position: Vec3) {
        ballHeld = true
        ball = BallState(position: position)
    }

    /// Releases the ball with an initial velocity (a serve toss).
    public mutating func release(velocity: Vec3, spin: Vec3 = .zero) {
        ballHeld = false
        ball.velocity = velocity
        ball.spin = spin
    }

    /// Forget contact cooldowns (e.g. between points).
    public mutating func resetContacts() { lastContactTime = [:] }
}
