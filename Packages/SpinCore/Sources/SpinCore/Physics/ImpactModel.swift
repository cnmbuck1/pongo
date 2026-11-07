import Foundation

/// Rigid-body impulse model for a spinning ball hitting a (possibly moving)
/// surface. Used for the table, net, floor and paddle alike, so every bounce
/// responds to the ball's current spin through the same physics.
///
/// Model:
/// * Normal impulse from the coefficient of restitution.
/// * Tangential (friction) impulse acts on the *contact point* velocity,
///   which includes the ball's spin (`omega × r_contact`). It is the impulse
///   that would bring the contact point to rest (or partially reverse it for
///   elastic rubber), capped by Coulomb friction (`mu * J_normal`).
/// * The tangential impulse changes both linear and angular velocity.
///
/// This produces, without any scripting:
/// * topspin balls keeping or gaining forward speed after a table bounce,
/// * backspin balls checking up or even kicking backward,
/// * paddle brushing motion converting into spin.
public enum ImpactModel {

    public struct Result: Equatable {
        /// Speed of approach along the contact normal (m/s, positive).
        public var normalSpeed: Double
        /// Magnitude of the tangential impulse divided by mass (m/s).
        public var tangentialDeltaV: Double
        /// True if friction was saturated (the contact slid).
        public var sliding: Bool
    }

    /// Resolves an impact. `normal` points from the surface toward the ball.
    /// `surfaceVelocity` is the velocity of the surface at the contact point.
    /// Returns nil (and leaves the ball unchanged) if the ball is separating.
    @discardableResult
    public static func resolve(ball: inout BallState,
                               normal: Vec3,
                               surfaceVelocity: Vec3,
                               material: ContactMaterial,
                               restitutionScale: Double = 1,
                               properties: BallProperties) -> Result? {
        let n = normal.normalized
        let vRel = ball.velocity - surfaceVelocity
        let vn = vRel.dot(n)
        guard vn < 0 else { return nil }

        let m = properties.mass
        let r = properties.radius
        let inertia = properties.inertia
        let e = material.restitution * restitutionScale

        let vNormal = n * vn
        let vTangent = vRel - vNormal
        // Vector from ball centre to the contact point.
        let rc = n * -r
        // Velocity of the contact point relative to the surface (tangential,
        // because omega × rc is perpendicular to n).
        let u = vTangent + ball.spin.cross(rc)
        let uMag = u.length

        let jn = m * (1 + e) * (-vn)
        var jt = Vec3.zero
        var sliding = false
        if uMag > 1e-9 {
            // Impulse per unit contact-velocity change: 1/m + r^2/I.
            let effective = 1.0 / m + r * r / inertia
            let needed = (1 + material.tangentialRestitution) * uMag / effective
            let cap = material.friction * jn
            let mag: Double
            if needed > cap { mag = cap; sliding = true } else { mag = needed }
            jt = u.normalized * -mag
        }

        let newRel = vTangent + jt / m + n * (-e * vn)
        ball.velocity = surfaceVelocity + newRel
        ball.spin += rc.cross(jt) / inertia
        return Result(normalSpeed: -vn, tangentialDeltaV: jt.length / m, sliding: sliding)
    }
}
