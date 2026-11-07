import Foundation
@testable import SpinCore

/// Drives a `PlayerPaddleController` through the public touch-event API the
/// way a reasonable human would: put the finger where the ball will be and
/// swipe through it at the right moment. It only sees what is on screen
/// (ball state) and only produces touch events.
final class ScriptedTouchPlayer {
    let sim: GameSimulation
    var swipeVX: Double
    var swipeVY: Double
    var leadTime: Double
    private var touching = false
    private var screen = (x: 0.5, y: 0.25)
    private var swipeFramesLeft = 0
    private var lastEmit = -1.0
    private var tossedAt = -1.0
    private var swungForHit = -1.0
    private var u = 0.5, v = 0.3

    init(sim: GameSimulation, swipeVX: Double = 0, swipeVY: Double = 2.6, leadTime: Double = 0.11) {
        self.sim = sim; self.swipeVX = swipeVX; self.swipeVY = swipeVY; self.leadTime = leadTime
    }

    private func emit(_ phase: InputEvent.Phase) {
        sim.handleInput(phase: phase, u: u, v: v, screenX: screen.x, screenY: screen.y)
    }

    /// Call before each `sim.step()`.
    func tick() {
        let t = sim.time
        guard t - lastEmit >= 1.0 / 60.0 - 1e-9 else { return }
        lastEmit = t
        let reach = PaddleReach()
        func setPad(_ p: Vec3) {
            u = (p.x - reach.xRange.lowerBound) / (reach.xRange.upperBound - reach.xRange.lowerBound)
            v = (p.y - reach.yRange.lowerBound) / (reach.yRange.upperBound - reach.yRange.lowerBound)
        }
        if swipeFramesLeft > 0 {
            swipeFramesLeft -= 1
            screen.x += swipeVX / 60
            screen.y += swipeVY / 60
            emit(.moved)
            if swipeFramesLeft == 0 { emit(.ended); touching = false }
            return
        }
        let world = sim.world
        if sim.phase == .serving && sim.server == .near {
            // One-swipe serve: swipe while holding the ball; the controller
            // tosses and strikes on its own. Retry if the toss is re-held.
            if world.ballHeld && !touching && t - tossedAt > 0.8 {
                screen = (0.5, 0.25); u = 0.5; v = 0.25
                touching = true
                emit(.began)
                tossedAt = t
                startSwipe()
            }
            return
        }
        guard sim.phase == .rally, sim.referee.lastHitter == .far, sim.referee.lastHitter != nil else { return }
        guard let ic = InterceptPlanner.intercept(ball: world.ball, side: .near, config: sim.setup.physics,
                                                  preferredDepth: reach.defaultDepth - 0.05,
                                                  alreadyBounced: sim.referee.bouncedOnReceiver) else { return }
        setPad(ic.point)
        if !touching { touching = true; screen = (0.5, 0.3); emit(.began) } else { emit(.moved) }
        if ic.timeFromNow < leadTime && swungForHit != sim.referee.strokes.hashValue.double {
            swungForHit = sim.referee.strokes.hashValue.double
            startSwipe()
        }
    }

    private func startSwipe() {
        swipeFramesLeft = 6
    }
}

private extension Int { var double: Double { Double(self) } }
