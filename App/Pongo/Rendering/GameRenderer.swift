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

    static let baseFOV: CGFloat = 66
    static let cameraPosition = SIMD3<Float>(0, 3.0, 2.4)
    static let cameraTarget = SIMD3<Float>(0, 0.76, 0.0)

    init(table: TableGeometry, physics: PhysicsConfig, skin: BallSkin) {
        scene = ArenaBuilder.makeScene(table: table)
        nearPaddle = PaddleNode(accent: Palette.cyan, radius: physics.paddleRadius)
        farPaddle = PaddleNode(accent: Palette.violet, radius: physics.paddleRadius)
        ballNode = BallNode(radius: physics.ball.radius, skin: skin)

        camera.projectionDirection = .horizontal
        camera.fieldOfView = Self.baseFOV
        camera.zNear = 0.05
        camera.zFar = 60
        camera.wantsHDR = true
        camera.bloomIntensity = 0.6
        camera.bloomThreshold = 0.75
        camera.bloomBlurRadius = 6
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
    func powerShot(_ strength: Double) {
        shake = max(shake, Float(0.006 * strength))
        fovKick = max(fovKick, Float(1.6 * strength))
        shotPower = max(shotPower, strength)
    }

    func update(sim: GameSimulation, frameDt: Double) {
        let world = sim.world
        nearPaddle.apply(sim.nearDriver.paddle)
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
            var pos = Self.cameraPosition
            if shake > 0.0001 {
                pos += SIMD3<Float>(Float.random(in: -1...1), Float.random(in: -1...1), 0) * shake
                shake *= 0.82
            }
            cameraNode.simdPosition = pos
            cameraNode.simdLook(at: Self.cameraTarget)
            camera.fieldOfView = Self.baseFOV + CGFloat(fovKick)
            fovKick *= 0.88
        case .orbit:
            orbitAngle += Float(dt) * 0.12
            let r: Float = 4.6
            cameraNode.simdPosition = SIMD3<Float>(sin(orbitAngle) * r, 2.3, cos(orbitAngle) * r)
            cameraNode.simdLook(at: SIMD3<Float>(0, 0.8, 0))
            camera.fieldOfView = 70
        }
    }
}
