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
        switch self { case .beginner: return 0.96; case .standard: return 0.92; case .expert: return 0.72 }
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

    // MARK: Auto paddle (Build 2 control scheme)

    /// Top tracking speed (m/s) of the auto-positioned paddle.
    public var trackSpeed: Double {
        switch self { case .beginner: return 4.6; case .standard: return 3.8; case .expert: return 3.1 }
    }
    /// Tracking acceleration limit (m/s²).
    public var trackAcceleration: Double {
        switch self { case .beginner: return 32; case .standard: return 24; case .expert: return 17 }
    }
    /// Delay (s) after the opponent's hit before the paddle starts tracking.
    public var reactionDelay: Double {
        switch self { case .beginner: return 0.06; case .standard: return 0.12; case .expert: return 0.18 }
    }
    /// Stroke timing windows (s), measured from the ideal swipe moment.
    public var timing: TimingWindows {
        switch self {
        case .beginner: return TimingWindows(perfect: 0.07, good: 0.17, accept: 0.36)
        case .standard: return TimingWindows(perfect: 0.045, good: 0.11, accept: 0.24)
        case .expert: return TimingWindows(perfect: 0.025, good: 0.07, accept: 0.15)
        }
    }
}

/// How far from the ideal moment a swipe may be and still count.
public struct TimingWindows: Codable, Equatable {
    public var perfect: Double
    public var good: Double
    /// Beyond this a swipe is ignored (no stroke).
    public var accept: Double
    public init(perfect: Double, good: Double, accept: Double) {
        self.perfect = perfect; self.good = good; self.accept = accept
    }
    public func classify(_ delta: Double) -> StrokeTiming? {
        let a = abs(delta)
        if a <= perfect { return .perfect }
        if a <= good { return .good }
        if a <= accept { return delta > 0 ? .early : .late }
        return nil
    }
}

/// Timing quality of a stroke.
public enum StrokeTiming: String, Codable, Equatable {
    case perfect, good, early, late

    /// Multiplies the blade-angle assistance.
    public var accuracy: Double {
        switch self { case .perfect: return 1.0; case .good: return 0.85; case .early, .late: return 0.45 }
    }
    /// Multiplies stroke speed.
    public var power: Double {
        switch self { case .perfect: return 1.05; case .good: return 1.0; case .early, .late: return 0.8 }
    }
    /// Blade turn (rad) from hitting the ball early (in front) or late.
    public var yawError: Double {
        switch self { case .early: return 0.10; case .late: return -0.10; default: return 0 }
    }
}

/// How a swipe becomes a stroke. Vertical motion mainly makes topspin or
/// backspin, horizontal motion mainly places the ball left or right and adds
/// some sidespin, and swipe speed sets power. Placement and sidespin have
/// separate weights so later builds can decouple them.
public struct StrokeMapping: Codable, Equatable {
    /// Forward speed (m/s) at zero swipe speed, and added per screen-height/s.
    public var basePower = 1.0
    public var powerPerSpeed = 1.5
    public var maxForward = 9.0
    /// Brush speed (m/s) per screen-height/s of vertical swipe (topspin/backspin).
    public var verticalBrush = 0.95
    /// Brush speed (m/s) per screen-height/s of horizontal swipe (sidespin).
    public var lateralBrush = 0.55
    /// How far (m) a fully horizontal swipe moves the aim point across the
    /// opponent's half.
    public var lateralPlacement = 0.5
    public init() {}
}

/// How touches drive the paddle.
public enum ControlScheme: String, Codable, CaseIterable {
    /// Build 2 default: the paddle positions itself on the predicted ball
    /// path (with speed, reach and reaction limits); the player only swipes
    /// to strike, anywhere on the screen.
    case autoTrack
    /// One finger does everything: the paddle follows the finger and the
    /// finger's swipe speed/direction becomes the stroke.
    case swipe
    /// Slow drag positions the paddle; a short quick flick strikes. The paddle
    /// holds position during the flick so aiming and striking don't fight.
    case dragAndFlick

    public var displayName: String {
        switch self {
        case .autoTrack: return "Auto paddle"
        case .swipe: return "Finger paddle"
        case .dragAndFlick: return "Drag + flick"
        }
    }
}

public struct ControlSettings: Codable, Equatable {
    public var scheme: ControlScheme = .autoTrack
    public var mapping = StrokeMapping()
    public var assist: AssistLevel = .standard
    /// Vertical offset between finger and paddle, in screen heights, so the
    /// finger doesn't cover the incoming ball (applied by the UI layer).
    public var touchOffset: Double = 0.09
    /// Multiplies swipe-to-paddle speed.
    public var swipeSensitivity: Double = 1.0

    public init() {}
}
