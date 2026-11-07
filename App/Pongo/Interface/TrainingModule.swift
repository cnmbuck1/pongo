import Foundation
import SpinCore

/// Focused Training exercises (Build 2). The feeder serves endlessly; each
/// module asks for one kind of return and scores the player's shots.
enum TrainingModule: Int, CaseIterable {
    case basicReturns, topspin, backspin, sidespin, placement

    var title: String {
        switch self {
        case .basicReturns: return "Basic Returns"
        case .topspin: return "Topspin"
        case .backspin: return "Backspin"
        case .sidespin: return "Sidespin"
        case .placement: return "Shot Placement"
        }
    }

    /// Short animated prompt shown while the ball is coming.
    var prompt: String {
        switch self {
        case .basicReturns: return "SWIPE UP TO HIT"
        case .topspin: return "SWIPE UP FAST"
        case .backspin: return "SWIPE DOWN"
        case .sidespin: return "SWIPE SIDEWAYS"
        case .placement: return "SWIPE TOWARD THE TARGET"
        }
    }

    var subtitle: String {
        switch self {
        case .basicReturns: return "Learn shot timing and paddle contact."
        case .topspin: return "Brush up through the ball."
        case .backspin: return "Brush down under the ball."
        case .sidespin: return "Brush across the ball to curve it."
        case .placement: return "Land the ball in the target zone."
        }
    }

    /// Target zone centre on the feeder's half for the n-th attempt
    /// (placement only): alternates left and right.
    func target(attempt: Int) -> Vec3? {
        guard self == .placement else { return nil }
        let x = attempt % 2 == 0 ? -0.42 : 0.42
        return Vec3(x, 0.76, -0.85)
    }
    static let targetRadius = 0.32

    /// Whether a return that landed at `landing` (nil = didn't land on the
    /// feeder's half) with spin `spin` counts as a success.
    func success(spin: SpinReading, landing: Vec3?, attempt: Int) -> Bool {
        guard let l = landing else { return false }
        switch self {
        case .basicReturns: return true
        case .topspin: return spin.topspin > 60
        case .backspin: return spin.topspin < -60
        case .sidespin: return abs(spin.sidespin) > 45
        case .placement:
            guard let t = target(attempt: attempt) else { return false }
            let dx = l.x - t.x, dz = l.z - t.z
            return (dx * dx + dz * dz).squareRoot() <= Self.targetRadius
        }
    }

    /// "LEFT DEEP", "CENTER SHORT", …
    static func describe(landing: Vec3?) -> String {
        guard let l = landing else { return "MISSED THE TABLE" }
        let side = l.x < -0.25 ? "LEFT" : (l.x > 0.25 ? "RIGHT" : "CENTER")
        let depth = abs(l.z) > 0.9 ? "DEEP" : "SHORT"
        return "\(side) \(depth)"
    }
}
