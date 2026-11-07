import Foundation

// Build 3 shot selection: "the game controls where the paddle goes, the
// player controls what the paddle does". A swipe made while the ball is on
// its way selects a shot; the auto paddle executes it at the real contact.

/// The kind of shot a gesture selected.
public enum ShotKind: String, Codable, Equatable, CaseIterable {
    case standard, topspin, powerTopspin, backspin, left, right, sidespin

    public var label: String {
        switch self {
        case .standard: return "STANDARD"
        case .topspin: return "TOPSPIN"
        case .powerTopspin: return "POWER TOPSPIN"
        case .backspin: return "BACKSPIN"
        case .left: return "LEFT"
        case .right: return "RIGHT"
        case .sidespin: return "SIDESPIN"
        }
    }
}

/// A selected shot, ready to be executed at contact.
public struct ShotCommand: Equatable {
    public var kind: ShotKind
    /// -1 (far left of the opponent's half, as the player sees it) ... +1 (right).
    public var placement: Double
    /// Paddle stroke in the hitter's frame (m/s): x = sideways brush
    /// (sidespin), y = vertical brush (+ topspin, − backspin), z = forward drive.
    public var brush: Double
    public var sideBrush: Double
    public var forward: Double
    /// When the gesture was completed (simulation time).
    public var time: Double

    public init(kind: ShotKind, placement: Double = 0, brush: Double, sideBrush: Double = 0,
                forward: Double, time: Double = 0) {
        self.kind = kind; self.placement = placement; self.brush = brush
        self.sideBrush = sideBrush; self.forward = forward; self.time = time
    }

    /// Short label shown while the shot is buffered, e.g. "TOPSPIN · LEFT".
    public var label: String {
        switch kind {
        case .topspin, .powerTopspin, .backspin:
            if placement <= -0.4 { return kind.label + " · LEFT" }
            if placement >= 0.4 { return kind.label + " · RIGHT" }
            return kind.label
        default:
            return kind.label
        }
    }

    /// World-space paddle velocity for a hitter on `side`.
    public func stroke(for side: Side) -> Vec3 {
        Vec3(sideBrush, brush, side.hitDirection * forward)
    }
}

/// Tuning for gesture → shot. Every number is configurable.
public struct ShotTuning: Codable, Equatable {
    /// Minimum swipe length (screen heights) and average speed (screen
    /// heights / s) for a gesture to count as a shot. Shorter = a tap.
    public var minLength = 0.035
    public var minSpeed = 0.45
    /// A swipe within this angle (degrees) of vertical is a spin shot; within
    /// this angle of horizontal it is a placement shot; between is diagonal.
    public var verticalCone = 32.0
    public var horizontalCone = 30.0
    /// Path bulge / chord length above which a swipe counts as curved
    /// (sidespin brush) rather than straight.
    public var curveThreshold = 0.16
    /// Speed (screen heights / s) above which an upward swipe is a power topspin.
    public var powerSpeed = 2.4
    /// Swipe speed range mapped to 0...1 shot power.
    public var speedLow = 0.6
    public var speedHigh = 3.6

    // Stroke presets (m/s).
    public var standard = (brush: 0.45, forward: 2.7)
    public var topspinBrush = 1.3...2.4
    public var topspinForward = 2.7...4.2
    public var powerBrush = 2.4...3.3
    public var powerForward = 4.6...6.6
    public var backspinBrush = (-2.3)...(-1.4)
    public var backspinForward = 1.9...2.7
    public var placementForward = 2.7...4.0
    public var sideBrush = 1.6...2.6
    public var diagonalPlacement = 0.8

    public init() {}

    enum CodingKeys: String, CodingKey {
        case minLength, minSpeed, verticalCone, horizontalCone, curveThreshold, powerSpeed, speedLow, speedHigh
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minLength = (try? c.decodeIfPresent(Double.self, forKey: .minLength)) ?? minLength
        minSpeed = (try? c.decodeIfPresent(Double.self, forKey: .minSpeed)) ?? minSpeed
        verticalCone = (try? c.decodeIfPresent(Double.self, forKey: .verticalCone)) ?? verticalCone
        horizontalCone = (try? c.decodeIfPresent(Double.self, forKey: .horizontalCone)) ?? horizontalCone
        curveThreshold = (try? c.decodeIfPresent(Double.self, forKey: .curveThreshold)) ?? curveThreshold
        powerSpeed = (try? c.decodeIfPresent(Double.self, forKey: .powerSpeed)) ?? powerSpeed
        speedLow = (try? c.decodeIfPresent(Double.self, forKey: .speedLow)) ?? speedLow
        speedHigh = (try? c.decodeIfPresent(Double.self, forKey: .speedHigh)) ?? speedHigh
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(minLength, forKey: .minLength); try c.encode(minSpeed, forKey: .minSpeed)
        try c.encode(verticalCone, forKey: .verticalCone); try c.encode(horizontalCone, forKey: .horizontalCone)
        try c.encode(curveThreshold, forKey: .curveThreshold); try c.encode(powerSpeed, forKey: .powerSpeed)
        try c.encode(speedLow, forKey: .speedLow); try c.encode(speedHigh, forKey: .speedHigh)
    }

    public static func == (a: ShotTuning, b: ShotTuning) -> Bool {
        a.minLength == b.minLength && a.minSpeed == b.minSpeed && a.verticalCone == b.verticalCone
            && a.horizontalCone == b.horizontalCone && a.curveThreshold == b.curveThreshold
            && a.powerSpeed == b.powerSpeed && a.speedLow == b.speedLow && a.speedHigh == b.speedHigh
    }

    public var defaultShot: ShotCommand {
        ShotCommand(kind: .standard, brush: standard.brush, forward: standard.forward)
    }
}

/// Turns one completed touch path into a shot. The path is in screen
/// heights with y up.
public enum GestureInterpreter {

    public struct Sample: Equatable {
        public var t: Double, x: Double, y: Double
        public init(t: Double, x: Double, y: Double) { self.t = t; self.x = x; self.y = y }
    }

    /// - Parameter spinScale: scales spin brushes (Beginner simplifies spin).
    public static func interpret(_ path: [Sample], tuning: ShotTuning = ShotTuning(),
                                 spinScale: Double = 1) -> ShotCommand? {
        guard let first = path.first, let last = path.last else { return nil }
        let dx = last.x - first.x, dy = last.y - first.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length >= tuning.minLength else { return nil }
        // Speed: the faster of the whole-path average and the final 80 ms,
        // so a slow start followed by a flick still reads as a flick.
        let duration = max(last.t - first.t, 1.0 / 60.0)
        var speed = length / duration
        if let tail = path.last(where: { $0.t <= last.t - 0.08 }) ?? path.first, last.t - tail.t > 0.012 {
            let tx = last.x - tail.x, ty = last.y - tail.y
            speed = max(speed, (tx * tx + ty * ty).squareRoot() / (last.t - tail.t))
        }
        guard speed >= tuning.minSpeed else { return nil }
        let p = clamp((speed - tuning.speedLow) / (tuning.speedHigh - tuning.speedLow), 0, 1)
        func lerp(_ r: ClosedRange<Double>, _ f: Double) -> Double { r.lowerBound + (r.upperBound - r.lowerBound) * f }

        // Curvature: largest perpendicular distance from the chord.
        let ux = dx / length, uy = dy / length
        var bulge = 0.0
        for s in path {
            let rx = s.x - first.x, ry = s.y - first.y
            let d = rx * uy - ry * ux      // signed: > 0 bulges to the right of travel
            if abs(d) > abs(bulge) { bulge = d }
        }
        let curved = abs(bulge) / length >= tuning.curveThreshold && length >= tuning.minLength * 1.6

        let angleFromVertical = atan2(abs(dx), abs(dy)) * 180 / .pi
        let time = last.t
        if curved {
            // A brushing arc: sidespin. The ball curves the way the arc bows
            // out; placement follows the swipe's sideways travel only lightly.
            let dir: Double = bulge > 0 ? 1 : -1
            return ShotCommand(kind: .sidespin, placement: clamp(dx / length, -1, 1) * 0.35,
                               brush: tuning.standard.brush, sideBrush: dir * lerp(tuning.sideBrush, p) * spinScale,
                               forward: lerp(tuning.placementForward, p * 0.6), time: time)
        }
        if angleFromVertical <= tuning.verticalCone {
            if dy > 0 {
                let power = speed >= tuning.powerSpeed
                return ShotCommand(kind: power ? .powerTopspin : .topspin, placement: clamp(dx / length, -1, 1) * 0.5,
                                   brush: lerp(power ? tuning.powerBrush : tuning.topspinBrush, p) * spinScale,
                                   forward: lerp(power ? tuning.powerForward : tuning.topspinForward, p), time: time)
            }
            return ShotCommand(kind: .backspin, placement: clamp(dx / length, -1, 1) * 0.5,
                               brush: lerp(tuning.backspinBrush, 1 - p) * spinScale,
                               forward: lerp(tuning.backspinForward, p), time: time)
        }
        if 90 - angleFromVertical <= tuning.horizontalCone {
            // Straight sideways: placement only, no sidespin.
            return ShotCommand(kind: dx < 0 ? .left : .right, placement: dx < 0 ? -1 : 1,
                               brush: tuning.standard.brush, forward: lerp(tuning.placementForward, p), time: time)
        }
        // Diagonal: directional topspin / backspin.
        let place = (dx < 0 ? -1.0 : 1.0) * tuning.diagonalPlacement
        if dy > 0 {
            return ShotCommand(kind: .topspin, placement: place, brush: lerp(tuning.topspinBrush, p) * spinScale,
                               forward: lerp(tuning.topspinForward, p), time: time)
        }
        return ShotCommand(kind: .backspin, placement: place, brush: lerp(tuning.backspinBrush, 1 - p) * spinScale,
                           forward: lerp(tuning.backspinForward, p), time: time)
    }
}

/// Timing for buffered shots, measured from when the shot was selected to
/// the lock point just before contact. Timing changes shot quality; it never
/// decides whether the paddle touches the ball.
public struct ShotTimingWindows: Codable, Equatable {
    /// Selected within this many seconds before the lock: perfect.
    public var perfect: Double
    /// ...within this: good. Earlier than this: early.
    public var good: Double
    /// Seconds before contact at which the selected shot is locked.
    public var lock: Double

    public init(perfect: Double, good: Double, lock: Double) {
        self.perfect = perfect; self.good = good; self.lock = lock
    }

    /// - Parameter timeToContact: seconds from the gesture to the contact.
    public func classify(timeToContact: Double) -> StrokeTiming {
        let beforeLock = timeToContact - lock
        if beforeLock < 0 { return .late }
        if beforeLock <= perfect { return .perfect }
        if beforeLock <= good { return .good }
        return .early
    }
}

/// Holds the latest selected shot for the current incoming ball.
public struct ShotBuffer: Equatable {
    public private(set) var command: ShotCommand?
    public private(set) var timing: StrokeTiming?
    public private(set) var locked = false

    public init() {}

    /// Offer a new shot. Before the lock the latest shot replaces any earlier
    /// one. After the lock a shot is only taken (as late) when none was chosen.
    /// Returns true when the shot was accepted.
    @discardableResult
    public mutating func offer(_ cmd: ShotCommand, timing t: StrokeTiming) -> Bool {
        if locked {
            guard command == nil else { return false }
            command = cmd; timing = .late
            return true
        }
        command = cmd; timing = t
        return true
    }

    public mutating func lock() { locked = true }

    public mutating func clear() {
        command = nil; timing = nil; locked = false
    }
}

/// Why the player's paddle did not return the ball.
public enum MissReason: String, Codable, Equatable {
    /// The ball never came within the paddle's reach.
    case outOfReach
    /// The paddle could not get to the contact point in time (the ball was
    /// too fast or too wide for this level's tracking speed).
    case lateContact
}

/// Player-paddle diagnostics (developer overlay and logs).
public struct PaddleDiagnostics: Equatable {
    public var interceptPoint: Vec3?
    public var targetPosition: Vec3 = .zero
    public var actualPosition: Vec3 = .zero
    public var contactEligible = false
    public var reachable = false
    public var bufferedShot: ShotCommand?
    public var bufferedTiming: StrokeTiming?
    public var timeToContact: Double?
    public var lastShot: ShotCommand?
    public var lastTiming: StrokeTiming?
    public var lastMiss: MissReason?
    public init() {}
}
