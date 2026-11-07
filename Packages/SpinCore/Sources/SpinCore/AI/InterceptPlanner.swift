import Foundation

/// Predicts where and when a side can strike an incoming ball, using the full
/// physics (spin included) via `TrajectoryPredictor`.
public enum InterceptPlanner {

    public struct Intercept: Equatable {
        /// Seconds from now.
        public var timeFromNow: Double
        public var point: Vec3
        /// Predicted ball state at the intercept.
        public var ball: BallState
    }

    /// - Parameters:
    ///   - preferredDepth: |z| at which the side would like to strike.
    ///   - minHeight: if the ball would drop below this before reaching the
    ///     preferred depth, strike it at its apex instead (short balls).
    public static func intercept(ball: BallState, side: Side, config: PhysicsConfig,
                                 preferredDepth: Double, minHeight: Double = 0.84, maxHeight: Double = 1.36,
                                 maxDepth: Double = 2.3,
                                 alreadyBounced: Bool = false,
                                 horizon: Double = 1.8, step: Double = 1.0 / 120.0) -> Intercept? {
        let pred = TrajectoryPredictor.predict(from: ball, config: config, duration: horizon, step: step,
                                               stop: .thirdTableOrFloor)
        let landings = pred.events.filter { $0.kind == .tableBounce || $0.kind == .floorHit }
        let tBounce: Double
        let second: PhysicsEvent?
        if alreadyBounced {
            // Already bounced on our half: strike before it lands again.
            guard Side.of(z: ball.position.z) == side else { return nil }
            tBounce = 0
            second = landings.first
        } else {
            // The ball must bounce on our half (possibly after the server's own
            // bounce on a serve) before anything else; otherwise it is going out.
            guard let idx = landings.firstIndex(where: { $0.kind == .tableBounce && $0.side == side }),
                  idx <= 1,
                  !landings[..<idx].contains(where: { $0.kind == .floorHit }) else { return nil }
            tBounce = landings[idx].time
            second = landings.dropFirst(idx + 1).first
        }
        var apex: TrajectoryPredictor.Sample?
        for s in pred.samples where s.time > tBounce + 1e-6 {
            if let second = second, s.time >= second.time { break }
            let p = s.ball.position
            if apex == nil || (p.y > apex!.ball.position.y && p.y <= maxHeight) { apex = s }
            if abs(p.z) > maxDepth { break }
            if abs(p.z) >= preferredDepth, p.y >= minHeight * 0.9, p.y <= maxHeight {
                return Intercept(timeFromNow: s.time, point: p, ball: s.ball)
            }
            if s.ball.velocity.y < 0, p.y < minHeight, let a = apex {
                return Intercept(timeFromNow: a.time, point: a.ball.position, ball: a.ball)
            }
        }
        if let a = apex { return Intercept(timeFromNow: a.time, point: a.ball.position, ball: a.ball) }
        return nil
    }

    /// For a tossed serve: when the falling ball reaches `contactHeight`.
    public static func tossIntercept(ball: BallState, config: PhysicsConfig, contactHeight: Double,
                                     step: Double = 1.0 / 240.0) -> Intercept? {
        let pred = TrajectoryPredictor.predict(from: ball, config: config, duration: 1.2, step: step,
                                               stop: .firstTableOrFloor)
        for s in pred.samples where s.ball.velocity.y < 0 && s.ball.position.y <= contactHeight {
            return Intercept(timeFromNow: s.time, point: s.ball.position, ball: s.ball)
        }
        return nil
    }
}
