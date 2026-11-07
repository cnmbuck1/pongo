import SceneKit
import SpinCore

/// A futuristic paddle. The blade's facing follows the simulated face normal;
/// the node never moves on its own, it only mirrors the simulation.
final class PaddleNode: SCNNode {

    private let pivot = SCNNode()
    private var smoothedNormal = SIMD3<Float>(0, 0, -1)

    init(accent: UIColor, radius: Double) {
        super.init()
        let r = CGFloat(radius)
        addChildNode(pivot)

        // Blade: thin disc whose axis is the pivot's local +Z.
        let blade = SCNNode(geometry: SCNCylinder(radius: r, height: 0.012))
        blade.geometry?.materials = [Materials.pbr(UIColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1),
                                                   metalness: 0.2, roughness: 0.6)]
        blade.eulerAngles.x = .pi / 2
        pivot.addChildNode(blade)

        // Rubber face (front) tinted with the accent colour.
        let face = SCNNode(geometry: SCNCylinder(radius: r * 0.96, height: 0.002))
        face.geometry?.materials = [Materials.pbr(accent.withAlphaComponent(1).mixed(with: .black, 0.55),
                                                  metalness: 0.0, roughness: 0.75)]
        face.eulerAngles.x = .pi / 2
        face.position = SCNVector3(0, 0, 0.0065)
        pivot.addChildNode(face)

        // Glowing rim.
        let rim = SCNNode(geometry: SCNTorus(ringRadius: r, pipeRadius: 0.0035))
        rim.geometry?.materials = [Materials.glow(accent, intensity: 1.1)]
        rim.eulerAngles.x = .pi / 2
        rim.castsShadow = false
        pivot.addChildNode(rim)

        // Handle hanging below the blade.
        let handle = SCNNode(geometry: SCNBox(width: 0.028, height: 0.10, length: 0.022, chamferRadius: 0.008))
        handle.geometry?.materials = [Materials.metalFrame]
        handle.position = SCNVector3(0, -Float(r) - 0.045, 0)
        pivot.addChildNode(handle)
        let grip = SCNNode(geometry: SCNBox(width: 0.004, height: 0.08, length: 0.024, chamferRadius: 0))
        grip.geometry?.materials = [Materials.glow(accent, intensity: 0.7)]
        grip.position = SCNVector3(0.0145, 0, 0)
        handle.addChildNode(grip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Mirrors a simulated paddle state.
    func apply(_ paddle: PaddleState) {
        simdPosition = paddle.position.simd
        // Light smoothing of orientation only (position is exact).
        let target = paddle.normal.simd
        smoothedNormal = simd_normalize(smoothedNormal + (target - smoothedNormal) * 0.5)
        pivot.simdLook(at: simdWorldPosition + smoothedNormal, up: SIMD3<Float>(0, 1, 0),
                       localFront: SIMD3<Float>(0, 0, 1))
    }
}

extension UIColor {
    func mixed(with other: UIColor, _ t: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t,
                       blue: b1 + (b2 - b1) * t, alpha: a1 + (a2 - a1) * t)
    }
}
