import Foundation

/// Forward-simulates a free ball using the *same* physics as the live world
/// (aerodynamics, spin, table, net). The AI and the control assistance use
/// this; nothing here alters the real ball.
public enum TrajectoryPredictor {

    public struct Sample: Equatable {
        public var time: Double
        public var ball: BallState
    }

    public struct Prediction {
        public var samples: [Sample]
        public var events: [PhysicsEvent]

        /// First table bounce, if any.
        public var firstBounce: PhysicsEvent? { events.first { $0.kind == .tableBounce } }
    }

    public enum StopCondition {
        case duration
        case firstTableOrFloor
        case secondTableOrFloor
        case thirdTableOrFloor
    }

    public static func predict(from start: BallState,
                               config: PhysicsConfig,
                               duration: Double,
                               step: Double? = nil,
                               stop: StopCondition = .duration,
                               recordSamples: Bool = true) -> Prediction {
        var ball = start
        let dt = step ?? config.fixedTimestep
        var t = 0.0
        var samples: [Sample] = recordSamples ? [Sample(time: 0, ball: ball)] : []
        var events: [PhysicsEvent] = []
        var tableOrFloor = 0
        while t < duration {
            let before = events.count
            BallPhysics.advanceFree(&ball, dt: dt, config: config, time: t, events: &events)
            t += dt
            if recordSamples { samples.append(Sample(time: t, ball: ball)) }
            if events.count > before {
                for e in events[before...] where e.kind == .tableBounce || e.kind == .floorHit {
                    tableOrFloor += 1
                    if e.kind == .floorHit { tableOrFloor = 99 }
                }
                switch stop {
                case .duration: break
                case .firstTableOrFloor: if tableOrFloor >= 1 { return Prediction(samples: samples, events: events) }
                case .secondTableOrFloor: if tableOrFloor >= 2 { return Prediction(samples: samples, events: events) }
                case .thirdTableOrFloor: if tableOrFloor >= 3 { return Prediction(samples: samples, events: events) }
                }
            }
            if ball.position.y < -0.5 { break }
        }
        return Prediction(samples: samples, events: events)
    }
}
