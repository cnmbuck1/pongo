import SceneKit
import SpinCore

/// Owns the SceneKit scene and mirrors a `GameSimulation` into it every frame.
/// Rendering never feeds back into the simulation.
final class GameRenderer {

    enum CameraMode {
        /// Gameplay: fixed behind the player's paddle, slightly elevated.
        case gameplay
        /// Menu / attract mode: slow orbit around the table.
        case orbit
    }

    let scene: SCNScene
    let cameraNode = SCNNode()
    private let camera = SCNCamera()
    private let nearPaddle: PaddleNode
    private let farPaddle: PaddleNode
    private let ballNode: BallNode
    private let trail = SpinTrail()
    private let shadowBlob = SCNNode()
    private let spinArrow = SCNNode()
    private var bounceMarkers: [SCNNode] = []
    private var shownBounces: [Vec3] = []

    var cameraMode: CameraMode = .gameplay
    var trainingVisuals = false { didSet { spinArrow.isHidden = !trainingVisuals; trail.boost = trainingVisuals ? 1.6 : 1 } }

    private var shake: Float = 0
    private var fovKick: Float = 0
    private var orbitAngle: Float = 0
    private var shotPower: Double = 0
    private var followX: Float = 0
    private var followY: Float = 0
    private var playerPaddleX: Float = 0
    private var ballPosition = SIMD3<Float>(0, 1, 0)
    private var ballOnPlayerSide = false

    /// Gameplay camera parameters (Build 2). Everything about the view is
    /// here so it can be tuned without touching the camera code.
    struct CameraConfig {
        /// Camera height above the floor (m). The table top is at 0.76 m.
        var height: Float = 2.3
        /// Distance from the net to the camera along the table axis (m). The
        /// player's end of the table is at 1.37 m.
        var distance: Float = 2.2
        /// Downward pitch (degrees).
        var pitch: Float = 29.5
        /// Horizontal field of view (degrees).
        var fieldOfView: CGFloat = 64
        /// Fraction of the player's paddle x the camera slides with.
        var paddleFollow: Float = 0.3
        /// How much the camera leans toward wide or high balls on the
        /// player's side (0 = never).
        var ballTracking: Float = 0.12
        /// Time constant (s) for all camera movement.
        var smoothing: Double = 0.14
    }
    var cameraConfig = CameraConfig()
    static let paddleVisualScale = 1.8
    var motionEffects = true { didSet { trail.enabled = motionEffects || trainingVisuals } }

    static let baseFOV: CGFloat = CameraConfig().fieldOfView
    static var cameraPosition: SIMD3<Float> { SIMD3<Float>(0, CameraConfig().height, CameraConfig().distance) }
    static var cameraTarget: SIMD3<Float> {
        let c = CameraConfig()
        let pitch = c.pitch * .pi / 180
        return cameraPosition + SIMD3<Float>(0, -sin(pitch), -cos(pitch)) * 3
    }

    /// Finger-paddle schemes only: maps a touch (screen fractions, x from
    /// the left, `up` from the bottom, touch offset already applied) to the
    /// player controller's normalised (u, v) so the paddle is drawn where the
    /// finger points. Derived from the default camera: at the paddle's
    /// default depth, screen edge to edge covers x = ±1.0 m once the camera
    /// slides with the paddle, and paddle height 0.80–1.42 m spans 18–30 %
    /// up the screen.
    static func paddleInput(screenX: Double, up: Double, reach: PaddleReach) -> (u: Double, v: Double) {
        let x = (screenX - 0.5) * 2 * 1.0
        let u = (x - reach.xRange.lowerBound) / (reach.xRange.upperBound - reach.xRange.lowerBound)
        let v = (up - 0.18) / 0.12
        return (u, v)
    }

    init(table: TableGeometry, physics: PhysicsConfig, skin: BallSkin) {
        scene = ArenaBuilder.makeScene(table: table)
        // Paddles are drawn larger than a real blade (Build 2: easy to see
        // in the foreground). Physics keeps the real blade size.
        nearPaddle = PaddleNode(accent: Palette.cyan, radius: physics.paddleRadius * Self.paddleVisualScale)
        farPaddle = PaddleNode(accent: Palette.violet, radius: physics.paddleRadius * Self.paddleVisualScale)
        ballNode = BallNode(radius: physics.ball.radius, skin: skin)

        camera.projectionDirection = .horizontal
        camera.fieldOfView = Self.baseFOV
        camera.zNear = 0.05
        camera.zFar = 60
        camera.wantsHDR = true
        // Fixed exposure: auto exposure brightened the dark arena until the
        // key light washed out the table.
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = 0
        camera.bloomIntensity = 0.25
        camera.bloomThreshold = 1.2
        camera.bloomBlurRadius = 5
        camera.vignettingIntensity = 0.35
        camera.vignettingPower = 0.6
        cameraNode.camera = camera
        cameraNode.simdPosition = Self.cameraPosition
        cameraNode.simdLook(at: Self.cameraTarget)

        let root = scene.rootNode
        [cameraNode, nearPaddle, farPaddle, ballNode, trail].forEach { root.addChildNode($0) }

        // Contact shadow under the ball helps depth perception.
        let blob = SCNPlane(width: 0.07, height: 0.07)
        let bm = SCNMaterial()
        bm.lightingModel = .constant
        bm.diffuse.contents = Materials.radialSprite(UIColor(white: 0, alpha: 0.75))
        bm.writesToDepthBuffer = false
        blob.materials = [bm]
        shadowBlob.geometry = blob
        shadowBlob.eulerAngles.x = -.pi / 2
        shadowBlob.castsShadow = false
        root.addChildNode(shadowBlob)

        // Training: spin axis arrow.
        let shaft = SCNNode(geometry: SCNCylinder(radius: 0.003, height: 0.12))
        shaft.geometry?.materials = [Materials.glow(Palette.violet, intensity: 1)]
        let head = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.009, height: 0.025))
        head.geometry?.materials = [Materials.glow(Palette.violet, intensity: 1)]
        head.position = SCNVector3(0, 0.07, 0)
        spinArrow.addChildNode(shaft)
        spinArrow.addChildNode(head)
        spinArrow.isHidden = true
        root.addChildNode(spinArrow)

        for _ in 0..<6 {
            let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.035, pipeRadius: 0.003))
            ring.geometry?.materials = [Materials.glow(Palette.cyan, intensity: 1)]
            ring.isHidden = true
            ring.castsShadow = false
            root.addChildNode(ring)
            bounceMarkers.append(ring)
        }
    }

    func setSkin(_ skin: BallSkin) { ballNode.apply(skin: skin) }

    /// Subtle emphasis for powerful shots (kept small for gameplay stability).
    /// Contact feedback: paddle flash and recoil, trail emphasis.
    func paddleImpact(side: Side?, power: Double, perfect: Bool) {
        let node = side == .far ? farPaddle : nearPaddle
        node.impact(power: power, perfect: perfect)
        guard motionEffects else { return }
        trail.flash = max(trail.flash, Float(perfect ? 1 : power * 0.6))
        ballNode.pop(power: perfect ? max(power, 0.6) : power)
    }

    func powerShot(_ strength: Double) {
        guard motionEffects else { return }
        shake = max(shake, Float(0.006 * strength))
        fovKick = max(fovKick, Float(1.6 * strength))
        shotPower = max(shotPower, strength)
    }

    func update(sim: GameSimulation, frameDt: Double) {
        let world = sim.world
        nearPaddle.apply(sim.nearDriver.paddle)
        playerPaddleX = Float(sim.nearDriver.paddle.position.x)
        ballPosition = world.ball.position.simd
        ballOnPlayerSide = !world.ballHeld && world.ball.position.z > 0
        farPaddle.apply(sim.farDriver.paddle)
        ballNode.update(ball: world.ball, dt: frameDt, power: shotPower)
        shotPower *= 0.9

        let inPlay = !world.ballHeld && (sim.phase == .rally || sim.phase == .serving || sim.phase == .pointEnded)
        trail.update(ball: world.ball, inPlay: inPlay, cameraPosition: cameraNode.simdWorldPosition)

        // Ball contact shadow on table or floor.
        let p = world.ball.position
        let t = sim.setup.physics.table
        let overTable = t.contains(x: p.x, z: p.z)
        let groundY = overTable ? t.surfaceHeight + 0.001 : 0.001
        shadowBlob.simdPosition = SIMD3<Float>(Float(p.x), Float(groundY), Float(p.z))
        let h = Float(max(0, p.y - groundY))
        shadowBlob.opacity = CGFloat(max(0.1, 0.8 - h * 1.2))
        shadowBlob.scale = SCNVector3(1 + h, 1 + h, 1 + h)

        if trainingVisuals {
            let w = world.ball.spin
            let rate = w.length
            spinArrow.isHidden = rate < 20
            if rate >= 20 {
                spinArrow.simdPosition = p.simd
                let axis = (w / rate).simd
                spinArrow.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: axis)
                let s = Float(0.4 + min(1.6, rate / 150))
                spinArrow.scale = SCNVector3(1, s, 1)
            }
            // Bounce markers.
            if sim.recentBounces != shownBounces {
                shownBounces = sim.recentBounces
                for (i, ring) in bounceMarkers.enumerated() {
                    if i < shownBounces.count {
                        let b = shownBounces[shownBounces.count - 1 - i]
                        ring.isHidden = false
                        ring.simdPosition = SIMD3<Float>(Float(b.x), Float(b.y) + 0.002, Float(b.z))
                        ring.opacity = CGFloat(1 - Double(i) * 0.18)
                    } else {
                        ring.isHidden = true
                    }
                }
            }
        } else {
            bounceMarkers.forEach { $0.isHidden = true }
        }

        updateCamera(frameDt)
    }

    private func updateCamera(_ dt: Double) {
        switch cameraMode {
        case .gameplay:
            let c = cameraConfig
            let k = Float(1 - exp(-dt / max(c.smoothing, 0.01)))
            // Slide with the paddle; lean slightly toward wide or high balls.
            var wantX = playerPaddleX * c.paddleFollow
            var wantY: Float = 0
            if ballOnPlayerSide {
                wantX += ballPosition.x * c.ballTracking
                wantY = max(0, ballPosition.y - 1.3) * c.ballTracking * 2
            }
            followX += (wantX - followX) * k
            followY += (wantY - followY) * k
            let slide = SIMD3<Float>(followX, followY, 0)
            let pitch = c.pitch * .pi / 180
            let base = SIMD3<Float>(0, c.height, c.distance)
            var pos = base + slide
            if shake > 0.0001 {
                pos += SIMD3<Float>(Float.random(in: -1...1), Float.random(in: -1...1), 0) * shake
                shake *= 0.82
            }
            cameraNode.simdPosition = pos
            cameraNode.simdLook(at: base + slide + SIMD3<Float>(0, -sin(pitch), -cos(pitch)) * 3)
            camera.fieldOfView = c.fieldOfView + CGFloat(fovKick)
            fovKick *= 0.88
        case .orbit:
            orbitAngle += Float(dt) * 0.12
            // Lower, closer orbit for a cinematic menu backdrop.
            let r: Float = 3.7
            cameraNode.simdPosition = SIMD3<Float>(sin(orbitAngle) * r, 1.75, cos(orbitAngle) * r)
            cameraNode.simdLook(at: SIMD3<Float>(0, 0.85, 0))
            camera.fieldOfView = 66
        }
    }
}
