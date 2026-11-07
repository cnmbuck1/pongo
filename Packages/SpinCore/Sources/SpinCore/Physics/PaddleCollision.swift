import Foundation

/// Ball vs. paddle blade collision.
///
/// The blade is modelled as a one-sided disc (front face toward the
/// opponent). The outgoing ball state is computed from the incoming ball
/// velocity and spin, the face normal, the paddle velocity, the contact
/// position (sweet spot) and rubber friction / restitution — the ball's
/// direction is never simply reversed.
public enum PaddleCollision {

    /// Geometric test: is the ball touching the front face of the paddle and
    /// approaching it? Returns the in-plane offset from the blade centre.
    public static func detect(ball: BallState, paddle: PaddleState, config: PhysicsConfig) -> Vec3? {
        let r = config.ball.radius
        let h = config.paddleHalfThickness
        let n = paddle.normal
        let rel = ball.position - paddle.position
        let d = rel.dot(n)
        guard d < r + h, d > -(r + h) else { return nil }
        let lateral = rel - n * d
        guard lateral.length <= paddle.hitRadius else { return nil }
        let approach = (ball.velocity - paddle.velocity).dot(n)
        guard approach < 0 else { return nil }
        return lateral
    }

    /// Applies the paddle impact using `faceNormal` (which may differ slightly
    /// from the detection normal when a controller fine-tunes the face angle at
    /// the moment of impact). Returns the approach speed.
    @discardableResult
    public static func resolve(ball: inout BallState,
                               paddle: PaddleState,
                               faceNormal: Vec3,
                               lateralOffset: Vec3,
                               config: PhysicsConfig) -> ImpactModel.Result? {
        let n = faceNormal.normalized
        let r = config.ball.radius
        // De-penetrate: put the ball on the face.
        ball.position = paddle.position + lateralOffset + n * (r + config.paddleHalfThickness)
        let radius = max(config.paddleRadius, 1e-6)
        let offRatio = min(lateralOffset.length / radius, 1.25)
        let sweet = max(0.55, 1 - config.paddleSweetSpotFalloff * offRatio * offRatio)
        return ImpactModel.resolve(ball: &ball, normal: n, surfaceVelocity: paddle.velocity,
                                   material: config.paddleMaterial, restitutionScale: sweet,
                                   properties: config.ball)
    }

    /// Convenience used by prediction / shot solving: what would happen if the
    /// ball were struck right now with this face and paddle velocity.
    public static func strike(ball: BallState, paddleVelocity: Vec3, faceNormal: Vec3,
                              config: PhysicsConfig, lateralOffset: Vec3 = .zero) -> BallState {
        var b = ball
        let n = faceNormal.normalized
        // Ensure the ball is moving toward the face in the relative frame; if
        // not (e.g. ball nearly stationary on a toss) the paddle still pushes.
        let lateral = lateralOffset - n * lateralOffset.dot(n)
        let paddle = PaddleState(position: b.position - lateral - n * (config.ball.radius + config.paddleHalfThickness),
                                 velocity: paddleVelocity, normal: n, hitRadius: config.paddleRadius)
        PaddleCollision.resolve(ball: &b, paddle: paddle, faceNormal: n, lateralOffset: lateral, config: config)
        return b
    }
}
