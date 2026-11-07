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
    private let playerScore = makeLabel("0", size: 40, weight: .heavy)
    private let opponentScore = makeLabel("0", size: 40, weight: .heavy, color: Palette.violet)
    private let playerName = makeLabel("YOU", size: 11, weight: .bold, color: Palette.cyan, kern: 2)
    private let opponentName = makeLabel("CPU", size: 11, weight: .bold, color: Palette.violet, kern: 2)
    private let gameLabel = makeLabel("GAME 1", size: 12, weight: .bold, color: Palette.textDim, kern: 3)
    private let gamesLabel = makeLabel("0 – 0", size: 13, weight: .semibold, color: Palette.textDim)
    private let playerServe = UIView()
    private let opponentServe = UIView()
    private let callout = makeLabel("", size: 30, weight: .heavy, kern: 4)
    private let hint = makeLabel("", size: 14, weight: .semibold, color: Palette.textDim)
    private let spinIndicator = SpinIndicatorView()
    private let contactReadout = makeLabel("", size: 12, weight: .semibold, color: Palette.cyan)
    private let pauseButton = UIButton(type: .system)
    private var overlay: UIView?
    private var hudTimer: CADisplayLink?
    private var lastServeHintShown = false

    // Touch tracking (single finger).
    private weak var activeTouch: UITouch?

    init(mode: GameMode, settings: AppSettings) {
        self.mode = mode
        self.settings = settings
        var setup = GameSetup()
        setup.mode = mode
        setup.difficulty = mode == .training ? .beginner : settings.difficulty
        setup.controls = settings.controls
        setup.seed = UInt64(Date().timeIntervalSince1970)
        let sim = GameSimulation(setup: setup)
        let renderer = GameRenderer(table: setup.physics.table, physics: setup.physics, skin: settings.ballSkin)
        renderer.trainingVisuals = mode == .training && settings.trainingOverlays
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

        func column(_ name: UILabel, _ score: UILabel, _ dot: UIView) -> UIStackView {
            let top = UIStackView(arrangedSubviews: [dot, name])
            top.axis = .horizontal
            top.spacing = 6
            top.alignment = .center
            let s = UIStackView(arrangedSubviews: [top, score])
            s.axis = .vertical
            s.alignment = .center
            s.spacing = 0
            return s
        }
        let left = column(playerName, playerScore, playerServe)
        let right = column(opponentName, opponentScore, opponentServe)
        let middle = UIStackView(arrangedSubviews: [gameLabel, gamesLabel])
        middle.axis = .vertical
        middle.alignment = .center
        middle.spacing = 4
        let bar = UIStackView(arrangedSubviews: [left, middle, right])
        bar.axis = .horizontal
        bar.distribution = .equalCentering
        bar.alignment = .center
        bar.translatesAutoresizingMaskIntoConstraints = false

        let barBG = UIView()
        barBG.translatesAutoresizingMaskIntoConstraints = false
        barBG.backgroundColor = UIColor(red: 0.02, green: 0.04, blue: 0.10, alpha: 0.55)
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
        callout.layer.shadowColor = Palette.cyan.cgColor
        callout.layer.shadowRadius = 12
        callout.layer.shadowOpacity = 0.8
        callout.layer.shadowOffset = .zero
        hint.numberOfLines = 0
        [callout, hint, contactReadout].forEach { view.addSubview($0) }
        spinIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinIndicator)
        spinIndicator.isHidden = !(settings.showSpinIndicator || mode == .training)
        contactReadout.numberOfLines = 2
        contactReadout.isHidden = !(mode == .training && settings.trainingOverlays)

        if mode == .training {
            playerScore.isHidden = true; opponentScore.isHidden = true
            playerServe.isHidden = true; opponentServe.isHidden = true
            gamesLabel.text = "RETURNS 0"
            gameLabel.text = "TRAINING"
            opponentName.text = "FEEDER"
        }

        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: g.topAnchor, constant: 14),
            bar.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 34),
            bar.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -84),
            barBG.topAnchor.constraint(equalTo: bar.topAnchor, constant: -8),
            barBG.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
            barBG.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: -18),
            barBG.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 18),
            pauseButton.centerYAnchor.constraint(equalTo: barBG.centerYAnchor),
            pauseButton.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            pauseButton.widthAnchor.constraint(equalToConstant: 40),
            pauseButton.heightAnchor.constraint(equalToConstant: 40),
            callout.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            callout.topAnchor.constraint(equalTo: barBG.bottomAnchor, constant: 40),
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
            playerScore.text = "\(snap.points(.near))"
            opponentScore.text = "\(snap.points(.far))"
            gameLabel.text = "GAME \(snap.gameNumber)"
            gamesLabel.text = "\(snap.games(.near)) – \(snap.games(.far))"
            playerServe.alpha = server == .near ? 1 : 0.12
            opponentServe.alpha = server == .far ? 1 : 0.12
        } else {
            gamesLabel.text = "RETURNS \(returns)"
        }
        let showServeHint = phase == .serving && server == .near
        if showServeHint != lastServeHintShown {
            lastServeHintShown = showServeHint
            hint.text = showServeHint ? "Touch to toss, then swipe up through the ball to serve" : ""
        }
        if mode == .training, settings.trainingOverlays, let c = contact {
            let who = c.side == .near ? "YOU" : "FEEDER"
            contactReadout.text = String(format: "%@  %.1f m/s\n%@  %.0f rpm", who, c.ballSpeed,
                                         c.spin.label.uppercased(), c.spin.revolutionsPerSecond * 60)
        }
    }

    @objc private func hudTick() {
        guard spinIndicator.isHidden == false else { return }
        let reading: SpinReading? = host.withSim { sim in
            sim.world.ballHeld ? nil : SpinReading(ball: sim.world.ball)
        }
        spinIndicator.show(reading)
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
        for e in events {
            switch e {
            case let .physics(p):
                let strength = min(1, p.impactSpeed / 12)
                switch p.kind {
                case .paddleHit:
                    SoundManager.shared.play(.paddle, strength: strength)
                    if p.side == .near {
                        let power = min(1, p.ballAfter.velocity.length / 14)
                        HapticManager.shared.paddleContact(power: power)
                    }
                case .tableBounce: SoundManager.shared.play(.table, strength: strength)
                case .netTouch: SoundManager.shared.play(.net, strength: strength)
                case .floorHit: SoundManager.shared.play(.table, strength: strength * 0.4)
                }
            case let .point(winner, reason):
                SoundManager.shared.play(.point, strength: 0.7)
                HapticManager.shared.point(won: winner == .near)
                if mode == .training {
                    flash(winner == .near ? "NICE" : describe(reason), color: winner == .near ? Palette.cyan : Palette.white)
                } else {
                    flash(winner == .near ? "POINT" : describe(reason), color: winner == .near ? Palette.cyan : Palette.violet)
                }
            case .letCalled:
                flash("LET")
            case let .gameWon(by, game):
                flash(by == .near ? "GAME \(game) – YOU" : "GAME \(game) – CPU", color: by == .near ? Palette.cyan : Palette.violet)
            case let .matchWon(by):
                SoundManager.shared.play(by == .near ? .victory : .defeat)
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

    /// Converts a touch to simulation input. Horizontal position maps across
    /// the reachable width; vertical position (with the occlusion offset)
    /// maps to paddle height. The swipe itself is read from raw screen motion.
    private func input(for touch: UITouch, phase: InputEvent.Phase) {
        let p = touch.location(in: view)
        let w = max(view.bounds.width, 1), h = max(view.bounds.height, 1)
        let up = 1 - p.y / h                       // 0 = bottom of screen
        let offset = settings.controls.touchOffset
        let u = Double((p.x / w - 0.06) / 0.88)
        // The paddle sits `offset` screen-heights above the finger so the
        // finger never covers the incoming ball.
        let v = (Double(up) + offset - 0.17) / 0.36
        host.withSim { sim in
            sim.handleInput(phase: phase, u: u, v: v,
                            screenX: Double(p.x / h), screenY: Double(up))
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
