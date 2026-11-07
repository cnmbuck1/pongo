import SceneKit
import SpinCore

/// Bridges SceneKit's render loop to the fixed-timestep simulation.
///
/// The render thread advances the simulation by the real elapsed time (the
/// simulation itself always steps in fixed 1/240 s ticks), then mirrors the
/// state into the scene. UI-thread access goes through `withSim`, guarded by
/// a lock.
final class SimulationHost: NSObject, SCNSceneRendererDelegate {

    let sim: GameSimulation
    let renderer: GameRenderer
    private let lock = NSLock()
    private var lastTime: TimeInterval?
    private var paused = false
    /// Simulation time of the player's last perfectly timed hit.
    private(set) var lastPerfectHitTime: Double = -1

    /// Delivered on the main thread.
    var onEvents: (([GameEvent]) -> Void)?

    init(sim: GameSimulation, renderer: GameRenderer) {
        self.sim = sim
        self.renderer = renderer
        super.init()
    }

    var isPaused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return paused }
        set { lock.lock(); paused = newValue; lock.unlock() }
    }

    @discardableResult
    func withSim<T>(_ body: (GameSimulation) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(sim)
    }

    func renderer(_ r: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let dt = lastTime.map { min(0.1, max(0, time - $0)) } ?? 0
        lastTime = time
        lock.lock()
        if !paused { sim.advance(by: dt) }
        let events = sim.drainEvents()
        for e in events {
            if case let .physics(p) = e, p.kind == .paddleHit {
                let speed = p.ballAfter.velocity.length
                if speed > 9 { renderer.powerShot(min(1, (speed - 9) / 6)) }
                let perfect = p.side == .near
                    && (sim.nearDriver as? PlayerPaddleController)?.strokeTiming == .perfect
                renderer.paddleImpact(side: p.side, power: min(1, speed / 14), perfect: perfect)
                if perfect { lastPerfectHitTime = p.time }
            }
        }
        renderer.update(sim: sim, frameDt: paused ? 0 : dt)
        lock.unlock()
        if !events.isEmpty, let handler = onEvents {
            DispatchQueue.main.async { handler(events) }
        }
    }
}
