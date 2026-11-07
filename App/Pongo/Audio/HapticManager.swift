import UIKit

/// Light haptic on contact, stronger on power shots, subtle on points.
/// Rate limited so long rallies don't buzz constantly.
final class HapticManager {
    static let shared = HapticManager()

    var enabled = true

    private let light = UIImpactFeedbackGenerator(style: .light)
    private let heavy = UIImpactFeedbackGenerator(style: .rigid)
    private let notify = UINotificationFeedbackGenerator()
    private var lastFire: CFTimeInterval = 0
    private let minInterval: CFTimeInterval = 0.09

    private init() {
        light.prepare(); heavy.prepare(); notify.prepare()
    }

    private func allowed() -> Bool {
        let now = CACurrentMediaTime()
        guard enabled, now - lastFire >= minInterval else { return false }
        lastFire = now
        return true
    }

    func paddleContact(power: Double) {
        guard allowed() else { return }
        if power > 0.7 {
            heavy.impactOccurred(intensity: CGFloat(min(1, 0.6 + power * 0.4)))
        } else {
            light.impactOccurred(intensity: CGFloat(0.4 + power * 0.5))
        }
    }

    func point(won: Bool) {
        guard allowed() else { return }
        if won { notify.notificationOccurred(.success) } else { light.impactOccurred(intensity: 0.5) }
    }
}
