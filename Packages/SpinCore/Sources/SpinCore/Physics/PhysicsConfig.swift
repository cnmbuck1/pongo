import Foundation

/// Which end of the table. `near` is the human player (positive z, closest
/// to the camera); `far` is the computer opponent (negative z).
public enum Side: String, Codable, CaseIterable {
    case near
    case far

    public var opponent: Side { self == .near ? .far : .near }

    /// Sign of z on this side of the net.
    public var zSign: Double { self == .near ? 1 : -1 }

    /// Direction (sign of z velocity) in which this side hits the ball.
    public var hitDirection: Double { -zSign }

    public static func of(z: Double) -> Side { z >= 0 ? .near : .far }
}

/// Regulation-inspired table geometry (ITTF dimensions).
public struct TableGeometry: Codable, Equatable {
    public var length: Double = 2.74
    public var width: Double = 1.525
    public var surfaceHeight: Double = 0.76
    public var topThickness: Double = 0.03
    public var netHeight: Double = 0.1525
    /// Net extends this far beyond each sideline (to the net posts).
    public var netOverhang: Double = 0.1525

    public init() {}

    public var halfLength: Double { length / 2 }
    public var halfWidth: Double { width / 2 }
    public var netTop: Double { surfaceHeight + netHeight }
    public var netHalfSpan: Double { halfWidth + netOverhang }

    /// True when (x, z) lies on the playing surface.
    public func contains(x: Double, z: Double, margin: Double = 0) -> Bool {
        abs(x) <= halfWidth + margin && abs(z) <= halfLength + margin
    }
}

/// Physical properties of the ball. Identical for every cosmetic skin.
public struct BallProperties: Codable, Equatable {
    /// 40 mm ball.
    public var radius: Double = 0.020
    /// 2.7 g.
    public var mass: Double = 0.0027
    /// Thin-shell sphere: I = 2/3 m r^2.
    public var inertiaFactor: Double = 2.0 / 3.0

    public init() {}

    public var inertia: Double { inertiaFactor * mass * radius * radius }
}

/// Aerodynamics. Values are *gameplay tuned* starting from real-world
/// estimates; they are expected to be adjusted through play testing.
public struct AeroParameters: Codable, Equatable {
    public var gravity = Vec3(0, -9.81, 0)
    /// Drag acceleration = -dragCoefficient * |v| * v   (1/m).
    /// Real ball ≈ 0.5 * rho * Cd * A / m ≈ 0.14.
    public var dragCoefficient: Double = 0.14
    /// Magnus acceleration = magnusCoefficient * (omega × v).
    /// Real ball ≈ 0.003–0.004; boosted slightly so spin reads clearly on a phone.
    public var magnusCoefficient: Double = 0.0048
    /// Exponential spin decay rate in flight (1/s).
    public var spinDecay: Double = 0.12

    public init() {}
}

/// Contact parameters for one kind of surface.
public struct ContactMaterial: Codable, Equatable {
    /// Normal coefficient of restitution.
    public var restitution: Double
    /// Coulomb friction coefficient (caps the tangential impulse).
    public var friction: Double
    /// Tangential "springiness": 0 = contact point ends at rest relative to
    /// the surface (rolling); > 0 = contact velocity partially reverses
    /// (grippy elastic rubber produces extra spin).
    public var tangentialRestitution: Double

    public init(restitution: Double, friction: Double, tangentialRestitution: Double) {
        self.restitution = restitution
        self.friction = friction
        self.tangentialRestitution = tangentialRestitution
    }

    /// Table top. Friction is a little above lab measurements so that the
    /// spin-dependent bounce (kick / check) reads clearly.
    public static let table = ContactMaterial(restitution: 0.88, friction: 0.45, tangentialRestitution: 0.0)
    /// Inverted rubber on a blade.
    public static let paddle = ContactMaterial(restitution: 0.72, friction: 0.75, tangentialRestitution: 0.2)
    /// Soft net mesh: absorbs most of the energy.
    public static let net = ContactMaterial(restitution: 0.15, friction: 0.30, tangentialRestitution: 0.0)
    /// Arena floor.
    public static let floor = ContactMaterial(restitution: 0.70, friction: 0.40, tangentialRestitution: 0.0)
}

/// All tunable physics parameters in one serialisable bundle.
public struct PhysicsConfig: Codable, Equatable {
    public var table = TableGeometry()
    public var ball = BallProperties()
    public var aero = AeroParameters()
    public var tableMaterial = ContactMaterial.table
    public var paddleMaterial = ContactMaterial.paddle
    public var netMaterial = ContactMaterial.net
    public var floorMaterial = ContactMaterial.floor

    /// Fixed simulation timestep, independent of rendering frame rate.
    public var fixedTimestep: Double = 1.0 / 240.0
    /// Maximum distance the ball may travel (relative to any moving surface)
    /// during one collision sub-step. Smaller than the ball radius, which
    /// makes collision checks swept / tunnelling-proof.
    public var maxSubstepTravel: Double = 0.008
    /// Blade radius (a disc approximation of the paddle head).
    public var paddleRadius: Double = 0.078
    public var paddleHalfThickness: Double = 0.008
    /// Sweet-spot falloff: restitution scales by 1 - k * (d/R)^2.
    public var paddleSweetSpotFalloff: Double = 0.25
    /// Minimum time between two contacts of the same paddle.
    public var paddleContactCooldown: Double = 0.12

    public init() {}
}
