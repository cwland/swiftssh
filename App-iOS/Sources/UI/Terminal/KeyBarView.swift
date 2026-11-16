import UIKit
import Observation
import AppCore

/// The key bar above the software keyboard: Esc, Ctrl, Alt, Tab, arrows, `| / - ~ _`, Home, End,
/// Page Up/Down, in a row that scrolls sideways. Ctrl and Alt are sticky (`KeyBarState`): tap for one
/// keystroke, double-tap to lock, tap again for off; filled while on, with a bar under them while
/// locked.
final class KeyBarView: UIInputView, UIInputViewAudioFeedback {
    private let state: KeyBarState
    private let press: @MainActor (KeyBarState.Key) -> Void
    private var modifierButtons: [KeyBarState.Modifier: UIButton] = [:]
    private static let height: CGFloat = 44

    init(state: KeyBarState, press: @escaping @MainActor (KeyBarState.Key) -> Void) {
        self.state = state
        self.press = press
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.height), inputViewStyle: .keyboard)
        autoresizingMask = [.flexibleWidth]
        allowsSelfSizing = true
        build()
        followState()
    }

    required init?(coder: NSCoder) {
        fatalError("KeyBarView is made in code")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }

    var enableInputClicksWhenVisible: Bool { true }

    private func build() {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 34),
        ])

        for key in KeyBarState.Key.bar {
            stack.addArrangedSubview(keyButton(key))
            if key == .escape {
                stack.addArrangedSubview(modifierButton(.ctrl, title: "ctrl", label: "Control"))
                stack.addArrangedSubview(modifierButton(.alt, title: "alt", label: "Alt"))
            }
        }
    }

    private func keyButton(_ key: KeyBarState.Key) -> UIButton {
        makeButton(title: key.title, label: key.accessibilityLabel) { [weak self] in
            self?.press(key)
        }
    }

    private func modifierButton(_ modifier: KeyBarState.Modifier, title: String, label: String) -> UIButton {
        let button = makeButton(title: title, label: label) { [weak self] in
            self?.state.tap(modifier)
        }
        modifierButtons[modifier] = button
        return button
    }

    private func makeButton(title: String, label: String, action: @escaping @MainActor @Sendable () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.baseBackgroundColor = .secondarySystemBackground
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)
            return attributes
        }
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in
            UIDevice.current.playInputClick()
            action()
        })
        button.accessibilityLabel = label
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        return button
    }

    /// Redraws Ctrl and Alt now and whenever the state changes (Observation fires once per
    /// registration, so this registers again each time).
    private func followState() {
        let (ctrl, alt) = withObservationTracking {
            (state.ctrl, state.alt)
        } onChange: { [weak self] in
            Task { @MainActor in self?.followState() }
        }
        draw(.ctrl, ctrl)
        draw(.alt, alt)
    }

    private func draw(_ modifier: KeyBarState.Modifier, _ value: KeyBarState.ModifierState) {
        guard let button = modifierButtons[modifier], var configuration = button.configuration else { return }
        let on = value != .off
        configuration.baseBackgroundColor = on ? .tintColor : .secondarySystemBackground
        configuration.baseForegroundColor = on ? .white : .label
        configuration.subtitle = value == .locked ? "\u{2014}" : nil
        button.configuration = configuration
        button.accessibilityValue = switch value {
        case .off: "Off"
        case .once: "On for one key"
        case .locked: "Locked on"
        }
    }
}
