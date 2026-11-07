import Foundation

/// Human-readable decomposition of the ball's spin relative to its flight,
/// for the spin indicator and training overlays.
public struct SpinReading: Equatable {
    /// Positive = topspin, negative = backspin (rad/s).
    public var topspin: Double
    /// Positive = the ball curves to the player's right (+x), negative = left.
    /// Magnitude is the vertical-axis spin (rad/s).
    public var sidespin: Double
    /// Total spin rate (rad/s).
    public var total: Double

    public var revolutionsPerSecond: Double { total / (2 * .pi) }

    /// Spin below this rate is reported as "no spin".
    public static let threshold: Double = 25

    public enum Kind: String, Codable {
        case none, topspin, backspin, leftSide, rightSide
    }

    /// Dominant components (may contain both a top/back and a side entry).
    public var components: [Kind] {
        var k: [Kind] = []
        if topspin > Self.threshold { k.append(.topspin) }
        if topspin < -Self.threshold { k.append(.backspin) }
        if sidespin > Self.threshold { k.append(.rightSide) }
        if sidespin < -Self.threshold { k.append(.leftSide) }
        return k.isEmpty ? [.none] : k
    }

    public var label: String {
        let names: [Kind: String] = [.none: "No spin", .topspin: "Topspin", .backspin: "Backspin",
                                     .leftSide: "Left side", .rightSide: "Right side"]
        return components.map { names[$0]! }.joined(separator: " + ")
    }

    public init(topspin: Double, sidespin: Double, total: Double) {
        self.topspin = topspin; self.sidespin = sidespin; self.total = total
    }

    public init(ball: BallState) {
        let v = ball.velocity
        let horizontal = Vec3(v.x, 0, v.z)
        let w = ball.spin
        total = w.length
        if horizontal.length < 0.2 {
            topspin = 0; sidespin = 0; return
        }
        let travel = horizontal.normalized
        // Axis about which forward-rolling (topspin) rotation occurs.
        let topAxis = Vec3.unitY.cross(travel)
        topspin = w.dot(topAxis)
        // Sidespin: vertical-axis spin, signed by the lateral (x) curve it causes.
        let curveX = (Vec3(0, w.y, 0).cross(v)).x
        sidespin = curveX >= 0 ? abs(w.y) : -abs(w.y)
    }
}
