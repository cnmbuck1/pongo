import UIKit
import SpinCore

/// Minimal Cnmbuck-styled button: dark glass with a cyan outline.
final class PongoButton: UIButton {
    init(title: String, primary: Bool = false) {
        super.init(frame: .zero)
        var config = UIButton.Configuration.plain()
        var attr = AttributedString(title.uppercased())
        attr.font = .systemFont(ofSize: primary ? 20 : 16, weight: .bold)
        attr.kern = 3
        config.attributedTitle = attr
        config.baseForegroundColor = primary ? Palette.midnight : Palette.white
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 28, bottom: 14, trailing: 28)
        configuration = config
        backgroundColor = primary ? Palette.cyan : UIColor(white: 1, alpha: 0.06)
        layer.cornerRadius = 14
        layer.borderWidth = primary ? 0 : 1.2
        layer.borderColor = Palette.cyan.withAlphaComponent(0.7).cgColor
        if primary {
            layer.shadowColor = Palette.cyan.cgColor
            layer.shadowRadius = 14
            layer.shadowOpacity = 0.55
            layer.shadowOffset = .zero
        }
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        addTarget(self, action: #selector(tap), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func tap() { SoundManager.shared.play(.menu) }

    override var isHighlighted: Bool {
        didSet { UIView.animate(withDuration: 0.1) { self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity } }
    }
}

func makeLabel(_ text: String = "", size: CGFloat, weight: UIFont.Weight = .semibold,
               color: UIColor = Palette.white, kern: CGFloat = 0, align: NSTextAlignment = .center) -> UILabel {
    let l = UILabel()
    l.translatesAutoresizingMaskIntoConstraints = false
    l.textAlignment = align
    l.textColor = color
    l.font = .monospacedDigitSystemFont(ofSize: size, weight: weight)
    if kern != 0 {
        l.attributedText = NSAttributedString(string: text, attributes: [.kern: kern, .font: l.font!, .foregroundColor: color])
    } else {
        l.text = text
    }
    return l
}

/// Small optional spin indicator: shows topspin / backspin and left / right
/// side as an arrow on a dial, with a short label.
final class SpinIndicatorView: UIView {
    private let label = makeLabel("", size: 10, weight: .bold, color: Palette.textDim)
    private var top: Double = 0
    private var side: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: bottomAnchor, constant: 2),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            widthAnchor.constraint(equalToConstant: 46), heightAnchor.constraint(equalToConstant: 46)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ reading: SpinReading?) {
        guard let r = reading, r.total > SpinReading.threshold else {
            top = 0; side = 0; label.text = ""
            setNeedsDisplay(); return
        }
        top = r.topspin; side = r.sidespin
        label.text = r.label.uppercased()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let ring = UIBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3))
        ring.lineWidth = 1.5
        Palette.cyan.withAlphaComponent(0.4).setStroke()
        ring.stroke()
        let mag = (top * top + side * side).squareRoot()
        guard mag > 1 else { return }
        let scale = CGFloat(min(1, mag / 220)) * (bounds.width / 2 - 6)
        // Up = topspin, down = backspin, right/left = curve direction.
        let dx = CGFloat(side / mag) * scale
        let dy = CGFloat(-top / mag) * scale
        let tip = CGPoint(x: c.x + dx, y: c.y + dy)
        let arrow = UIBezierPath()
        arrow.move(to: c); arrow.addLine(to: tip)
        arrow.lineWidth = 3
        arrow.lineCapStyle = .round
        (top >= 0 ? Palette.cyan : Palette.violet).setStroke()
        arrow.stroke()
        let dot = UIBezierPath(ovalIn: CGRect(x: tip.x - 3.5, y: tip.y - 3.5, width: 7, height: 7))
        (top >= 0 ? Palette.cyan : Palette.violet).setFill()
        dot.fill()
    }
}
