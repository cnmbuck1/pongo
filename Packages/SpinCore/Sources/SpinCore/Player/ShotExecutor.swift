import Foundation

/// Arcade-simulation shot execution for the auto paddle.
///
/// At the (single, real) paddle contact, the selected shot decides the
/// outgoing ball directly: a landing target, a pace and a spin. The launch
/// velocity is then solved with the same flight physics as the live ball
/// (drag, Magnus, net), so the ball really flies, curves and kicks the way
/// its spin says. This keeps every shot type distinct and predictable, which
/// pure blade physics did not (a "standard" and a "backspin" stroke came out
/// almost the same).
public enum ShotExecutor {

    /// What a shot should do.
    public struct Intent: Equatable {
        /// Landing point on the opponent's half.
        public var target: Vec3
        public var speed: Double
        /// rad/s; + topspin, − backspin.
        public var topspin: Double
        /// rad/s about the vertical axis; + curves toward +x, − toward −x.
        public var sidespin: Double
        public init(target: Vec3, speed: Double, topspin: Double, sidespin: Double) {
            self.target = target; self.speed = speed; self.topspin = topspin; self.sidespin = sidespin
        }
    }

    /// Spin vector for a ball travelling with `velocity`.
    public static func spinVector(velocity v: Vec3, topspin: Double, sidespin: Double) -> Vec3 {
        let h = Vec3(v.x, 0, v.z)
        guard h.length > 1e-6 else { return .zero }
        let topAxis = Vec3.unitY.cross(h.normalized)
        // Vertical spin w.y curves the ball along x by w.y * v.z (Magnus).
        let wy = v.z >= 0 ? sidespin : -sidespin
        return topAxis * topspin + Vec3(0, wy, 0)
    }

    private enum Landing { case short, long, onTarget(Vec3) }

    /// Where the launched ball first lands relative to the target depth.
    private static func land(from p: Vec3, velocity v: Vec3, intent: Intent, hitter: Side,
                             config: PhysicsConfig) -> (Landing, Vec3?) {
        let ball = BallState(position: p, velocity: v, spin: spinVector(velocity: v, topspin: intent.topspin,
                                                                         sidespin: intent.sidespin))
        let pred = TrajectoryPredictor.predict(from: ball, config: config, duration: 2.0, step: 1.0 / 240.0,
                                               stop: .firstTableOrFloor, recordSamples: false)
        let opp = hitter.opponent
        if pred.events.contains(where: { $0.kind == .netTouch }) { return (.short, nil) }
        guard let first = pred.events.first(where: { $0.kind == .tableBounce || $0.kind == .floorHit }) else {
            return (.long, nil)
        }
        let pt = first.point
        if first.kind == .tableBounce && first.side == hitter { return (.short, pt) }
        let depth = pt.z * opp.zSign          // distance past the net on the far side
        if first.kind == .floorHit {
            // Floor short of the table end (e.g. off the side) counts by depth.
            return (depth < intent.target.z * opp.zSign ? .short : .long, pt)
        }
        return (.onTarget(pt), pt)
    }

    /// Solves the launch velocity for `intent` from `position`. Returns the
    /// outgoing ball (position unchanged). Falls back to slower pace when the
    /// requested pace cannot land.
    public static func execute(from position: Vec3, intent: Intent, hitter: Side,
                               config: PhysicsConfig) -> BallState {
        let opp = hitter.opponent
        let targetDepth = intent.target.z * opp.zSign
        var speed = intent.speed
        var aimX = intent.target.x
        var best: (v: Vec3, err: Double)?
        for _ in 0..<5 {                         // pace back-off
            for _ in 0..<3 {                     // lateral correction for curve
                var dir = Vec3(aimX - position.x, 0, intent.target.z - position.z)
                if dir.length < 1e-6 { dir = Vec3(0, 0, opp.zSign) }
                dir = dir.normalized
                func velocity(_ elev: Double) -> Vec3 { (dir * cos(elev) + Vec3.unitY * sin(elev)) * speed }
                var lo = -0.5, hi = 0.75
                var found: (v: Vec3, pt: Vec3)?
                var lastShortClear: (v: Vec3, pt: Vec3)?
                for _ in 0..<16 {
                    let mid = (lo + hi) / 2
                    let v = velocity(mid)
                    let (res, pt) = land(from: position, velocity: v, intent: intent, hitter: hitter, config: config)
                    switch res {
                    case .short:
                        lo = mid
                    case .long:
                        hi = mid
                    case let .onTarget(p):
                        let d = p.z * opp.zSign
                        found = (v, p)
                        if d < targetDepth { lo = mid; lastShortClear = (v, p) } else { hi = mid }
                    }
                    _ = pt
                }
                guard let f = found ?? lastShortClear else { break }
                let err = abs(f.pt.x - intent.target.x) + abs(f.pt.z * opp.zSign - targetDepth)
                if best == nil || err < best!.err { best = (f.v, err) }
                if abs(f.pt.x - intent.target.x) < 0.02 { break }
                aimX += intent.target.x - f.pt.x
            }
            if let b = best, b.err < 0.25 { break }
            speed *= 0.85
            aimX = intent.target.x
        }
        let v = best?.v ?? (Vec3(0, 0.35, opp.zSign).normalized * 5)
        return BallState(position: position, velocity: v,
                         spin: spinVector(velocity: v, topspin: intent.topspin, sidespin: intent.sidespin))
    }
}
