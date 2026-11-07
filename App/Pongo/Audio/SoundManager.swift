import AVFoundation

/// Procedurally synthesised sound effects (no bundled audio assets).
/// Impact sounds come in soft / medium / hard variants and are played at a
/// volume scaled by impact strength, so they vary with how hard the ball hits.
final class SoundManager {
    static let shared = SoundManager()

    enum Effect: CaseIterable {
        case paddle, perfect, table, net, point, victory, defeat, menu
    }

    var enabled = true

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var nextPlayer = 0
    private var buffers: [Effect: [AVAudioPCMBuffer]] = [:]
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var prepared = false

    private init() {}

    func prepare() {
        guard !prepared else { return }
        prepared = true
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        for _ in 0..<8 {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: format)
            players.append(p)
        }
        buildBuffers()
        do { try engine.start() } catch { prepared = false }
        players.forEach { $0.play() }
    }

    /// - Parameter strength: 0...1
    func play(_ effect: Effect, strength: Double = 0.6) {
        guard enabled, prepared, let variants = buffers[effect], !variants.isEmpty else { return }
        if !engine.isRunning { try? engine.start(); players.forEach { $0.play() } }
        let s = max(0, min(1, strength))
        let idx = variants.count == 1 ? 0 : min(variants.count - 1, Int(s * Double(variants.count)))
        let player = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        player.volume = Float(0.25 + 0.75 * s)
        player.scheduleBuffer(variants[idx], at: nil, options: [], completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    // MARK: Synthesis

    private func makeBuffer(duration: Double, _ sample: (Double) -> Double) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(duration * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            let t = Double(i) / format.sampleRate
            data[i] = Float(max(-1, min(1, sample(t))))
        }
        return buffer
    }

    private func buildBuffers() {
        var seed: UInt32 = 12345
        func noise() -> Double {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Double(seed) / Double(UInt32.max) * 2 - 1
        }
        func tone(_ f: Double, _ t: Double) -> Double { sin(2 * .pi * f * t) }

        // Paddle: bright click + woody body. Harder hits are brighter.
        buffers[.paddle] = [0.0, 0.5, 1.0].map { k in
            makeBuffer(duration: 0.07) { t in
                let env = exp(-t * (70 + 40 * k))
                return env * (0.55 * tone(1500 + 900 * k, t) + 0.35 * tone(520 + 120 * k, t) + 0.25 * noise() * exp(-t * 300))
            }
        }
        // Perfectly timed stroke: the paddle crack plus a short bright shimmer.
        buffers[.perfect] = [makeBuffer(duration: 0.22) { t in
            let crack = exp(-t * 90) * (0.5 * tone(2300, t) + 0.3 * tone(620, t))
            let shimmer = 0.22 * exp(-t * 14) * (tone(1760, t) + 0.6 * tone(2637, t)) * min(1, t * 200)
            return crack + shimmer
        }]
        // Table: hollow "tok".
        buffers[.table] = [0.0, 0.5, 1.0].map { k in
            makeBuffer(duration: 0.09) { t in
                let env = exp(-t * (55 + 25 * k))
                return env * (0.6 * tone(980 + 260 * k, t) + 0.35 * tone(240, t) + 0.15 * noise() * exp(-t * 400))
            }
        }
        // Net: soft rustle.
        var lp = 0.0
        buffers[.net] = [makeBuffer(duration: 0.12) { t in
            lp += (noise() - lp) * 0.08
            return 0.9 * lp * exp(-t * 30)
        }]
        // Point: two-tone chime.
        buffers[.point] = [makeBuffer(duration: 0.35) { t in
            let f = t < 0.12 ? 880.0 : 1318.5
            return 0.35 * tone(f, t) * exp(-(t.truncatingRemainder(dividingBy: 0.12)) * 9) * exp(-t * 3)
        }]
        // Victory: rising arpeggio.
        buffers[.victory] = [makeBuffer(duration: 1.0) { t in
            let notes = [523.25, 659.25, 783.99, 1046.5]
            let i = min(3, Int(t / 0.16))
            let local = t - Double(i) * 0.16
            return 0.3 * (tone(notes[i], t) + 0.4 * tone(notes[i] * 2, t)) * exp(-local * 4) * (i == 3 ? exp(-local * 1.5) : 1)
        }]
        // Defeat: falling minor figure.
        buffers[.defeat] = [makeBuffer(duration: 0.9) { t in
            let notes = [659.25, 587.33, 523.25, 440.0]
            let i = min(3, Int(t / 0.18))
            let local = t - Double(i) * 0.18
            return 0.28 * tone(notes[i], t) * exp(-local * 5)
        }]
        // Menu selection tick.
        buffers[.menu] = [makeBuffer(duration: 0.04) { t in
            0.4 * tone(2400, t) * exp(-t * 120)
        }]
    }
}
