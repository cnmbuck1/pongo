import UIKit
import SpinCore

/// Settings: opponent difficulty, control scheme and assistance, touch offset,
/// swipe sensitivity, sound, haptics, spin indicator, training overlays and
/// ball skin.
final class SettingsViewController: UIViewController {

    private var settings: AppSettings
    private let onChange: (AppSettings) -> Void
    private let stack = UIStackView()

    init(settings: AppSettings, onChange: @escaping (AppSettings) -> Void) {
        self.settings = settings
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = Palette.midnight
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
        navigationController?.navigationBar.tintColor = Palette.cyan
        navigationController?.navigationBar.titleTextAttributes = [.foregroundColor: Palette.white]

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -30),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20)
        ])
        build()
    }

    private func section(_ title: String) {
        let l = makeLabel(title.uppercased(), size: 12, weight: .bold, color: Palette.cyan, kern: 3, align: .left)
        stack.addArrangedSubview(l)
        stack.setCustomSpacing(8, after: l)
    }

    private func note(_ text: String) {
        let l = makeLabel(text, size: 12, weight: .regular, color: Palette.textDim, align: .left)
        l.numberOfLines = 0
        stack.addArrangedSubview(l)
    }

    private func segmented(_ title: String, _ items: [String], selected: Int, _ action: @escaping (Int) -> Void) {
        section(title)
        let s = UISegmentedControl(items: items)
        s.selectedSegmentIndex = selected
        s.apportionsSegmentWidthsByContent = true
        s.selectedSegmentTintColor = Palette.cyan
        s.setTitleTextAttributes([.foregroundColor: Palette.midnight], for: .selected)
        s.setTitleTextAttributes([.foregroundColor: Palette.white], for: .normal)
        s.addAction(UIAction { [weak self] _ in
            action(s.selectedSegmentIndex); self?.changed()
        }, for: .valueChanged)
        stack.addArrangedSubview(s)
    }

    private func toggle(_ title: String, _ value: Bool, _ action: @escaping (Bool) -> Void) {
        let row = UIStackView()
        row.axis = .horizontal
        let l = makeLabel(title, size: 16, weight: .medium, align: .left)
        let sw = UISwitch()
        sw.isOn = value
        sw.onTintColor = Palette.cyan
        sw.addAction(UIAction { [weak self] _ in action(sw.isOn); self?.changed() }, for: .valueChanged)
        row.addArrangedSubview(l)
        row.addArrangedSubview(sw)
        stack.addArrangedSubview(row)
    }

    private func slider(_ title: String, _ value: Float, _ range: ClosedRange<Float>, _ action: @escaping (Float) -> Void) {
        section(title)
        let s = UISlider()
        s.minimumValue = range.lowerBound
        s.maximumValue = range.upperBound
        s.value = value
        s.minimumTrackTintColor = Palette.cyan
        s.addAction(UIAction { [weak self] _ in action(s.value); self?.changed() }, for: .valueChanged)
        stack.addArrangedSubview(s)
    }

    private func build() {
        segmented("Opponent", AIDifficulty.allCases.map { $0.displayName },
                  selected: AIDifficulty.allCases.firstIndex(of: settings.difficulty) ?? 1) { [weak self] i in
            self?.settings.difficulty = AIDifficulty.allCases[i]
        }
        let assistItems = ["Match opponent"] + AssistLevel.allCases.map { $0.displayName }
        let assistIndex = settings.assistFollowsDifficulty ? 0 : 1 + (AssistLevel.allCases.firstIndex(of: settings.controls.assist) ?? 1)
        segmented("Control assistance", assistItems, selected: assistIndex) { [weak self] i in
            guard let self else { return }
            self.settings.assistFollowsDifficulty = i == 0
            if i > 0 { self.settings.controls.assist = AssistLevel.allCases[i - 1] }
        }
        note("Assistance sets how quickly the paddle tracks the ball, how wide the timing window is and how much the blade angle is helped. It never guarantees a return. \"Match opponent\" uses Beginner, Standard or Expert to match the opponent.")
        segmented("Control scheme", ControlScheme.allCases.map { $0.displayName },
                  selected: ControlScheme.allCases.firstIndex(of: settings.controls.scheme) ?? 0) { [weak self] i in
            self?.settings.controls.scheme = ControlScheme.allCases[i]
        }
        note("Auto paddle: the paddle moves to the ball and hits it for you. Swipe any time while the ball is coming to pick the shot: up for topspin (fast for power), down for backspin, left or right to place it, a curved swipe for sidespin. No swipe plays a safe return. Finger paddle: the paddle follows your finger and your swipe is the stroke. Drag + flick: drag slowly to position, flick to strike.")
        slider("Touch offset (finger paddle schemes)", Float(settings.controls.touchOffset), 0...0.25) { [weak self] v in
            self?.settings.controls.touchOffset = Double(v)
        }
        slider("Swipe sensitivity", Float(settings.controls.swipeSensitivity), 0.6...1.6) { [weak self] v in
            self?.settings.controls.swipeSensitivity = Double(v)
        }
        segmented("Ball", BallSkin.allCases.map { $0.displayName },
                  selected: BallSkin.allCases.firstIndex(of: settings.ballSkin) ?? 0) { [weak self] i in
            self?.settings.ballSkin = BallSkin.allCases[i]
        }
        note("Ball skins are cosmetic only. Every ball has identical physics.")
        section("Feedback")
        toggle("Sound", settings.soundEnabled) { [weak self] v in self?.settings.soundEnabled = v }
        toggle("Haptics", settings.hapticsEnabled) { [weak self] v in self?.settings.hapticsEnabled = v }
        toggle("Spin indicator", settings.showSpinIndicator) { [weak self] v in self?.settings.showSpinIndicator = v }
        toggle("Training overlays", settings.trainingOverlays) { [weak self] v in self?.settings.trainingOverlays = v }
        toggle("Motion effects", settings.motionEffects) { [weak self] v in self?.settings.motionEffects = v }
        note("Training overlays (spin axis, bounce markers, contact readout) appear only in Training mode. Motion effects are camera shake and trail emphasis on big shots.")
    }

    private func changed() {
        SoundManager.shared.enabled = settings.soundEnabled
        HapticManager.shared.enabled = settings.hapticsEnabled
        onChange(settings)
    }

    @objc private func done() { dismiss(animated: true) }
}
