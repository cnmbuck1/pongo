import SceneKit
import SpinCore

/// Camera-facing ribbon through the ball's recent positions. It shows the
/// real, recent curvature of the flight (never a predicted path), so a
/// curving sidespin or dipping topspin ball draws a curved trail. Width and
/// brightness scale with spin; colour reads the spin type (cyan topspin,
/// violet backspin, paler for sidespin); fast shots draw longer, brighter.
final class SpinTrail: SCNNode {

    private var points: [SIMD3<Float>] = []
    private let maxPoints = 34
    var enabled = true
    /// Brief emphasis after a strong or perfect hit (decays per frame).
    var flash: Float = 0
    private let material: SCNMaterial
    var boost: Float = 1

    override init() {
        material = SCNMaterial()
        material.lightingModel = .constant
        material.blendMode = .add
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        material.diffuse.contents = UIColor.white
        super.init()
        castsShadow = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reset() {
        points.removeAll()
        geometry = nil
    }

    func update(ball: BallState, inPlay: Bool, cameraPosition: SIMD3<Float>) {
        guard inPlay, enabled else { reset(); return }
        flash *= 0.94
        points.append(ball.position.simd)
        let speed = Float(ball.velocity.length)
        // Standard shots keep a short trail; power shots a longer one.
        let length = Int(14 + min(1, max(0, (speed - 6) / 8)) * Float(maxPoints - 14))
        if points.count > length { points.removeFirst(points.count - length) }
        let spin = Float(ball.spin.length)
        let strength = min(1, (0.15 + max(0, (spin - 25) / 220)) * boost + flash * 0.5)
        guard points.count >= 3 else { geometry = nil; return }
        // Spin type → colour.
        let reading = SpinReading(ball: ball)
        let total = max(1e-3, abs(reading.topspin) + abs(reading.sidespin))
        let back = Float(max(0, -reading.topspin) / total)
        let side = Float(abs(reading.sidespin) / total)
        let cyan = SIMD3<Float>(0.0, 0.88, 1.0), violet = SIMD3<Float>(0.56, 0.40, 1.0), pale = SIMD3<Float>(0.7, 1.0, 1.0)
        var rgb = cyan + (violet - cyan) * back
        rgb = rgb + (pale - rgb) * (side * 0.6)
        let bright = 0.8 + 0.4 * min(1, max(0, (speed - 8) / 6)) + flash * 0.6

        var verts: [SCNVector3] = []
        var colors: [SIMD4<Float>] = []
        verts.reserveCapacity(points.count * 2)
        let n = points.count
        for i in 0..<n {
            let p = points[i]
            let prev = points[max(0, i - 1)], next = points[min(n - 1, i + 1)]
            var dir = next - prev
            if simd_length(dir) < 1e-5 { dir = SIMD3<Float>(0, 0, 1) }
            let toCam = simd_normalize(cameraPosition - p)
            var side = simd_cross(simd_normalize(dir), toCam)
            if simd_length(side) < 1e-5 { side = SIMD3<Float>(1, 0, 0) }
            side = simd_normalize(side)
            let t = Float(i) / Float(n - 1)               // 0 = oldest, 1 = newest
            let width = (0.004 + 0.014 * strength) * t
            let a = (t * t) * (0.25 + 0.75 * strength)
            let l = p - side * width, r = p + side * width
            verts.append(SCNVector3(l.x, l.y, l.z))
            verts.append(SCNVector3(r.x, r.y, r.z))
            let k = a * bright
            let c = SIMD4<Float>(rgb.x * k, rgb.y * k, rgb.z * k, a)
            colors.append(c); colors.append(c)
        }
        let vSource = SCNGeometrySource(vertices: verts)
        let cData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let cSource = SCNGeometrySource(data: cData, semantic: .color, vectorCount: colors.count,
                                        usesFloatComponents: true, componentsPerVector: 4,
                                        bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                        dataStride: MemoryLayout<SIMD4<Float>>.stride)
        var indices: [UInt16] = []
        for i in 0..<(n - 1) {
            let a = UInt16(i * 2), b = UInt16(i * 2 + 1), c = UInt16(i * 2 + 2), d = UInt16(i * 2 + 3)
            indices += [a, b, c, b, d, c]
        }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let g = SCNGeometry(sources: [vSource, cSource], elements: [element])
        g.materials = [material]
        geometry = g
    }
}
