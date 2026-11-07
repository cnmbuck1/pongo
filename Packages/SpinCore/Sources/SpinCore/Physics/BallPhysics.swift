import Foundation

/// A collision produced by the physics simulation.
public struct PhysicsEvent: Codable, Equatable {
    public enum Kind: String, Codable {
        case paddleHit
        case tableBounce
        case netTouch
        case floorHit
    }

    public var kind: Kind
    /// For `paddleHit`: who hit it. For `tableBounce`: which half was hit.
    public var side: Side?
    public var point: Vec3
    /// Approach speed along the contact normal (m/s).
    public var impactSpeed: Double
    /// Ball state immediately after the contact.
    public var ballAfter: BallState
    /// Simulation time of the contact.
    public var time: Double

    public init(kind: Kind, side: Side?, point: Vec3, impactSpeed: Double, ballAfter: BallState, time: Double) {
        self.kind = kind; self.side = side; self.point = point
        self.impactSpeed = impactSpeed; self.ballAfter = ballAfter; self.time = time
    }
}

/// Free-flight dynamics and static (table / net / floor) collisions.
public enum BallPhysics {

    /// Aerodynamic + gravitational acceleration for a ball state.
    @inlinable
    public static func acceleration(_ ball: BallState, aero: AeroParameters) -> Vec3 {
        let v = ball.velocity
        let drag = v * (-aero.dragCoefficient * v.length)
        let magnus = ball.spin.cross(v) * aero.magnusCoefficient
        return aero.gravity + drag + magnus
    }

    /// Integrates free flight over `h` seconds (semi-implicit Euler; `h` is a
    /// small sub-step so this is accurate and stable).
    @inlinable
    public static func integrate(_ ball: inout BallState, h: Double, aero: AeroParameters) {
        let a = acceleration(ball, aero: aero)
        ball.velocity += a * h
        ball.position += ball.velocity * h
        ball.spin *= exp(-aero.spinDecay * h)
    }

    /// Number of sub-steps needed so that the ball moves at most
    /// `maxTravel` relative to any surface during one sub-step.
    @inlinable
    public static func substepCount(relativeSpeed: Double, dt: Double, maxTravel: Double) -> Int {
        let n = Int((relativeSpeed * dt / maxTravel).rounded(.up))
        return clamp(n, 1, 96)
    }

    // MARK: - Static collisions

    /// Sphere vs axis-aligned box. Handles flat faces, edges and corners
    /// (e.g. "edge balls" on the table or the net tape).
    /// Returns the contact normal and impact result if an impact was resolved.
    public static func collideBox(_ ball: inout BallState,
                                  min lo: Vec3, max hi: Vec3,
                                  material: ContactMaterial,
                                  properties: BallProperties) -> (normal: Vec3, point: Vec3, result: ImpactModel.Result)? {
        let r = properties.radius
        let c = ball.position
        let p = Vec3(clamp(c.x, lo.x, hi.x), clamp(c.y, lo.y, hi.y), clamp(c.z, lo.z, hi.z))
        let d = c - p
        let dist = d.length
        guard dist < r else { return nil }

        var n: Vec3
        if dist > 1e-9 {
            n = d / dist
            ball.position = p + n * r
        } else {
            // Centre inside the box (should not happen with swept sub-steps,
            // but be robust): exit through the nearest face.
            let faces: [(Double, Vec3)] = [
                (hi.y - c.y, .unitY), (c.y - lo.y, -.unitY),
                (hi.x - c.x, .unitX), (c.x - lo.x, -.unitX),
                (hi.z - c.z, .unitZ), (c.z - lo.z, -.unitZ)
            ]
            let best = faces.min { $0.0 < $1.0 }!
            n = best.1
            ball.position = c + n * (best.0 + r)
        }
        guard let result = ImpactModel.resolve(ball: &ball, normal: n, surfaceVelocity: .zero,
                                               material: material, properties: properties) else { return nil }
        return (n, ball.position - n * r, result)
    }

    /// Table top as a box (top face at the playing-surface height).
    public static func tableBox(_ t: TableGeometry) -> (Vec3, Vec3) {
        (Vec3(-t.halfWidth, t.surfaceHeight - t.topThickness, -t.halfLength),
         Vec3(t.halfWidth, t.surfaceHeight, t.halfLength))
    }

    /// Net as a thin vertical box spanning post to post.
    public static func netBox(_ t: TableGeometry) -> (Vec3, Vec3) {
        (Vec3(-t.netHalfSpan, t.surfaceHeight, -0.002),
         Vec3(t.netHalfSpan, t.netTop, 0.002))
    }

    /// Runs table, net and floor collisions for the current sub-step and
    /// appends any events.
    public static func collideStatic(_ ball: inout BallState,
                                     config: PhysicsConfig,
                                     time: Double,
                                     events: inout [PhysicsEvent]) {
        let props = config.ball
        let (tLo, tHi) = tableBox(config.table)
        if let hit = collideBox(&ball, min: tLo, max: tHi, material: config.tableMaterial, properties: props) {
            // Only a hit on the top surface counts as a bounce on a half; an
            // impact with the side of the table is effectively out.
            if hit.normal.y > 0.3 {
                events.append(PhysicsEvent(kind: .tableBounce, side: Side.of(z: hit.point.z), point: hit.point,
                                           impactSpeed: hit.result.normalSpeed, ballAfter: ball, time: time))
            } else {
                events.append(PhysicsEvent(kind: .floorHit, side: nil, point: hit.point,
                                           impactSpeed: hit.result.normalSpeed, ballAfter: ball, time: time))
            }
        }
        let (nLo, nHi) = netBox(config.table)
        if let hit = collideBox(&ball, min: nLo, max: nHi, material: config.netMaterial, properties: props) {
            events.append(PhysicsEvent(kind: .netTouch, side: nil, point: hit.point,
                                       impactSpeed: hit.result.normalSpeed, ballAfter: ball, time: time))
        }
        // Floor.
        if ball.position.y < props.radius && ball.velocity.y < 0 {
            ball.position.y = props.radius
            if let res = ImpactModel.resolve(ball: &ball, normal: .unitY, surfaceVelocity: .zero,
                                             material: config.floorMaterial, properties: props) {
                events.append(PhysicsEvent(kind: .floorHit, side: nil,
                                           point: Vec3(ball.position.x, 0, ball.position.z),
                                           impactSpeed: res.normalSpeed, ballAfter: ball, time: time))
            }
        }
    }

    /// Advances a free ball by `dt` using swept sub-steps, colliding only with
    /// static geometry. Used by trajectory prediction and by the world.
    public static func advanceFree(_ ball: inout BallState, dt: Double, config: PhysicsConfig,
                                   time: Double, events: inout [PhysicsEvent]) {
        let n = substepCount(relativeSpeed: ball.velocity.length, dt: dt, maxTravel: config.maxSubstepTravel)
        let h = dt / Double(n)
        for i in 0..<n {
            integrate(&ball, h: h, aero: config.aero)
            collideStatic(&ball, config: config, time: time + h * Double(i + 1), events: &events)
        }
    }
}
