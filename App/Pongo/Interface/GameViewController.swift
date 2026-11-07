import UIKit
import SceneKit
import SpinCore

/// Gameplay screen: 3D scene, touch input, HUD, pause and results.
final class GameViewController: UIViewController {

    private let mode: GameMode
    private var settings: AppSettings
    private let scnView = SCNView()
    private let host: SimulationHost

    // HUD
    // Scoreboard: YOU 01 | GAME 1 | CPU 07, games won in small type.
    private let playerScore = makeLabel("00", size: 24, weight: .heavy, color: Palette.cyan)
    private let opponentScore = makeLabel("00", size: 24, weight: .heavy, color: Palette.violet)
    private let playerName = makeLabel("YOU", size: 11, weight: .bold, color: Palette.cyan, kern: 1.5)
    private let opponentName = makeLabel("CPU", size: 11, weight: .bold, color: Palette.violet, kern: 1.5)
    private let gameLabel = makeLabel("GAME 1", size: 12, weight: .heavy, color: Palette.white, kern: 3)
    private let gamesLabel = makeLabel("GAMES 0–0", size: 9, weight: .semibold, color: Palette.textDim, kern: 1)
    private let playerServe = UIView()
    private let opponentServe = UIView()
    private let callout = makeLabel("", size: 30, weight: .heavy, kern: 4)
    private let hint = makeLabel("", size: 14, weight: .semibold, color: Palette.textDim)
    private let spinIndicator = SpinIndicatorView()
    private let contactReadout = makeLabel("", size: 12, weight: .semibold, color: Palette.cyan)
    private let pauseButton = UIButton(type: .system)
    private var overlay: UIView?
    private var hudTimer: CADisplayLink?
    // Short animated tutorial (Build 2): TAP TO TOSS → SWIPE TO SERVE, and
    // SWIPE TO HIT on the first incoming ball. Gone after the first serve /
    // first return; Training always shows the hitting prompt again.
    private let tutorial = makeLabel("", size: 22, weight: .heavy, color: Palette.cyan, kern: 4)
    private var tutorialText = ""
    private var serveTutorialActive = false
    private var hitTutorialActive = false
    private var lastTiming: StrokeTiming?
    // Selected-shot feedback (Build 3): a small label naming the buffered
    // shot, then the executed shot and its timing for a moment after contact.
    private let shotLabel = makeLabel("", size: 14, weight: .heavy, color: Palette.white, kern: 3)
    private var shotFeedbackUntil: CFTimeInterval = 0
    // Developer diagnostics (launch argument -PongoDebug only).
    private let debugEnabled = ProcessInfo.processInfo.arguments.contains("-PongoDebug")
    private let debugLabel = UILabel()
    private let debugLog = DebugLog()

    // Training module scoring.
    private let module: TrainingModule?
    private var attempts = 0
    private var successes = 0
    private var pendingAttempt: SpinReading?
    private var promptsLeft = 3

    // Touch tracking (single finger).
    private weak var activeTouch: UITouch?

    /// `demo` (screenshot automation only) lets an AI play the near side too.
    init(mode: GameMode, settings: AppSettings, module: TrainingModule? = nil, demo: Bool = false) {
        self.mode = mode
        self.module = mode == .training ? (module ?? .basicReturns) : nil
        self.settings = settings
        var setup = GameSetup()
        setup.mode = mode
        setup.difficulty = mode == .training ? .beginner : settings.difficulty
        setup.controls = settings.gameControls
        setup.seed = UInt64(Date().timeIntervalSince1970)
        let sim = demo
            ? GameSimulation(setup: setup,
                             near: AIOpponentController(side: .near, profile: .intermediate, seed: setup.seed),
                             far: AIOpponentController(side: .far, profile: .intermediate, seed: setup.seed &+ 1))
            : GameSimulation(setup: setup)
        let renderer = GameRenderer(table: setup.physics.table, physics: setup.physics, skin: settings.ballSkin)
        renderer.trainingVisuals = mode == .training && settings.trainingOverlays
        renderer.motionEffects = settings.motionEffects
        host = SimulationHost(sim: sim, renderer: renderer)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.midnight
        view.isMultipleTouchEnabled = false
        scnView.translatesAutoresizingMaskIntoConstraints = false
        scnView.scene = host.renderer.scene
        scnView.pointOfView = host.renderer.cameraNode
        scnView.delegate = host
        scnView.preferredFramesPerSecond = 60
        scnView.antialiasingMode = .multisampling2X
        scnView.isPlaying = true
        scnView.isUserInteractionEnabled = false   // touches handled by this controller
        view.addSubview(scnView)
        pin(scnView)
        buildHUD()
        host.onEvents = { [weak self] events in self?.handle(events) }
        refreshTrainingTarget()
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResign), name: .pongoShouldPause, object: nil)
        refreshHUD()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
        let link = CADisplayLink(target: self, selector: #selector(hudTick))
        link.preferredFramesPerSecond = 20
        link.add(to: .main, forMode: .common)
        hudTimer = link
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        hudTimer?.invalidate()
        hudTimer = nil
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
    }

    private func pin(_ v: UIView) {
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: view.topAnchor),
            v.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    // MARK: HUD

    private func buildHUD() {
        for dot in [playerServe, opponentServe] {
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.layer.cornerRadius = 4
            dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        }
        playerServe.backgroundColor = Palette.cyan
        opponentServe.backgroundColor = Palette.violet

        func row(_ views: [UIView]) -> UIStackView {
            let s = UIStackView(arrangedSubviews: views)
            s.axis = .horizontal
            s.spacing = 6
            s.alignment = .center
            return s
        }
        let left = row([playerServe, playerName, playerScore])
        let right = row([opponentScore, opponentName, opponentServe])
        let middle = UIStackView(arrangedSubviews: [gameLabel, gamesLabel])
        middle.axis = .vertical
        middle.alignment = .center
        middle.spacing = 1
        let bar = UIStackView(arrangedSubviews: [left, middle, right])
        bar.axis = .horizontal
        bar.distribution = .fill
        bar.spacing = 8
        bar.alignment = .center
        // Scores and names never truncate; the middle column shrinks instead
        // (narrow iPhones and Display Zoom).
        for v in [playerScore, opponentScore, playerName, opponentName, playerServe, opponentServe] {
            v.setContentCompressionResistancePriority(.required, for: .horizontal)
            v.setContentHuggingPriority(.required, for: .horizontal)
        }
        for l in [gameLabel, gamesLabel] {
            l.adjustsFontSizeToFitWidth = true
            l.minimumScaleFactor = 0.55
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        middle.setContentHuggingPriority(.defaultLow, for: .horizontal)
        middle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        left.spacing = 5
        right.spacing = 5
        bar.translatesAutoresizingMaskIntoConstraints = false

        let barBG = UIView()
        barBG.translatesAutoresizingMaskIntoConstraints = false
        barBG.backgroundColor = UIColor(red: 0.02, green: 0.04, blue: 0.10, alpha: 0.82)
        barBG.layer.cornerRadius = 18
        barBG.layer.borderWidth = 1
        barBG.layer.borderColor = Palette.cyan.withAlphaComponent(0.25).cgColor
        barBG.isUserInteractionEnabled = false
        view.addSubview(barBG)
        view.addSubview(bar)

        pauseButton.translatesAutoresizingMaskIntoConstraints = false
        pauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        pauseButton.tintColor = Palette.white
        pauseButton.backgroundColor = UIColor(white: 1, alpha: 0.08)
        pauseButton.layer.cornerRadius = 20
        pauseButton.addTarget(self, action: #selector(pauseTapped), for: .touchUpInside)
        view.addSubview(pauseButton)

        callout.alpha = 0
        callout.adjustsFontSizeToFitWidth = true
        callout.minimumScaleFactor = 0.5
        callout.layer.shadowColor = Palette.cyan.cgColor
        callout.layer.shadowRadius = 12
        callout.layer.shadowOpacity = 0.8
        callout.layer.shadowOffset = .zero
        hint.numberOfLines = 0
        [callout, hint, contactReadout, tutorial, shotLabel].forEach { view.addSubview($0) }
        shotLabel.alpha = 0
        shotLabel.isUserInteractionEnabled = false
        if debugEnabled {
            debugLabel.translatesAutoresizingMaskIntoConstraints = false
            debugLabel.numberOfLines = 0
            debugLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
            debugLabel.textColor = UIColor(white: 1, alpha: 0.9)
            debugLabel.backgroundColor = UIColor(white: 0, alpha: 0.55)
            debugLabel.isUserInteractionEnabled = false
            view.addSubview(debugLabel)
            NSLayoutConstraint.activate([
                debugLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 6),
                debugLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -6),
                debugLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 120)
            ])
            let log = debugLog
            host.withSim { $0.player?.eventLog = { log.append($0) } }
            host.renderer.debugVisuals = true
        }
        tutorial.layer.shadowColor = Palette.cyan.cgColor
        tutorial.layer.shadowRadius = 10
        tutorial.layer.shadowOpacity = 0.7
        tutorial.layer.shadowOffset = .zero
        tutorial.isUserInteractionEnabled = false
        serveTutorialActive = !settings.serveTutorialDone && mode == .match
        hitTutorialActive = !settings.serveTutorialDone || mode == .training
        spinIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinIndicator)
        spinIndicator.isHidden = !(settings.showSpinIndicator || mode == .training)
        contactReadout.numberOfLines = 2
        contactReadout.isHidden = !(mode == .training && settings.trainingOverlays)

        if mode == .training {
            playerScore.isHidden = true; opponentScore.isHidden = true
            playerServe.isHidden = true; opponentServe.isHidden = true
            gamesLabel.text = "0 / 0"
            gameLabel.text = (module?.title ?? "Training").uppercased()
            opponentName.text = "FEEDER"
        }

        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: g.topAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 26),
            bar.trailingAnchor.constraint(equalTo: pauseButton.leadingAnchor, constant: -22),
            barBG.topAnchor.constraint(equalTo: bar.topAnchor, constant: -6),
            barBG.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
            barBG.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: -18),
            barBG.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 18),
            pauseButton.centerYAnchor.constraint(equalTo: barBG.centerYAnchor),
            pauseButton.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            pauseButton.widthAnchor.constraint(equalToConstant: 40),
            pauseButton.heightAnchor.constraint(equalToConstant: 40),
            callout.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            callout.topAnchor.constraint(equalTo: barBG.bottomAnchor, constant: 40),
            callout.leadingAnchor.constraint(greaterThanOrEqualTo: g.leadingAnchor, constant: 16),
            callout.trailingAnchor.constraint(lessThanOrEqualTo: g.trailingAnchor, constant: -16),
            tutorial.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            tutorial.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -70),
            shotLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shotLabel.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -112),
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -28),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: g.leadingAnchor, constant: 24),
            spinIndicator.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 18),
            spinIndicator.topAnchor.constraint(equalTo: barBG.bottomAnchor, constant: 18),
            contactReadout.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            contactReadout.topAnchor.constraint(equalTo: barBG.bottomAnchor, constant: 20)
        ])
    }

    private func refreshHUD() {
        let (snap, server, phase, contact, returns) = host.withSim { sim in
            (sim.score, sim.server, sim.phase, sim.lastContact, sim.stats.successfulReturns)
        }
        if mode == .match {
            playerScore.text = String(format: "%02d", snap.points(.near))
            opponentScore.text = String(format: "%02d", snap.points(.far))
            gameLabel.text = "GAME \(snap.gameNumber)"
            gamesLabel.text = "GAMES \(snap.games(.near))–\(snap.games(.far))"
            playerServe.alpha = server == .near ? 1 : 0.12
            opponentServe.alpha = server == .far ? 1 : 0.12
        } else {
            _ = returns
            gamesLabel.text = "\(successes) / \(attempts)"
        }
        _ = phase; _ = server
        if mode == .training, module == nil, settings.trainingOverlays, let c = contact {
            let who = c.side == .near ? "YOU" : "FEEDER"
            let timing = c.side == .near ? (lastTiming?.rawValue.uppercased() ?? "") : ""
            contactReadout.numberOfLines = 3
            contactReadout.text = String(format: "%@  %.1f m/s\n%@  %.0f rpm\n%@", who, c.ballSpeed,
                                         c.spin.label.uppercased(), c.spin.revolutionsPerSecond * 60, timing)
        }
    }

    private func updateTutorial() {
        guard serveTutorialActive || hitTutorialActive else {
            if !tutorialText.isEmpty { setTutorial("") }
            return
        }
        let (phase, server, held, incoming) = host.withSim { sim in
            (sim.phase, sim.server, sim.world.ballHeld,
             sim.referee.lastHitter == .far && sim.phase == .rally)
        }
        var text = ""
        if serveTutorialActive && phase == .serving && server == .near {
            if settings.gameControls.assist == .beginner {
                text = held ? "TAP TO SERVE" : ""
            } else {
                text = held ? "TAP TO TOSS" : "SWIPE TO SERVE"
            }
        } else if hitTutorialActive && incoming {
            text = module?.prompt ?? "SWIPE TO PICK A SHOT"
        }
        if text != tutorialText { setTutorial(text) }
    }

    private func setTutorial(_ text: String) {
        tutorialText = text
        tutorial.layer.removeAllAnimations()
        tutorial.attributedText = NSAttributedString(string: text, attributes: [
            .kern: 4, .font: tutorial.font!, .foregroundColor: Palette.cyan])
        guard !text.isEmpty else { return }
        tutorial.alpha = 1
        tutorial.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        UIView.animate(withDuration: 0.55, delay: 0, options: [.autoreverse, .repeat, .allowUserInteraction, .curveEaseInOut]) {
            self.tutorial.alpha = 0.45
            self.tutorial.transform = .identity
        }
    }

    @objc private func hudTick() {
        updateTutorial()
        updateShotLabel()
        if debugEnabled { updateDebug() }
        guard spinIndicator.isHidden == false else { return }
        let reading: SpinReading? = host.withSim { sim in
            sim.world.ballHeld ? nil : SpinReading(ball: sim.world.ball)
        }
        spinIndicator.show(reading)
    }

    private func updateShotLabel() {
        guard CACurrentMediaTime() > shotFeedbackUntil else { return }
        let buffered = host.withSim { $0.player?.buffer.command }
        if let b = buffered {
            setShotLabel(b.label, color: Palette.cyan, alpha: 0.9)
        } else if shotLabel.alpha > 0 {
            UIView.animate(withDuration: 0.25) { self.shotLabel.alpha = 0 }
        }
    }

    private func setShotLabel(_ text: String, color: UIColor, alpha: CGFloat) {
        if shotLabel.text != text {
            shotLabel.attributedText = NSAttributedString(string: text, attributes: [
                .kern: 3, .font: shotLabel.font!, .foregroundColor: color])
        }
        shotLabel.alpha = alpha
    }

    private func updateDebug() {
        let text: String = host.withSim { sim in
            guard let p = sim.player else { return "" }
            let d = p.diagnostics
            let b = sim.world.ball
            func v(_ x: Vec3?) -> String { x.map { String(format: "%5.2f %5.2f %5.2f", $0.x, $0.y, $0.z) } ?? "-" }
            let spin = SpinReading(ball: b)
            return [
                "ball v   " + v(b.velocity) + String(format: "  |%.1f|", b.velocity.length),
                "spin     " + String(format: "top %.0f side %.0f rpm", spin.topspin * 60 / (2 * .pi), spin.sidespin * 60 / (2 * .pi)),
                "icept    " + v(d.interceptPoint) + (d.reachable ? "  reach" : "  -"),
                "target   " + v(d.targetPosition),
                "paddle   " + v(d.actualPosition),
                "eligible \(d.contactEligible)  ttc " + (d.timeToContact.map { String(format: "%.2f", $0) } ?? "-"),
                "buffer   \(d.bufferedShot?.label ?? "-") \(d.bufferedTiming?.rawValue ?? "")",
                "last     \(d.lastShot?.label ?? "-") \(d.lastTiming?.rawValue ?? "")  miss \(d.lastMiss?.rawValue ?? "-")"
            ].joined(separator: "\n")
        }
        debugLabel.text = text + "\n" + debugLog.tail(6).joined(separator: "\n")
    }

    private func flash(_ text: String, color: UIColor = Palette.white) {
        callout.text = text
        callout.textColor = color
        callout.layer.removeAllAnimations()
        callout.alpha = 0
        callout.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
        UIView.animate(withDuration: 0.18, animations: {
            self.callout.alpha = 1
            self.callout.transform = .identity
        }, completion: { _ in
            UIView.animate(withDuration: 0.4, delay: 0.7, options: [], animations: { self.callout.alpha = 0 })
        })
    }

    // MARK: Events → audio / haptics / HUD

    private func handle(_ events: [GameEvent]) {
        let decided = events.contains { e in
            if case .gameWon = e { return true }
            if case .matchWon = e { return true }
            return false
        }
        for e in events {
            switch e {
            case let .physics(p):
                let strength = min(1, p.impactSpeed / 12)
                switch p.kind {
                case .paddleHit:
                    let timing = p.side == .near
                        ? host.withSim { ($0.nearDriver as? PlayerPaddleController)?.strokeTiming } : nil
                    SoundManager.shared.play(timing == .perfect ? .perfect : .paddle, strength: strength)
                    if p.side == .near {
                        lastTiming = timing
                        let executed = host.withSim { sim -> String? in
                            guard let pl = sim.player, sim.referee.strokes > 1 else { return nil }
                            return pl.diagnostics.lastShot?.label
                        }
                        if let shot = executed {
                            let t = timing.map { " · " + $0.rawValue.uppercased() } ?? ""
                            setShotLabel(shot + t, color: timing == .perfect ? Palette.cyan : Palette.white, alpha: 1)
                            shotFeedbackUntil = CACurrentMediaTime() + 0.8
                        }
                        let power = min(1, p.ballAfter.velocity.length / 14)
                        HapticManager.shared.paddleContact(power: power)
                        let strokes = host.withSim { $0.referee.strokes }
                        if strokes == 1, serveTutorialActive {
                            serveTutorialActive = false
                            settings.serveTutorialDone = true
                            var saved = AppSettings.load()
                            saved.serveTutorialDone = true
                            saved.save()
                        } else if strokes > 1 {
                            if let m = module {
                                promptsLeft -= 1
                                if promptsLeft <= 0 { hitTutorialActive = false }
                                pendingAttempt = SpinReading(ball: p.ballAfter)
                                _ = m
                            } else {
                                hitTutorialActive = false
                            }
                        }
                    }
                case .tableBounce:
                    SoundManager.shared.play(.table, strength: strength)
                    if p.side == .far, let spin = pendingAttempt { finishAttempt(spin: spin, landing: p.point) }
                case .netTouch: SoundManager.shared.play(.net, strength: strength)
                case .floorHit: SoundManager.shared.play(.table, strength: strength * 0.4)
                }
            case let .point(winner, reason):
                SoundManager.shared.play(.point, strength: 0.7)
                HapticManager.shared.point(won: winner == .near)
                if mode == .training {
                    if let spin = pendingAttempt {
                        finishAttempt(spin: spin, landing: nil)
                    } else if winner == .far {
                        attempts += 1
                        flash(missDescription(reason), color: Palette.white)
                        refreshTrainingTarget()
                    }
                } else {
                    flash(winner == .near ? "POINT" : missDescription(reason), color: winner == .near ? Palette.cyan : Palette.violet)
                    if !decided, let call = scoreCall() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                            self?.flash(call.text, color: call.color)
                        }
                    }
                }
            case .letCalled:
                flash("LET")
            case let .gameWon(by, game):
                flash(by == .near ? "GAME \(game) – YOU" : "GAME \(game) – CPU", color: by == .near ? Palette.cyan : Palette.violet)
            case let .matchWon(by):
                SoundManager.shared.play(by == .near ? .victory : .defeat)
                flash(by == .near ? "GAME, SET, MATCH – YOU" : "GAME, SET, MATCH – CPU",
                      color: by == .near ? Palette.cyan : Palette.violet)
            case let .phaseChanged(p):
                if p == .ready, mode == .match {
                    let n = host.withSim { $0.score.gameNumber }
                    flash("GAME \(n)")
                }
                if p == .matchEnded { showResults() }
            case .serveTossed:
                break
            }
        }
        refreshHUD()
    }

    private func finishAttempt(spin: SpinReading, landing: Vec3?) {
        guard let m = module else { return }
        pendingAttempt = nil
        let ok = m.success(spin: spin, landing: landing, attempt: attempts)
        attempts += 1
        if ok { successes += 1 }
        flash(ok ? "NICE" : "TRY AGAIN", color: ok ? Palette.cyan : Palette.white)
        if settings.trainingOverlays {
            let timing = lastTiming?.rawValue.uppercased() ?? ""
            contactReadout.numberOfLines = 4
            contactReadout.text = String(format: "%@  %@\n%.0f rpm\n%@", spin.label.uppercased(), timing,
                                         spin.revolutionsPerSecond * 60, TrainingModule.describe(landing: landing))
        }
        refreshTrainingTarget()
        refreshHUD()
    }

    private func refreshTrainingTarget() {
        host.withSim { _ in host.renderer.showTarget(module?.target(attempt: attempts), radius: TrainingModule.targetRadius) }
    }

    /// Umpire calls after a point: DEUCE at 10–10 (and every tie after),
    /// GAME POINT / MATCH POINT when a side is one point from winning.
    private func scoreCall() -> (text: String, color: UIColor)? {
        let score = host.withSim { $0.score }
        guard score.matchWinner == nil else { return nil }
        let f = score.format
        let n = score.points(.near), c = score.points(.far)
        if score.isDeuce && n == c { return ("DEUCE", Palette.white) }
        for side in [Side.near, .far] {
            let me = score.points(side), them = score.points(side.opponent)
            guard me >= f.pointsToWinGame - 1, me - them >= f.winByMargin - 1, me > them else { continue }
            let match = score.games(side) == f.gamesToWinMatch - 1
            let who = side == .near ? "" : " – CPU"
            return ((match ? "MATCH POINT" : "GAME POINT") + who, side == .near ? Palette.cyan : Palette.violet)
        }
        return nil
    }

    /// Why the player lost the point: the paddle's own reason when the ball
    /// got past it (out of reach / too fast), otherwise the rules reason.
    private func missDescription(_ r: PointReason) -> String {
        let (miss, lastHitter) = host.withSim { ($0.player?.diagnostics.lastMiss, $0.referee.lastHitter) }
        if lastHitter == .far, let m = miss {
            switch m {
            case .outOfReach: return "OUT OF REACH"
            case .lateContact: return settings.gameControls.assist == .beginner ? "TOO FAST" : "LATE"
            }
        }
        return describe(r)
    }

    private func describe(_ r: PointReason) -> String {
        switch r {
        case .serveMissedOwnHalf, .serveMissedReceiverHalf, .serveFault: return "FAULT"
        case .doubleBounce, .notReturned: return "MISSED"
        case .missedTable: return "OUT"
        case .hitOwnHalf: return "OWN HALF"
        case .volley: return "NO BOUNCE"
        case .doubleHit: return "DOUBLE HIT"
        case .netNoReturn: return "NET"
        }
    }

    // MARK: Touch input

    /// Converts a touch to simulation input. The paddle is drawn where the
    /// finger points, raised by the touch offset so the finger never covers
    /// the incoming ball (see `GameRenderer.paddleInput`). The swipe itself
    /// is read from raw screen motion.
    private func input(for touch: UITouch, phase: InputEvent.Phase) {
        let p = touch.location(in: view)
        let w = max(view.bounds.width, 1), h = max(view.bounds.height, 1)
        let up = Double(1 - p.y / h)                  // 0 = bottom of screen
        let offset = settings.controls.touchOffset
        let (u, v) = GameRenderer.paddleInput(screenX: Double(p.x / w), up: up + offset, reach: PaddleReach())
        host.withSim { sim in
            sim.handleInput(phase: phase, u: u, v: v,
                            screenX: Double(p.x / h), screenY: up)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard overlay == nil, activeTouch == nil, let t = touches.first else { return }
        activeTouch = t
        input(for: t, phase: .began)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        // Use coalesced touches for accurate swipe velocity at 120 Hz.
        if let coalesced = event?.coalescedTouches(for: t), coalesced.count > 1 {
            for c in coalesced { input(for: c, phase: .moved) }
        } else {
            input(for: t, phase: .moved)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        input(for: t, phase: .ended)
        activeTouch = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        input(for: t, phase: .cancelled)
        activeTouch = nil
    }

    // MARK: Pause / results

    @objc private func appWillResign() {
        if overlay == nil, host.withSim({ $0.phase }) != .matchEnded { pauseTapped() }
    }

    @objc private func pauseTapped() {
        guard overlay == nil else { return }
        SoundManager.shared.play(.menu)
        host.isPaused = true
        let resume = PongoButton(title: "Resume", primary: true)
        resume.addTarget(self, action: #selector(resumeTapped), for: .touchUpInside)
        let restart = PongoButton(title: mode == .match ? "Restart Match" : "Restart")
        restart.addTarget(self, action: #selector(restartTapped), for: .touchUpInside)
        let menu = PongoButton(title: "Main Menu")
        menu.addTarget(self, action: #selector(menuTapped), for: .touchUpInside)
        presentOverlay(title: "PAUSED", lines: [], buttons: [resume, restart, menu])
    }

    @objc private func resumeTapped() {
        dismissOverlay()
        host.isPaused = false
    }

    @objc private func restartTapped() {
        dismissOverlay()
        host.withSim { $0.restartMatch() }
        host.isPaused = false
        refreshHUD()
    }

    @objc private func menuTapped() {
        host.isPaused = true
        scnView.isPlaying = false
        navigationController?.popViewController(animated: true)
    }

    private func showResults() {
        let (score, stats) = host.withSim { ($0.score, $0.stats) }
        let won = score.matchWinner == .near
        let games = score.completedGames.map { "\($0.near)–\($0.far)" }.joined(separator: "   ")
        let lines = [
            "GAMES  \(score.games(.near)) – \(score.games(.far))",
            games,
            "",
            "Longest rally: \(stats.longestRally) shots",
            String(format: "Average rally: %.1f shots", stats.averageRally),
            "Successful returns: \(stats.successfulReturns)",
            String(format: "Fastest shot: %.1f m/s", stats.fastestShot),
            String(format: "Max spin: %.0f rpm", stats.maxSpin / (2 * .pi) * 60)
        ]
        let restart = PongoButton(title: "Restart Match", primary: true)
        restart.addTarget(self, action: #selector(restartTapped), for: .touchUpInside)
        let menu = PongoButton(title: "Main Menu")
        menu.addTarget(self, action: #selector(menuTapped), for: .touchUpInside)
        presentOverlay(title: won ? "VICTORY" : "DEFEAT", titleColor: won ? Palette.cyan : Palette.violet,
                       lines: lines, buttons: [restart, menu])
    }

    private func presentOverlay(title: String, titleColor: UIColor = Palette.white, lines: [String], buttons: [UIButton]) {
        let o = UIView()
        o.translatesAutoresizingMaskIntoConstraints = false
        o.backgroundColor = UIColor(red: 0.01, green: 0.02, blue: 0.06, alpha: 0.82)
        view.addSubview(o)
        pin(o)
        let t = makeLabel(title, size: 44, weight: .black, color: titleColor, kern: 8)
        t.layer.shadowColor = titleColor.cgColor
        t.layer.shadowRadius = 16
        t.layer.shadowOpacity = 0.7
        t.layer.shadowOffset = .zero
        var views: [UIView] = [t]
        for line in lines {
            let l = makeLabel(line, size: 16, weight: .medium, color: Palette.white)
            views.append(l)
        }
        let spacer = UIView()
        spacer.heightAnchor.constraint(equalToConstant: 18).isActive = true
        views.append(spacer)
        views.append(contentsOf: buttons)
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(22, after: t)
        stack.translatesAutoresizingMaskIntoConstraints = false
        o.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: o.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: o.safeAreaLayoutGuide.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(equalTo: o.safeAreaLayoutGuide.trailingAnchor, constant: -40)
        ])
        o.alpha = 0
        UIView.animate(withDuration: 0.2) { o.alpha = 1 }
        overlay = o
    }

    private func dismissOverlay() {
        guard let o = overlay else { return }
        overlay = nil
        UIView.animate(withDuration: 0.15, animations: { o.alpha = 0 }, completion: { _ in o.removeFromSuperview() })
    }
}

/// Thread-safe ring buffer for the developer event log.
final class DebugLog {
    private var lines: [String] = []
    private let lock = NSLock()
    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
        if lines.count > 40 { lines.removeFirst(lines.count - 40) }
        NSLog("PONGO %@", line)
    }
    func tail(_ n: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(lines.suffix(n))
    }
}
