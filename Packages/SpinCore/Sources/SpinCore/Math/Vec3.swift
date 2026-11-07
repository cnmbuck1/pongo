import Foundation

/// Double-precision 3D vector used by the simulation.
///
/// The simulation deliberately does not use SceneKit / simd types so that it
/// stays platform independent and bit-for-bit reproducible for a given
/// platform and input sequence (useful for future multiplayer).
///
/// World coordinate system (metres):
/// * `x` – lateral, positive to the right as seen by the human player
/// * `y` – up, floor at `y = 0`
/// * `z` – along the table, positive toward the human player (near side)
///   The net is at `z = 0`.
public struct Vec3: Codable, Equatable, Hashable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x; self.y = y; self.z = z
    }

    public static let zero = Vec3(0, 0, 0)
    public static let unitX = Vec3(1, 0, 0)
    public static let unitY = Vec3(0, 1, 0)
    public static let unitZ = Vec3(0, 0, 1)

    @inlinable public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    @inlinable public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    @inlinable public static prefix func - (a: Vec3) -> Vec3 { Vec3(-a.x, -a.y, -a.z) }
    @inlinable public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    @inlinable public static func * (s: Double, a: Vec3) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    @inlinable public static func / (a: Vec3, s: Double) -> Vec3 { Vec3(a.x / s, a.y / s, a.z / s) }
    @inlinable public static func += (a: inout Vec3, b: Vec3) { a = a + b }
    @inlinable public static func -= (a: inout Vec3, b: Vec3) { a = a - b }
    @inlinable public static func *= (a: inout Vec3, s: Double) { a = a * s }

    @inlinable public func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }
    @inlinable public func cross(_ b: Vec3) -> Vec3 {
        Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x)
    }
    @inlinable public var lengthSquared: Double { x * x + y * y + z * z }
    @inlinable public var length: Double { lengthSquared.squareRoot() }

    /// Unit vector, or zero when the vector is (nearly) zero.
    @inlinable public var normalized: Vec3 {
        let l = length
        return l > 1e-12 ? self / l : .zero
    }

    /// Component-wise linear interpolation.
    @inlinable public static func lerp(_ a: Vec3, _ b: Vec3, _ t: Double) -> Vec3 { a + (b - a) * t }

    /// Rotates `self` about a unit `axis` by `angle` radians (Rodrigues).
    public func rotated(about axis: Vec3, by angle: Double) -> Vec3 {
        let k = axis.normalized
        let c = cos(angle), s = sin(angle)
        return self * c + k.cross(self) * s + k * (k.dot(self) * (1 - c))
    }

    /// Spherical interpolation between two unit vectors.
    public static func slerp(_ a: Vec3, _ b: Vec3, _ t: Double) -> Vec3 {
        let an = a.normalized, bn = b.normalized
        let d = max(-1, min(1, an.dot(bn)))
        let theta = acos(d)
        if theta < 1e-6 { return lerp(an, bn, t).normalized }
        let s = sin(theta)
        return (an * (sin((1 - t) * theta) / s) + bn * (sin(t * theta) / s)).normalized
    }

    public var description: String {
        String(format: "(%.3f, %.3f, %.3f)", x, y, z)
    }
}

@inlinable public func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }
