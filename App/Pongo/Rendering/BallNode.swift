import SceneKit
import SpinCore

/// The ball. Its visual rotation integrates the simulated spin vector, so
/// the logo mark shows the real direction and rate of spin. Skins are purely
/// cosmetic.
final class BallNode: SCNNode {

    private let sphere = SCNNode()
    private let glow = SCNNode()
    private(set) var skin: BallSkin = .classic
    private var orientationQ = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    private var glowLevel: Float = 0

    init(radius: Double, skin: BallSkin) {
        super.init()
        sphere.geometry = SCNSphere(radius: CGFloat(radius))
        (sphere.geometry as? SCNSphere)?.segmentCount = 32
        addChildNode(sphere)

        let g = SCNPlane(width: CGFloat(radius * 7), height: CGFloat(radius * 7))
        let gm = SCNMaterial()
        gm.lightingModel = .constant
        gm.diffuse.contents = Materials.radialSprite(Palette.cyan)
        gm.blendMode = .add
        gm.writesToDepthBuffer = false
        g.materials = [gm]
        glow.geometry = g
        glow.constraints = [SCNBillboardConstraint()]
        glow.opacity = 0
        glow.castsShadow = false
        addChildNode(glow)
        apply(skin: skin)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(skin: BallSkin) {
        self.skin = skin
        let m: SCNMaterial
        switch skin {
        case .classic:
            m = Materials.pbr(.white, metalness: 0, roughness: 0.45)
            m.diffuse.contents = Materials.ballTexture(base: UIColor(white: 0.97, alpha: 1),
                                                       mark: UIColor(white: 0.55, alpha: 1), bands: false)
            // Slight self-illumination keeps a crisp white silhouette
            // against the dark arena without blooming.
            m.emission.contents = UIColor(white: 1, alpha: 1)
            m.emission.intensity = 0.3
        case .energy:
            m = Materials.pbr(.white, metalness: 0.55, roughness: 0.3)
            m.diffuse.contents = Materials.ballTexture(base: UIColor(white: 0.92, alpha: 1),
                                                       mark: Palette.cyan, bands: false)
            m.emission.contents = Palette.cyan
            m.emission.intensity = 0.12
        case .orb:
            m = Materials.pbr(Palette.silver, metalness: 0.95, roughness: 0.18)
            m.diffuse.contents = Materials.ballTexture(base: Palette.silver, mark: Palette.cyan, bands: true)
            m.emission.contents = Materials.ballTexture(base: .black, mark: Palette.cyan, bands: true)
            m.emission.intensity = 0.9
        }
        sphere.geometry?.materials = [m]
    }

    /// Short squash-and-recover on a strong strike (visual only).
    func pop(power: Double) {
        guard power > 0.35 else { return }
        let s = Float(1 + 0.25 * min(1, power))
        sphere.removeAction(forKey: "pop")
        sphere.scale = SCNVector3(s, 1 / s.squareRoot(), s)
        sphere.runAction(.scale(to: 1, duration: 0.09), forKey: "pop")
    }

    /// - Parameters:
    ///   - power: 0...1 recent shot power (for the orb's glow on big shots).
    func update(ball: BallState, dt: Double, power: Double) {
        simdPosition = ball.position.simd
        let w = ball.spin
        let rate = Float(w.length)
        if rate > 0.01 {
            let axis = w.simd / rate
            orientationQ = simd_normalize(simd_quatf(angle: rate * Float(dt), axis: axis) * orientationQ)
            sphere.simdOrientation = orientationQ
        }
        // Glow: energy and orb skins react to spin; orb flares on power shots.
        let spinFactor = min(1, rate / 220)
        var target: Float
        switch skin {
        case .classic: target = 0
        case .energy: target = 0.25 * spinFactor
        case .orb: target = 0.2 + 0.45 * spinFactor + 0.6 * Float(power)
        }
        glowLevel += (target - glowLevel) * 0.15
        glow.opacity = CGFloat(min(1, glowLevel))
    }
}
