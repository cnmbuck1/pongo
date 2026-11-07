import Foundation

/// Everything a paddle controller (human or AI) may observe each tick.
/// Controllers never mutate the ball: they only output a paddle state.
public struct DriverContext {
    public var time: Double
    public var dt: Double
    public var ball: BallState
    public var ballHeld: Bool
    public var phase: MatchPhase
    public var refereePhase: RallyReferee.Phase
    public var server: Side
    public var lastHitter: Side?
    public var lastHitTime: Double
    public var config: PhysicsConfig
    public var opponentPaddle: PaddleState
    /// True once the ball has bounced on the receiving half since the last hit.
    public var bouncedSinceHit: Bool = false

    public init(time: Double, dt: Double, ball: BallState, ballHeld: Bool, phase: MatchPhase,
                refereePhase: RallyReferee.Phase, server: Side, lastHitter: Side?, lastHitTime: Double,
                config: PhysicsConfig, opponentPaddle: PaddleState) {
        self.time = time; self.dt = dt; self.ball = ball; self.ballHeld = ballHeld; self.phase = phase
        self.refereePhase = refereePhase; self.server = server; self.lastHitter = lastHitter
        self.lastHitTime = lastHitTime; self.config = config; self.opponentPaddle = opponentPaddle
    }

    /// True while `side` should be preparing to receive / return the ball.
    public func ballIncoming(to side: Side) -> Bool {
        guard !ballHeld else { return false }
        switch refereePhase {
        case .serveNeedsServerBounce, .serveNeedsReceiverBounce, .rally:
            return lastHitter == side.opponent
        default:
            return false
        }
    }

    public func isServing(_ side: Side) -> Bool {
        phase == .serving && server == side
    }
}

public struct DriverOutput {
    public var paddle: PaddleState
    /// Ask the simulation to toss the ball (only honoured when this side is
    /// serving and the ball is held).
    public var requestToss: Bool

    public init(paddle: PaddleState, requestToss: Bool = false) {
        self.paddle = paddle; self.requestToss = requestToss
    }
}

/// A paddle controller. The human player and the AI both implement this, and
/// the simulation treats them identically — the AI gets no special access to
/// the ball's physics.
public protocol PaddleDriver: AnyObject {
    var side: Side { get }
    var paddle: PaddleState { get }
    /// Called at the start of every point.
    func resetForPoint(config: PhysicsConfig)
    func update(_ ctx: DriverContext) -> DriverOutput
    /// Final blade angle at the instant of contact.
    func contactNormal(incoming: BallState, paddle: PaddleState, ctx: DriverContext) -> Vec3
    /// Optional: the outgoing ball for this contact, decided by the shot
    /// (arcade shot execution). Called right after `contactNormal` for the
    /// same contact. nil = pure blade physics.
    func outgoingBall(incoming: BallState, paddle: PaddleState, ctx: DriverContext) -> BallState?
}

public extension PaddleDriver {
    func outgoingBall(incoming: BallState, paddle: PaddleState, ctx: DriverContext) -> BallState? { nil }
}

/// Reachable region for a paddle, mirrored for each side.
public struct PaddleReach: Codable, Equatable {
    public var xRange: ClosedRange<Double> = -1.05...1.05
    public var yRange: ClosedRange<Double> = 0.80...1.42
    /// Distance from the net (|z|).
    public var depthRange: ClosedRange<Double> = 0.50...2.40
    public var defaultDepth: Double = 1.62

    public init() {}

    public func clampPosition(_ p: Vec3, side: Side) -> Vec3 {
        let depth = clamp(abs(p.z), depthRange.lowerBound, depthRange.upperBound)
        return Vec3(clamp(p.x, xRange.lowerBound, xRange.upperBound),
                    clamp(p.y, yRange.lowerBound, yRange.upperBound),
                    depth * side.zSign)
    }
}

/// Where the server holds the ball relative to the blade before tossing.
public func serveHoldPoint(paddle: PaddleState, side: Side) -> Vec3 {
    paddle.position + Vec3(0, 0.03, side.hitDirection * 0.10)
}

/// Rate-limited point-mass motion used for paddles (no teleporting).
public struct PaddleMotion: Codable, Equatable {
    public var position: Vec3
    public var velocity: Vec3 = .zero

    public init(position: Vec3) { self.position = position }

    /// Steers toward `target` with a desired-velocity controller limited by
    /// `maxSpeed` and `maxAccel`. `feedForward` is a velocity to add (used for
    /// strokes that must pass through a point at a given speed).
    public mutating func steer(toward target: Vec3, feedForward: Vec3 = .zero, dt: Double,
                               maxSpeed: Double, maxAccel: Double, gain: Double = 9) {
        var desired = (target - position) * gain + feedForward
        let s = desired.length
        let cap = max(maxSpeed, feedForward.length)
        if s > cap { desired = desired * (cap / s) }
        var dv = desired - velocity
        let maxDv = maxAccel * dt
        if dv.length > maxDv { dv = dv.normalized * maxDv }
        velocity += dv
        position += velocity * dt
    }
}
