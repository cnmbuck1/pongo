import SceneKit
import SpinCore

/// The futuristic table: regulation proportions (2.74 m × 1.525 m, surface at
/// 0.76 m, 15.25 cm net), graphite surface, illuminated cyan perimeter and
/// centre lines, metallic frame, angular supports and soft under-glow.
final class TableNode: SCNNode {

    init(geometry t: TableGeometry) {
        super.init()
        name = "table"
        let L = CGFloat(t.length), W = CGFloat(t.width), H = CGFloat(t.surfaceHeight)
        let thick = CGFloat(t.topThickness)

        // Playing surface.
        let top = SCNNode(geometry: SCNBox(width: W, height: thick, length: L, chamferRadius: 0.004))
        top.geometry?.materials = [Materials.tableTop]
        top.position = SCNVector3(0, Float(H - thick / 2), 0)
        addChildNode(top)

        // Metallic frame (slightly larger, just under the top).
        let frame = SCNNode(geometry: SCNBox(width: W + 0.03, height: 0.035, length: L + 0.03, chamferRadius: 0.01))
        frame.geometry?.materials = [Materials.metalFrame]
        frame.position = SCNVector3(0, Float(H - thick - 0.017), 0)
        addChildNode(frame)

        // Illuminated lines: 2 cm perimeter, 3 mm centre line.
        let y = Float(H) + 0.0008
        func line(_ w: CGFloat, _ l: CGFloat, _ x: Float, _ z: Float, _ m: SCNMaterial) {
            let n = SCNNode(geometry: SCNBox(width: w, height: 0.0015, length: l, chamferRadius: 0))
            n.geometry?.materials = [m]
            n.position = SCNVector3(x, y, z)
            n.castsShadow = false
            addChildNode(n)
        }
        let edge: CGFloat = 0.02
        line(edge, L, Float(-W / 2 + edge / 2), 0, Materials.lineCyan)
        line(edge, L, Float(W / 2 - edge / 2), 0, Materials.lineCyan)
        line(W, edge, 0, Float(-L / 2 + edge / 2), Materials.lineCyan)
        line(W, edge, 0, Float(L / 2 - edge / 2), Materials.lineCyan)
        line(0.003, L, 0, 0, Materials.lineWhite)

        // Angular support structure: two slanted V-frames and a spine.
        for zSign: Float in [-1, 1] {
            for xSign: Float in [-1, 1] {
                let leg = SCNNode(geometry: SCNBox(width: 0.05, height: CGFloat(H) - 0.06, length: 0.07, chamferRadius: 0.01))
                leg.geometry?.materials = [Materials.darkMetal]
                leg.position = SCNVector3(xSign * Float(W) * 0.36, Float(H) / 2 - 0.04, zSign * Float(L) * 0.30)
                leg.eulerAngles = SCNVector3(zSign * 0.22, 0, -xSign * 0.18)
                addChildNode(leg)
                // Glowing accent strip on each leg.
                let strip = SCNNode(geometry: SCNBox(width: 0.008, height: CGFloat(H) - 0.12, length: 0.072, chamferRadius: 0))
                strip.geometry?.materials = [Materials.glow(Palette.cyan, intensity: 0.6)]
                strip.position = SCNVector3(xSign * 0.026, 0, 0)
                strip.castsShadow = false
                leg.addChildNode(strip)
            }
            let foot = SCNNode(geometry: SCNBox(width: W * 0.85, height: 0.03, length: 0.12, chamferRadius: 0.01))
            foot.geometry?.materials = [Materials.darkMetal]
            foot.position = SCNVector3(0, 0.015, zSign * Float(L) * 0.36)
            addChildNode(foot)
        }
        let spine = SCNNode(geometry: SCNBox(width: 0.08, height: 0.06, length: L * 0.7, chamferRadius: 0.02))
        spine.geometry?.materials = [Materials.darkMetal]
        spine.position = SCNVector3(0, Float(H) * 0.45, 0)
        addChildNode(spine)

        // Soft under-table illumination.
        let glowPlane = SCNNode(geometry: SCNPlane(width: W * 1.4, height: L * 1.2))
        let gm = SCNMaterial()
        gm.lightingModel = .constant
        gm.diffuse.contents = Materials.radialSprite(Palette.cyan.withAlphaComponent(0.35))
        gm.blendMode = .add
        gm.writesToDepthBuffer = false
        glowPlane.geometry?.materials = [gm]
        glowPlane.eulerAngles.x = -.pi / 2
        glowPlane.position = SCNVector3(0, 0.004, 0)
        glowPlane.castsShadow = false
        addChildNode(glowPlane)

        let under = SCNLight()
        under.type = .omni
        under.color = Palette.cyan
        under.intensity = 120
        under.attenuationStartDistance = 0.2
        under.attenuationEndDistance = 2.2
        let underNode = SCNNode()
        underNode.light = under
        underNode.position = SCNVector3(0, 0.35, 0)
        addChildNode(underNode)

        addChildNode(makeNet(t))
    }

    private func makeNet(_ t: TableGeometry) -> SCNNode {
        let net = SCNNode()
        net.name = "net"
        let span = CGFloat(t.netHalfSpan * 2)
        let h = CGFloat(t.netHeight)
        let mesh = SCNNode(geometry: SCNPlane(width: span, height: h))
        mesh.geometry?.materials = [Materials.net]
        mesh.position = SCNVector3(0, Float(t.surfaceHeight) + Float(h) / 2, 0)
        mesh.castsShadow = false
        net.addChildNode(mesh)

        let tape = SCNNode(geometry: SCNBox(width: span, height: 0.012, length: 0.006, chamferRadius: 0.002))
        tape.geometry?.materials = [Materials.glow(UIColor(white: 0.95, alpha: 1), intensity: 0.8)]
        tape.position = SCNVector3(0, Float(t.netTop) - 0.006, 0)
        net.addChildNode(tape)

        for s: Float in [-1, 1] {
            let post = SCNNode(geometry: SCNCylinder(radius: 0.012, height: h + 0.03))
            post.geometry?.materials = [Materials.glow(Palette.cyan, intensity: 0.9)]
            post.position = SCNVector3(s * Float(span / 2), Float(t.surfaceHeight) + Float(h + 0.03) / 2 - 0.015, 0)
            net.addChildNode(post)
            let clamp = SCNNode(geometry: SCNBox(width: 0.03, height: 0.03, length: 0.06, chamferRadius: 0.005))
            clamp.geometry?.materials = [Materials.metalFrame]
            clamp.position = SCNVector3(s * Float(span / 2), Float(t.surfaceHeight) - 0.01, 0)
            net.addChildNode(clamp)
        }
        return net
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
