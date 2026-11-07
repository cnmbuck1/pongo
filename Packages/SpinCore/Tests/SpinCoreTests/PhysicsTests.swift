import XCTest
@testable import SpinCore

final class PhysicsTests: XCTestCase {
    let config = PhysicsConfig()
    var table: TableGeometry { config.table }

    /// Flies a ball until its first table/floor contact and returns the prediction.
    func fly(_ ball: BallState, stop: TrajectoryPredictor.StopCondition = .firstTableOrFloor,
             duration: Double = 3) -> TrajectoryPredictor.Prediction {
        TrajectoryPredictor.predict(from: ball, config: config, duration: duration, stop: stop)
    }

    /// A standard drive from the near end toward the far end.
    func drive(spin: Vec3, speed: Double = 9, vy: Double = 1.3) -> BallState {
        BallState(position: Vec3(0, table.surfaceHeight + 0.25, table.halfLength + 0.1),
                  velocity: Vec3(0, vy, -speed), spin: spin)
    }

    // MARK: Spin direction / Magnus

    func testMagnusDirectionForTopspinIsDownward() {
        // Ball travelling toward the far side (-z) with topspin: for -z travel
        // the topspin axis is -x (Vec3.unitY × travel).
        let ball = BallState(position: .zero, velocity: Vec3(0, 0, -10), spin: Vec3(-150, 0, 0))
        var aero = config.aero
        aero.gravity = .zero
        aero.dragCoefficient = 0
        let a = BallPhysics.acceleration(ball, aero: aero)
        XCTAssertLessThan(a.y, -1, "topspin must push the ball down")
        XCTAssertGreaterThan(SpinReading(ball: ball).topspin, 100)
    }

    func testMagnusDirectionForBackspinIsUpward() {
        let ball = BallState(position: .zero, velocity: Vec3(0, 0, -10), spin: Vec3(150, 0, 0))
        var aero = config.aero
        aero.gravity = .zero
        aero.dragCoefficient = 0
        XCTAssertGreaterThan(BallPhysics.acceleration(ball, aero: aero).y, 1)
        XCTAssertLessThan(SpinReading(ball: ball).topspin, -100)
    }

    func testTopspinDipsAndBackspinFloatsComparedToFlat() {
        let flat = fly(drive(spin: .zero)).firstBounce!
        let top = fly(drive(spin: Vec3(-160, 0, 0))).firstBounce!
        let back = fly(drive(spin: Vec3(160, 0, 0))).firstBounce
        // Topspin lands shorter (closer to the net, i.e. larger z) than flat.
        XCTAssertGreaterThan(top.point.z, flat.point.z + 0.15, "topspin should dip")
        // Backspin carries further (or flies long off the table).
        if let back = back, back.kind == .tableBounce {
            XCTAssertLessThan(back.point.z, flat.point.z - 0.1, "backspin should float")
        }
    }

    func testSidespinCurvesLaterally() {
        let left = fly(drive(spin: Vec3(0, 140, 0))).firstBounce!
        let right = fly(drive(spin: Vec3(0, -140, 0))).firstBounce!
        let flat = fly(drive(spin: .zero)).firstBounce!
        XCTAssertEqual(flat.point.x, 0, accuracy: 1e-6)
        // omega_y > 0 with travel toward -z curves toward -x.
        XCTAssertLessThan(left.point.x, -0.08)
        XCTAssertGreaterThan(right.point.x, 0.08)
        XCTAssertGreaterThan(SpinReading(ball: drive(spin: Vec3(0, -140, 0))).sidespin, 0)
        XCTAssertLessThan(SpinReading(ball: drive(spin: Vec3(0, 140, 0))).sidespin, 0)
    }

    func testDragSlowsBall() {
        var b = BallState(position: Vec3(0, 5, 0), velocity: Vec3(0, 0, -12))
        let start = b.velocity.length
        for _ in 0..<60 { BallPhysics.integrate(&b, h: 1.0 / 240, aero: config.aero) }
        XCTAssertLessThan(abs(b.velocity.z), start * 0.97)
    }

    // MARK: Table bounce

    func bounce(vz: Double, vy: Double = -3, spinX: Double) -> BallState {
        var b = BallState(position: Vec3(0, table.surfaceHeight + config.ball.radius - 0.001, 0.6),
                          velocity: Vec3(0, vy, vz), spin: Vec3(spinX, 0, 0))
        var events: [PhysicsEvent] = []
        BallPhysics.collideStatic(&b, config: config, time: 0, events: &events)
        XCTAssertEqual(events.first?.kind, .tableBounce)
        return b
    }

    func testTableBounceReflectsVerticalVelocity() {
        let b = bounce(vz: 0, vy: -4, spinX: 0)
        XCTAssertEqual(b.velocity.y, 4 * config.tableMaterial.restitution, accuracy: 1e-9)
    }

    func testTopspinBounceKeepsMoreForwardSpeedThanBackspin() {
        // Ball moving toward the near player (+z): topspin axis is +x.
        let top = bounce(vz: 5, spinX: 150)
        let flat = bounce(vz: 5, spinX: 0)
        let back = bounce(vz: 5, spinX: -150)
        XCTAssertGreaterThan(top.velocity.z, flat.velocity.z + 0.3)
        XCTAssertGreaterThan(flat.velocity.z, back.velocity.z + 0.2)
    }

    func testSideSpinComponentKicksBounceSideways() {
        // Spin about the travel axis (the tilted part of a sidespin stroke)
        // makes the ball kick sideways off the table; pure vertical-axis
        // spin curves the flight instead (see testSidespinCurvesLaterally).
        var b = BallState(position: Vec3(0, table.surfaceHeight + config.ball.radius - 0.001, 0.6),
                          velocity: Vec3(0, -3, 5), spin: Vec3(0, 0, 150))
        var events: [PhysicsEvent] = []
        BallPhysics.collideStatic(&b, config: config, time: 0, events: &events)
        XCTAssertEqual(events.first?.kind, .tableBounce)
        XCTAssertGreaterThan(abs(b.velocity.x), 0.3)
        var m = BallState(position: Vec3(0, table.surfaceHeight + config.ball.radius - 0.001, 0.6),
                          velocity: Vec3(0, -3, 5), spin: Vec3(0, 0, -150))
        BallPhysics.collideStatic(&m, config: config, time: 0, events: &events)
        XCTAssertEqual(b.velocity.x, -m.velocity.x, accuracy: 1e-9, "opposite spin, opposite kick")
    }

    func testHeavyBackspinOnSlowBallKicksBackward() {
        let b = bounce(vz: 1.0, vy: -3, spinX: -260)
        XCTAssertLessThan(b.velocity.z, 0, "strong backspin should kick the ball back toward the net")
    }

    func testTopspinCanAccelerateBallOffTheTable() {
        let b = bounce(vz: 2.0, vy: -3, spinX: 250)
        XCTAssertGreaterThan(b.velocity.z, 2.0)
    }

    func testBallMissingTableReachesFloor() {
        let wide = BallState(position: Vec3(1.2, 1.0, 0.5), velocity: Vec3(0, 0, 1))
        let p = fly(wide)
        XCTAssertEqual(p.events.first?.kind, .floorHit)
    }

    func testEdgeBallDeflects() {
        // Ball dropping onto the far end edge from outside.
        var b = BallState(position: Vec3(0, table.surfaceHeight + 0.005, -table.halfLength - 0.012),
                          velocity: Vec3(0, -2, -0.5))
        var events: [PhysicsEvent] = []
        BallPhysics.collideStatic(&b, config: config, time: 0, events: &events)
        XCTAssertFalse(events.isEmpty)
        XCTAssertLessThan(b.velocity.z, -0.4, "edge contact should push the ball outward")
    }

    // MARK: Net

    func testLowBallIsStoppedByNet() {
        let low = BallState(position: Vec3(0, table.surfaceHeight + 0.08, 0.6), velocity: Vec3(0, 0.5, -6))
        let p = fly(low, stop: .duration, duration: 1.0)
        XCTAssertTrue(p.events.contains { $0.kind == .netTouch })
        // The ball must never end up on the far half past the net.
        let crossed = p.samples.contains { $0.ball.position.z < -0.05 }
        XCTAssertFalse(crossed, "ball passed through the net")
    }

    func testHighBallClearsNet() {
        let p = fly(drive(spin: .zero, vy: 1.0))
        XCTAssertFalse(p.events.contains { $0.kind == .netTouch })
        XCTAssertEqual(p.firstBounce?.side, .far)
    }

    func testNetCordBallLosesEnergyAndCanDribbleOver() {
        // Ball skimming the tape.
        let b = BallState(position: Vec3(0, table.netTop + 0.012, 0.3), velocity: Vec3(0, 0.2, -4))
        let p = fly(b, stop: .duration, duration: 1.0)
        let touch = p.events.first { $0.kind == .netTouch }
        XCTAssertNotNil(touch)
        XCTAssertLessThan(touch!.ballAfter.velocity.length, 4)
    }

    func testFastBallDoesNotTunnelThroughNet() {
        let b = BallState(position: Vec3(0.2, table.surfaceHeight + 0.09, 0.4), velocity: Vec3(0, 0, -35))
        let p = fly(b, stop: .duration, duration: 0.4)
        XCTAssertTrue(p.events.contains { $0.kind == .netTouch })
        XCTAssertFalse(p.samples.contains { $0.ball.position.z < -0.03 })
    }

    // MARK: Paddle

    func testPaddleContactIsNotSimpleReflection() {
        // Incoming ball toward the near player, paddle brushing upward.
        let incoming = BallState(position: Vec3(0, 1.0, 1.6), velocity: Vec3(0, -0.5, 6))
        let n = ShotSolver.faceNormal(for: .near, pitch: -0.2, yaw: 0)
        let still = PaddleCollision.strike(ball: incoming, paddleVelocity: .zero, faceNormal: n, config: config)
        let brushed = PaddleCollision.strike(ball: incoming, paddleVelocity: Vec3(0, 3, -4), faceNormal: n, config: config)
        XCTAssertLessThan(still.velocity.z, 0)
        XCTAssertLessThan(brushed.velocity.z, still.velocity.z, "a forward swing must add speed")
        let reading = SpinReading(ball: brushed)
        XCTAssertGreaterThan(reading.topspin, 60, "an upward brush must create topspin")
    }

    func testDownwardBrushCreatesBackspin() {
        let incoming = BallState(position: Vec3(0, 1.0, 1.6), velocity: Vec3(0, -0.5, 4))
        let n = ShotSolver.faceNormal(for: .near, pitch: 0.6, yaw: 0)
        let out = PaddleCollision.strike(ball: incoming, paddleVelocity: Vec3(0, -2.5, -2), faceNormal: n, config: config)
        XCTAssertLessThan(SpinReading(ball: out).topspin, -60)
    }

    func testLateralBrushCreatesSidespin() {
        let incoming = BallState(position: Vec3(0, 1.0, 1.6), velocity: Vec3(0, -0.5, 4))
        let n = ShotSolver.faceNormal(for: .near, pitch: 0, yaw: 0)
        let out = PaddleCollision.strike(ball: incoming, paddleVelocity: Vec3(3, 0, -3), faceNormal: n, config: config)
        XCTAssertGreaterThan(abs(out.spin.y), 60)
    }

    func testOffCentreHitIsWeaker() {
        let paddle = PaddleState(position: Vec3(0, 1, 1.6), velocity: .zero, normal: -.unitZ, hitRadius: 0.1)
        var centre = BallState(position: Vec3(0, 1, 1.578), velocity: Vec3(0, 0, 5))
        var edge = BallState(position: Vec3(0.07, 1, 1.578), velocity: Vec3(0, 0, 5))
        let lc = PaddleCollision.detect(ball: centre, paddle: paddle, config: config)!
        let le = PaddleCollision.detect(ball: edge, paddle: paddle, config: config)!
        PaddleCollision.resolve(ball: &centre, paddle: paddle, faceNormal: paddle.normal, lateralOffset: lc, config: config)
        PaddleCollision.resolve(ball: &edge, paddle: paddle, faceNormal: paddle.normal, lateralOffset: le, config: config)
        XCTAssertGreaterThan(abs(centre.velocity.z), abs(edge.velocity.z))
    }

    func testFastSwingDoesNotTunnelThroughBall() {
        // Paddle swings 10 m/s through a slow ball within a single tick.
        var world = PhysicsWorld(config: config)
        world.hold(at: Vec3(0, 1.0, 1.5))
        world.release(velocity: Vec3(0, 0, 0.5))
        var pos = Vec3(0, 1.0, 1.62)
        var hit = false
        for _ in 0..<30 {
            let prev = pos
            pos = pos + Vec3(0, 0, -10) * config.fixedTimestep
            let p = PaddleState(position: pos, velocity: (pos - prev) / config.fixedTimestep, normal: -.unitZ, hitRadius: 0.078)
            let far = world.farPaddle
            let ev = world.step(near: p, far: far) { _, _, p in p.normal }
            if ev.contains(where: { $0.kind == .paddleHit }) { hit = true; break }
        }
        XCTAssertTrue(hit)
        XCTAssertLessThan(world.ball.velocity.z, -5)
    }

    // MARK: Timestep independence

    func testResultIndependentOfFrameRateBatching() {
        // The world advances in fixed ticks; batching ticks per frame differently
        // (30 vs 60 vs 120 fps) must give identical results.
        func run(framesPerSecond: Int) -> BallState {
            var sim = FixedStepClock(step: config.fixedTimestep)
            var world = PhysicsWorld(config: config)
            world.hold(at: Vec3(0, 1.0, 1.4))
            world.release(velocity: Vec3(0.3, 1.5, -7), spin: Vec3(-120, 30, 0))
            let near = world.nearPaddle, far = world.farPaddle
            let frame = 1.0 / Double(framesPerSecond)
            for _ in 0..<(framesPerSecond) {
                let n = sim.advance(by: frame)
                for _ in 0..<n { _ = world.step(near: near, far: far) { _, _, p in p.normal } }
            }
            return world.ball
        }
        let a = run(framesPerSecond: 30), b = run(framesPerSecond: 60), c = run(framesPerSecond: 120)
        XCTAssertEqual(a, b)
        XCTAssertEqual(b, c)
    }
}
