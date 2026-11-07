import Foundation

/// Finds a paddle face angle that sends the ball toward a target, given the
/// paddle's actual velocity at impact.
///
/// This is how both the AI and the player's control assistance "aim": the
/// shot outcome still comes entirely from the paddle collision physics; the
/// solver only chooses the blade angle, the same thing a real player adjusts.
public enum ShotSolver {

    public struct Goal: Equatable {
        public var hitter: Side
        public var isServe: Bool
        /// Desired landing point on the opponent's half (x and z used).
        public var target: Vec3

        public init(hitter: Side, isServe: Bool, target: Vec3) {
            self.hitter = hitter; self.isServe = isServe; self.target = target
        }
    }

    public struct Evaluation: Equatable {
        /// Lower is better. < ~1 means a legal landing on the correct half.
        public var score: Double
        public var landsLegally: Bool
        public var landing: Vec3?
    }

    /// Face normal facing the opponent, opened (`pitch` > 0 tilts the face
    /// upward) and turned toward +x by `yaw` (radians).
    public static func faceNormal(for side: Side, pitch: Double, yaw: Double) -> Vec3 {
        let dir = side.hitDirection
        let base = Vec3(0, 0, dir)
        let pitched = base.rotated(about: Vec3(-dir, 0, 0), by: pitch)
        return pitched.rotated(about: Vec3(0, dir, 0), by: yaw).normalized
    }

    /// Inverse of `faceNormal(for:pitch:yaw:)`.
    public static func angles(of normal: Vec3, side: Side) -> (pitch: Double, yaw: Double) {
        let n = normal.normalized
        let pitch = asin(clamp(n.y, -1, 1))
        let yaw = atan2(n.x, n.z * side.hitDirection)
        return (pitch, yaw)
    }

    /// Scores the flight of a ball that has just been struck.
    public static func evaluate(after ball: BallState, goal: Goal, config: PhysicsConfig,
                                step: Double = 1.0 / 120.0) -> Evaluation {
        let table = config.table
        let pred = TrajectoryPredictor.predict(from: ball, config: config, duration: 1.8, step: step,
                                               stop: goal.isServe ? .secondTableOrFloor : .firstTableOrFloor,
                                               recordSamples: true)
        let hitterSide = goal.hitter
        let receiver = hitterSide.opponent
        let netTouched = pred.events.contains { $0.kind == .netTouch }
        let landingEvents = pred.events.filter { $0.kind == .tableBounce || $0.kind == .floorHit }
        let apex = pred.samples.map { $0.ball.position.y }.max() ?? ball.position.y
        // Prefer arcs that clear the net with a safety margin, so small
        // execution errors don't put the ball into the net.
        var netClearance = 1.0
        for (a, b) in zip(pred.samples, pred.samples.dropFirst()) where a.ball.position.z * b.ball.position.z <= 0 {
            netClearance = min(a.ball.position.y, b.ball.position.y) - table.netTop - config.ball.radius
            break
        }
        let wantedMargin = goal.isServe ? 0.06 : 0.07
        let loftPenalty = 0.4 * max(0, apex - (table.netTop + 0.55))
            + 6 * max(0, wantedMargin - netClearance)

        func dist(_ p: Vec3) -> Double {
            let dx = p.x - goal.target.x, dz = p.z - goal.target.z
            return (dx * dx + dz * dz).squareRoot()
        }
        func edgePenalty(_ p: Vec3) -> Double {
            let mx = table.halfWidth - abs(p.x)
            let mz = table.halfLength - abs(p.z)
            let m = min(mx, mz)
            return m < 0.06 ? (0.06 - m) * 4 : 0
        }
        // Where the ball dropped through table height (for misses).
        func missPoint() -> Vec3 {
            for s in pred.samples.dropFirst() where s.ball.velocity.y < 0 && s.ball.position.y <= table.surfaceHeight + config.ball.radius {
                return s.ball.position
            }
            return pred.samples.last?.ball.position ?? ball.position
        }

        if goal.isServe {
            guard let first = landingEvents.first else {
                return Evaluation(score: 6 + dist(missPoint()), landsLegally: false, landing: nil)
            }
            if first.kind == .tableBounce, first.side == hitterSide {
                if landingEvents.count >= 2 {
                    let second = landingEvents[1]
                    if second.kind == .tableBounce, second.side == receiver {
                        return Evaluation(score: dist(second.point) + edgePenalty(second.point) + loftPenalty + (netTouched ? 1.5 : 0),
                                          landsLegally: !netTouched, landing: second.point)
                    }
                    return Evaluation(score: 2.5 + dist(second.point), landsLegally: false, landing: nil)
                }
                return Evaluation(score: 3 + dist(missPoint()), landsLegally: false, landing: nil)
            }
            // Went straight over without bouncing on the server's half.
            return Evaluation(score: 4 + abs(first.point.z - hitterSide.zSign * table.halfLength * 0.5),
                              landsLegally: false, landing: nil)
        }

        guard let first = landingEvents.first else {
            return Evaluation(score: 5 + dist(missPoint()), landsLegally: false, landing: nil)
        }
        if first.kind == .tableBounce, first.side == receiver {
            return Evaluation(score: dist(first.point) + edgePenalty(first.point) + loftPenalty + (netTouched ? 0.4 : 0),
                              landsLegally: true, landing: first.point)
        }
        if first.kind == .tableBounce {
            // Landed on own half (or fell back off the net).
            return Evaluation(score: 3 + dist(first.point), landsLegally: false, landing: nil)
        }
        return Evaluation(score: 2 + dist(missPoint()), landsLegally: false, landing: nil)
    }

    public struct Solution {
        public var normal: Vec3
        public var evaluation: Evaluation
    }

    /// Searches blade angles (coarse grid then local refinement).
    public static func solve(incoming: BallState, paddleVelocity: Vec3, goal: Goal,
                             config: PhysicsConfig,
                             contactOffset: Vec3 = .zero,
                             pitchRange: ClosedRange<Double> = (-75.0 * .pi / 180)...(65.0 * .pi / 180),
                             yawRange: ClosedRange<Double> = (-35.0 * .pi / 180)...(35.0 * .pi / 180)) -> Solution {
        var best: (pitch: Double, yaw: Double, eval: Evaluation)?

        func consider(_ pitch: Double, _ yaw: Double) {
            let n = faceNormal(for: goal.hitter, pitch: pitch, yaw: yaw)
            let out = PaddleCollision.strike(ball: incoming, paddleVelocity: paddleVelocity, faceNormal: n, config: config,
                                             lateralOffset: contactOffset)
            let e = evaluate(after: out, goal: goal, config: config)
            if best == nil || e.score < best!.eval.score { best = (pitch, yaw, e) }
        }

        let deg = Double.pi / 180
        var p = pitchRange.lowerBound
        while p <= pitchRange.upperBound + 1e-9 {
            var y = yawRange.lowerBound
            while y <= yawRange.upperBound + 1e-9 {
                consider(p, y)
                y += 7 * deg
            }
            p += 5 * deg
        }
        // Local refinement.
        if let b = best {
            for dp in stride(from: -4.0, through: 4.0, by: 1.0) {
                for dy in stride(from: -6.0, through: 6.0, by: 1.5) {
                    consider(clamp(b.pitch + dp * deg, pitchRange.lowerBound, pitchRange.upperBound),
                             clamp(b.yaw + dy * deg, yawRange.lowerBound, yawRange.upperBound))
                }
            }
        }
        let b = best!
        return Solution(normal: faceNormal(for: goal.hitter, pitch: b.pitch, yaw: b.yaw), evaluation: b.eval)
    }
}
