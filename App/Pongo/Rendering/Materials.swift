import SceneKit
import UIKit
import SpinCore

extension Vec3 {
    var scn: SCNVector3 { SCNVector3(Float(x), Float(y), Float(z)) }
    var simd: SIMD3<Float> { SIMD3<Float>(Float(x), Float(y), Float(z)) }
}

/// Reusable materials and procedural textures (no external art assets).
enum Materials {

    static func pbr(_ color: UIColor, metalness: CGFloat = 0, roughness: CGFloat = 0.5,
                    emission: UIColor? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = metalness
        m.roughness.contents = roughness
        if let e = emission { m.emission.contents = e }
        return m
    }

    /// Unlit glowing material (lines, trims, neon architecture).
    static func glow(_ color: UIColor, intensity: CGFloat = 1) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color.withAlphaComponent(1)
        m.emission.contents = color
        m.emission.intensity = intensity
        return m
    }

    static let tableTop: SCNMaterial = {
        // Unlit, with the shading baked into the texture: the table always
        // reads as a dark graphite surface whatever the arena lighting does
        // (lit materials washed out to pale grey on device).
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = tableTexture()
        return m
    }()
    static let metalFrame = pbr(Palette.silver, metalness: 1.0, roughness: 0.28)
    static let darkMetal = pbr(Palette.charcoal, metalness: 0.9, roughness: 0.4)
    static let lineCyan = glow(Palette.cyan, intensity: 1.2)
    static let lineWhite = glow(UIColor(white: 0.92, alpha: 1), intensity: 0.9)

    static let net: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = netTexture()
        m.emission.contents = UIColor(red: 0, green: 0.35, blue: 0.45, alpha: 1)
        m.isDoubleSided = true
        m.transparencyMode = .aOne
        m.writesToDepthBuffer = false
        return m
    }()

    /// Subtle micro-grid on the playing surface.
    static func tableTexture() -> UIImage {
        let size = CGSize(width: 512, height: 512)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            // Deep blue-graphite with a soft pool of light in the middle.
            let colors = [UIColor(red: 0.075, green: 0.115, blue: 0.20, alpha: 1).cgColor,
                          UIColor(red: 0.035, green: 0.055, blue: 0.105, alpha: 1).cgColor] as CFArray
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            cg.drawRadialGradient(grad, startCenter: CGPoint(x: 256, y: 256), startRadius: 0,
                                  endCenter: CGPoint(x: 256, y: 256), endRadius: 380, options: [.drawsAfterEndLocation])
            UIColor(red: 0.20, green: 0.45, blue: 0.70, alpha: 0.16).setStroke()
            let path = UIBezierPath()
            for i in stride(from: 0, through: 512, by: 32) {
                path.move(to: CGPoint(x: i, y: 0)); path.addLine(to: CGPoint(x: i, y: 512))
                path.move(to: CGPoint(x: 0, y: i)); path.addLine(to: CGPoint(x: 512, y: i))
            }
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// Semi-transparent illuminated mesh for the net.
    static func netTexture() -> UIImage {
        let size = CGSize(width: 512, height: 48)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 0.02, green: 0.10, blue: 0.16, alpha: 0.35).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.3, green: 0.95, blue: 1.0, alpha: 0.55).setStroke()
            let path = UIBezierPath()
            for x in stride(from: 0, through: 512, by: 6) {
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: 48))
            }
            for y in stride(from: 0, through: 48, by: 6) {
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: 512, y: y))
            }
            path.lineWidth = 0.7
            path.stroke()
        }
    }

    /// Temporary, clearly provisional logo mark (a ring with a "C" glyph).
    /// Replaced automatically when a `CnmbuckLogo` image asset is supplied.
    static func ballTexture(base: UIColor, mark: UIColor, bands: Bool) -> UIImage {
        if !bands, let logo = UIImage(named: GameConfig.logoAssetName) { return wrapLogo(logo, base: base) }
        if bands, let orb = UIImage(named: GameConfig.orbTextureAssetName) { return orb }
        let size = CGSize(width: 256, height: 128)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            base.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            if bands {
                mark.setFill()
                ctx.fill(CGRect(x: 0, y: 61, width: 256, height: 6))
                for i in 0..<4 {
                    ctx.fill(CGRect(x: CGFloat(i) * 64 + 28, y: 20, width: 8, height: 88))
                }
            }
            // Placeholder mark on two opposite sides so rotation is readable.
            for cx in [64.0, 192.0] {
                let r: CGFloat = 18
                let rect = CGRect(x: cx - r, y: 64 - r, width: 2 * r, height: 2 * r)
                let ring = UIBezierPath(ovalIn: rect)
                ring.lineWidth = 3
                mark.setStroke()
                ring.stroke()
                let c = UIBezierPath(arcCenter: CGPoint(x: cx, y: 64), radius: 9,
                                     startAngle: .pi * 0.25, endAngle: .pi * 1.75, clockwise: true)
                c.lineWidth = 3
                c.stroke()
            }
        }
    }

    private static func wrapLogo(_ logo: UIImage, base: UIColor) -> UIImage {
        let size = CGSize(width: 256, height: 128)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            base.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            for cx in [64.0, 192.0] {
                logo.draw(in: CGRect(x: cx - 22, y: 42, width: 44, height: 44))
            }
        }
    }

    /// Soft radial sprite for glows and particles.
    static func radialSprite(_ color: UIColor) -> UIImage {
        let size = CGSize(width: 64, height: 64)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            ctx.cgContext.drawRadialGradient(g, startCenter: CGPoint(x: 32, y: 32), startRadius: 0,
                                             endCenter: CGPoint(x: 32, y: 32), endRadius: 32, options: [])
        }
    }
}
