import Foundation

/// Complete kinematic state of the ball.
public struct BallState: Codable, Equatable {
    public var position: Vec3
    public var velocity: Vec3
    /// Angular velocity (rad/s). Direction is the spin axis (right-hand rule).
    public var spin: Vec3

    public init(position: Vec3, velocity: Vec3 = .zero, spin: Vec3 = .zero) {
        self.position = position
        self.velocity = velocity
        self.spin = spin
    }
}

/// State of a paddle for one simulation tick.
public struct PaddleState: Codable, Equatable {
    /// Centre of the blade face.
    public var position: Vec3
    /// Linear velocity of the blade (m/s).
    public var velocity: Vec3
    /// Unit normal of the hitting face, pointing toward the opponent.
    public var normal: Vec3
    /// Effective hit radius (blade radius plus any assistance tolerance).
    public var hitRadius: Double

    public init(position: Vec3, velocity: Vec3 = .zero, normal: Vec3, hitRadius: Double) {
        self.position = position
        self.velocity = velocity
        self.normal = normal.normalized
        self.hitRadius = hitRadius
    }
}
