import SceneKit
import SpinCore

/// One premium futuristic arena: dark atmosphere, reflective floor, subtle
/// illuminated architecture, distant stadium tiers and soft particles.
/// Built entirely from procedural geometry with shared materials.
enum ArenaBuilder {

    static func makeScene(table: TableGeometry) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = Palette.midnight
        scene.fogColor = Palette.midnight
        scene.fogStartDistance = 7
        scene.fogEndDistance = 26
        scene.fogDensityExponent = 1.4
        scene.lightingEnvironment.contents = Palette.deepBlue
        scene.lightingEnvironment.intensity = 0.35

        let root = scene.rootNode
        root.addChildNode(makeFloor())
        root.addChildNode(TableNode(geometry: table))
        root.addChildNode(makeArchitecture())
        root.addChildNode(makeStands())
        root.addChildNode(makeParticles())
        addLights(to: root)
        return scene
    }

    private static func makeFloor() -> SCNNode {
        let floor = SCNFloor()
        floor.reflectivity = 0.08
        floor.reflectionFalloffEnd = 2.5
        floor.reflectionResolutionScaleFactor = 0.5
        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.diffuse.contents = UIColor(red: 0.025, green: 0.032, blue: 0.06, alpha: 1)
        floor.materials = [m]
        let n = SCNNode(geometry: floor)
        n.name = "floor"

        // Court boundary markings on the floor.
        let ring = SCNNode(geometry: SCNTorus(ringRadius: 4.2, pipeRadius: 0.012))
        ring.geometry?.materials = [Materials.glow(Palette.cyan.withAlphaComponent(0.5), intensity: 0.25)]
        ring.scale = SCNVector3(0.75, 1, 1.25)
        ring.position = SCNVector3(0, 0.002, 0)
        ring.castsShadow = false
        n.addChildNode(ring)
        return n
    }

    private static func makeArchitecture() -> SCNNode {
        let group = SCNNode()
        let pillarMat = Materials.pbr(Palette.charcoal, metalness: 0.8, roughness: 0.45)
        let cyanStrip = Materials.glow(Palette.cyan.mixed(with: .black, 0.45), intensity: 0.35)
        let violetStrip = Materials.glow(Palette.violet.mixed(with: .black, 0.45), intensity: 0.3)
        let count = 14
        for i in 0..<count {
            let a = Float(i) / Float(count) * 2 * .pi
            let r: Float = 9.5
            let x = sin(a) * r * 0.85
            let z = cos(a) * r
            let pillar = SCNNode(geometry: SCNBox(width: 0.5, height: 7, length: 0.5, chamferRadius: 0.05))
            pillar.geometry?.materials = [pillarMat]
            pillar.position = SCNVector3(x, 3.5, z)
            pillar.eulerAngles.y = a
            let strip = SCNNode(geometry: SCNBox(width: 0.06, height: 6.2, length: 0.52, chamferRadius: 0))
            strip.geometry?.materials = [i % 2 == 0 ? cyanStrip : violetStrip]
            strip.castsShadow = false
            pillar.addChildNode(strip)
            group.addChildNode(pillar)
        }
        // Overhead halo ring.
        let halo = SCNNode(geometry: SCNTorus(ringRadius: 3.2, pipeRadius: 0.03))
        halo.geometry?.materials = [Materials.glow(Palette.cyan.mixed(with: .black, 0.4), intensity: 0.4)]
        halo.scale = SCNVector3(0.8, 1, 1.3)
        halo.position = SCNVector3(0, 4.2, 0)
        halo.castsShadow = false
        group.addChildNode(halo)
        halo.runAction(.repeatForever(.sequence([
            .fadeOpacity(to: 0.6, duration: 3), .fadeOpacity(to: 1.0, duration: 3)
        ])))
        return group
    }

    /// Distant stadium tiers behind the opponent, lit by thin light bands.
    private static func makeStands() -> SCNNode {
        let group = SCNNode()
        let tierMat = Materials.pbr(UIColor(red: 0.05, green: 0.06, blue: 0.10, alpha: 1), metalness: 0.3, roughness: 0.8)
        let band = Materials.glow(Palette.cyan.mixed(with: .black, 0.6), intensity: 0.18)
        for row in 0..<5 {
            let w = CGFloat(14 + row * 2)
            let tier = SCNNode(geometry: SCNBox(width: w, height: 0.6, length: 1.2, chamferRadius: 0))
            tier.geometry?.materials = [tierMat]
            tier.position = SCNVector3(0, Float(row) * 0.9 + 0.3, -12 - Float(row) * 1.1)
            group.addChildNode(tier)
            let light = SCNNode(geometry: SCNBox(width: w, height: 0.03, length: 0.03, chamferRadius: 0))
            light.geometry?.materials = [band]
            light.position = SCNVector3(0, 0.31, 0.6)
            light.castsShadow = false
            tier.addChildNode(light)
        }
        // Big display frame high above the stands (branding placeholder).
        let screen = SCNNode(geometry: SCNPlane(width: 5, height: 1.2))
        let sm = SCNMaterial()
        sm.lightingModel = .constant
        sm.diffuse.contents = brandBoard()
        screen.geometry?.materials = [sm]
        screen.position = SCNVector3(0, 7.2, -14)
        group.addChildNode(screen)
        return group
    }

    private static func brandBoard() -> UIImage {
        let size = CGSize(width: 1000, height: 240)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            Palette.midnight.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let border = UIBezierPath(roundedRect: CGRect(x: 6, y: 6, width: 988, height: 228), cornerRadius: 18)
            border.lineWidth = 4
            Palette.cyan.setStroke()
            border.stroke()
            let p = NSMutableParagraphStyle()
            p.alignment = .center
            let title = NSAttributedString(string: GameConfig.title, attributes: [
                .font: UIFont.systemFont(ofSize: 110, weight: .heavy),
                .foregroundColor: Palette.white, .kern: 18, .paragraphStyle: p])
            title.draw(in: CGRect(x: 0, y: 30, width: 1000, height: 130))
            let studio = NSAttributedString(string: GameConfig.studio, attributes: [
                .font: UIFont.systemFont(ofSize: 34, weight: .semibold),
                .foregroundColor: Palette.cyan, .kern: 10, .paragraphStyle: p])
            studio.draw(in: CGRect(x: 0, y: 165, width: 1000, height: 50))
        }
    }

    private static func makeParticles() -> SCNNode {
        let ps = SCNParticleSystem()
        ps.particleImage = Materials.radialSprite(Palette.cyan)
        ps.birthRate = 6
        ps.particleLifeSpan = 9
        ps.particleLifeSpanVariation = 3
        ps.particleSize = 0.03
        ps.particleSizeVariation = 0.02
        ps.particleColor = Palette.cyan.withAlphaComponent(0.18)
        ps.particleColorVariation = SCNVector4(0.05, 0.1, 0.2, 0.2)
        ps.particleVelocity = 0.08
        ps.particleVelocityVariation = 0.06
        ps.emittingDirection = SCNVector3(0, 1, 0)
        ps.spreadingAngle = 80
        ps.blendMode = .additive
        ps.isAffectedByGravity = false
        ps.emitterShape = SCNBox(width: 14, height: 5, length: 16, chamferRadius: 0)
        ps.birthLocation = .volume
        let n = SCNNode()
        n.position = SCNVector3(0, 2.5, -2)
        n.addParticleSystem(ps)
        return n
    }

    private static func addLights(to root: SCNNode) {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = UIColor(red: 0.25, green: 0.30, blue: 0.45, alpha: 1)
        ambient.intensity = 170
        let an = SCNNode(); an.light = ambient
        root.addChildNode(an)

        // Key light above the table, with soft shadows. Kept moderate and
        // tightly coned so it lights the table without a glaring hotspot.
        let key = SCNLight()
        key.type = .spot
        key.intensity = 380
        key.color = UIColor(white: 0.96, alpha: 1)
        key.spotInnerAngle = 28
        key.spotOuterAngle = 52
        key.castsShadow = true
        key.shadowMode = .deferred
        key.shadowRadius = 6
        key.shadowSampleCount = 8
        key.shadowColor = UIColor(white: 0, alpha: 0.55)
        key.shadowMapSize = CGSize(width: 1024, height: 1024)
        let kn = SCNNode(); kn.light = key
        kn.position = SCNVector3(0, 3.2, -0.3)
        kn.eulerAngles.x = -.pi / 2
        root.addChildNode(kn)

        // Coloured rim lights for the sci-fi look.
        for (pos, color) in [(SCNVector3(-4, 2.5, -4), Palette.violet), (SCNVector3(4, 2.5, 4), Palette.cyan)] {
            let l = SCNLight()
            l.type = .omni
            l.color = color
            l.intensity = 280
            l.attenuationEndDistance = 12
            let n = SCNNode(); n.light = l
            n.position = pos
            root.addChildNode(n)
        }
    }
}
