import Foundation

/// A timestamped touch sample. The rendering/UI layer converts UIKit touches
/// into these; the simulation consumes them on its fixed timestep. Because
/// input is plain data it can be logged, replayed or sent over a network.
public struct InputEvent: Codable, Equatable {
    public enum Phase: String, Codable { case began, moved, ended, cancelled }

    public var phase: Phase
    /// Simulation time the event applies at.
    public var time: Double
    /// Paddle-control position normalised to the reachable region:
    /// u: 0 = far left, 1 = far right; v: 0 = lowest, 1 = highest.
    /// Already includes the touch-occlusion offset.
    public var u: Double
    public var v: Double
    /// Raw screen position in units of screen height (y up). Used for swipe
    /// velocity so swipe feel is independent of the control mapping.
    public var screenX: Double
    public var screenY: Double

    public init(phase: Phase, time: Double, u: Double, v: Double, screenX: Double, screenY: Double) {
        self.phase = phase; self.time = time; self.u = u; self.v = v
        self.screenX = screenX; self.screenY = screenY
    }
}

/// Control assistance. Assistance can improve positioning, timing tolerance
/// and blade angle, but never guarantees a return: the shot still comes from
/// paddle velocity and the collision physics, and a mistimed or badly placed
/// paddle still misses.
public enum AssistLevel: String, Codable, CaseIterable {
    case beginner, standard, expert

    public var displayName: String {
        switch self {
        case .beginner: return "Beginner"
        case .standard: return "Standard"
        case .expert: return "Expert"
        }
    }

    /// 0...1 blend from the natural blade angle toward the solved blade angle.
    public var aimAssist: Double {
        switch self { case .beginner: return 0.95; case .standard: return 0.86; case .expert: return 0.62 }
    }
    /// 0...1 pull of paddle x/y toward the predicted ball path.
    public var positionAssist: Double {
        switch self { case .beginner: return 0.6; case .standard: return 0.32; case .expert: return 0.08 }
    }
    /// How long (s) a swipe stays "live" for contact.
    public var timingWindow: Double {
        switch self { case .beginner: return 0.30; case .standard: return 0.20; case .expert: return 0.12 }
    }
    /// Extra hit radius on the blade (m).
    public var extraHitRadius: Double {
        switch self { case .beginner: return 0.035; case .standard: return 0.018; case .expert: return 0.006 }
    }
}

/// How touches drive the paddle.
public enum ControlScheme: String, Codable, CaseIterable {
    /// One finger does everything: the paddle follows the finger and the
    /// finger's swipe speed/direction becomes the stroke.
    case swipe
    /// Slow drag positions the paddle; a short quick flick strikes. The paddle
    /// holds position during the flick so aiming and striking don't fight.
    case dragAndFlick

    public var displayName: String {
        switch self { case .swipe: return "One-finger swipe"; case .dragAndFlick: return "Drag + flick" }
    }
}

public struct ControlSettings: Codable, Equatable {
    public var scheme: ControlScheme = .swipe
    public var assist: AssistLevel = .standard
    /// Vertical offset between finger and paddle, in screen heights, so the
    /// finger doesn't cover the incoming ball (applied by the UI layer).
    public var touchOffset: Double = 0.09
    /// Multiplies swipe-to-paddle speed.
    public var swipeSensitivity: Double = 1.0

    public init() {}
}
