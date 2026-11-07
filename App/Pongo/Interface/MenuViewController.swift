import UIKit
import SceneKit
import SpinCore

/// Main menu: title over a live attract-mode rally (two AIs playing in the
/// arena under a slowly orbiting camera). Only implemented features have
/// buttons: Play, Training, Settings.
final class MenuViewController: UIViewController {

    private let scnView = SCNView()
    private var host: SimulationHost?
    private var settings = AppSettings.load()
    private let difficulty = UISegmentedControl(items: AIDifficulty.allCases.map { $0.displayName })

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.midnight
        setupAttractScene()
        setupUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        settings = AppSettings.load()
        applySettings()
        difficulty.selectedSegmentIndex = AIDifficulty.allCases.firstIndex(of: settings.difficulty) ?? 1
        host?.isPaused = false
        scnView.isPlaying = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        host?.isPaused = true
        scnView.isPlaying = false
    }

    private func applySettings() {
        SoundManager.shared.enabled = settings.soundEnabled
        HapticManager.shared.enabled = settings.hapticsEnabled
        host?.renderer.setSkin(settings.ballSkin)
    }

    private func setupAttractScene() {
        var setup = GameSetup()
        setup.seed = UInt64(Date().timeIntervalSince1970)
        let sim = GameSimulation(setup: setup,
                                 near: AIOpponentController(side: .near, profile: .intermediate, seed: setup.seed),
                                 far: AIOpponentController(side: .far, profile: .intermediate, seed: setup.seed &+ 1))
        let renderer = GameRenderer(table: setup.physics.table, physics: setup.physics, skin: settings.ballSkin)
        renderer.cameraMode = .orbit
        let host = SimulationHost(sim: sim, renderer: renderer)
        host.onEvents = { [weak host] events in
            // Attract mode loops forever.
            if events.contains(where: { if case .matchWon = $0 { return true }; return false }) {
                host?.withSim { $0.restartMatch() }
            }
        }
        self.host = host
        scnView.translatesAutoresizingMaskIntoConstraints = false
        scnView.scene = renderer.scene
        scnView.pointOfView = renderer.cameraNode
        scnView.delegate = host
        scnView.preferredFramesPerSecond = 60
        scnView.antialiasingMode = .multisampling2X
        scnView.isPlaying = true
        scnView.isUserInteractionEnabled = false
        view.addSubview(scnView)
        NSLayoutConstraint.activate([
            scnView.topAnchor.constraint(equalTo: view.topAnchor),
            scnView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scnView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scnView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        let shade = UIView()
        shade.translatesAutoresizingMaskIntoConstraints = false
        shade.backgroundColor = UIColor(red: 0.01, green: 0.02, blue: 0.06, alpha: 0.45)
        shade.isUserInteractionEnabled = false
        view.addSubview(shade)
        NSLayoutConstraint.activate([
            shade.topAnchor.constraint(equalTo: view.topAnchor),
            shade.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            shade.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            shade.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func setupUI() {
        let title = makeLabel(GameConfig.title, size: 64, weight: .black, kern: 12)
        title.layer.shadowColor = Palette.cyan.cgColor
        title.layer.shadowRadius = 18
        title.layer.shadowOpacity = 0.8
        title.layer.shadowOffset = .zero
        let subtitle = makeLabel(GameConfig.subtitle, size: 16, weight: .bold, color: Palette.cyan, kern: 6)
        let studio = makeLabel(GameConfig.studio, size: 12, weight: .semibold, color: Palette.textDim, kern: 5)

        let play = PongoButton(title: "Play", primary: true)
        play.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        let training = PongoButton(title: "Training")
        training.addTarget(self, action: #selector(trainingTapped), for: .touchUpInside)
        let settingsButton = PongoButton(title: "Settings")
        settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)

        difficulty.translatesAutoresizingMaskIntoConstraints = false
        difficulty.selectedSegmentTintColor = Palette.cyan
        difficulty.setTitleTextAttributes([.foregroundColor: Palette.midnight, .font: UIFont.systemFont(ofSize: 13, weight: .bold)], for: .selected)
        difficulty.setTitleTextAttributes([.foregroundColor: Palette.white, .font: UIFont.systemFont(ofSize: 13, weight: .semibold)], for: .normal)
        difficulty.addTarget(self, action: #selector(difficultyChanged), for: .valueChanged)
        let oppLabel = makeLabel("OPPONENT", size: 11, weight: .bold, color: Palette.textDim, kern: 3)

        let titleStack = UIStackView(arrangedSubviews: [title, subtitle])
        titleStack.axis = .vertical
        titleStack.spacing = 4
        titleStack.translatesAutoresizingMaskIntoConstraints = false

        let buttons = UIStackView(arrangedSubviews: [oppLabel, difficulty, play, training, settingsButton])
        buttons.axis = .vertical
        buttons.spacing = 14
        buttons.setCustomSpacing(8, after: oppLabel)
        buttons.setCustomSpacing(22, after: difficulty)
        buttons.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(titleStack)
        view.addSubview(buttons)
        view.addSubview(studio)
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            titleStack.topAnchor.constraint(equalTo: g.topAnchor, constant: 70),
            titleStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            buttons.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 40),
            buttons.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -40),
            buttons.bottomAnchor.constraint(equalTo: studio.topAnchor, constant: -40),
            difficulty.heightAnchor.constraint(equalToConstant: 36),
            studio.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -16),
            studio.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
    }

    @objc private func difficultyChanged() {
        SoundManager.shared.play(.menu)
        settings.difficulty = AIDifficulty.allCases[difficulty.selectedSegmentIndex]
        settings.save()
    }

    @objc private func playTapped() { start(.match) }
    @objc private func trainingTapped() { start(.training) }

    private func start(_ mode: GameMode) {
        navigationController?.pushViewController(GameViewController(mode: mode, settings: settings), animated: true)
    }

    @objc private func settingsTapped() {
        let vc = SettingsViewController(settings: settings) { [weak self] new in
            self?.settings = new
            new.save()
            self?.applySettings()
        }
        present(UINavigationController(rootViewController: vc), animated: true)
    }
}
