import SwiftUI
import UIKit

/// A touch control on screen.
enum ControlID: Hashable {
    case button(PadButton)
    case dpad
    case stick
}

struct ControlFrame: Equatable {
    let id: ControlID
    let frame: CGRect
    let isRound: Bool
}

private struct ControlFramesKey: PreferenceKey {
    static let defaultValue: [ControlFrame] = []
    static func reduce(value: inout [ControlFrame], nextValue: () -> [ControlFrame]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Reports this view's frame so the touch layer knows where the control is. Frames and touches are
    /// both in window coordinates: the touch layer's UIKit view can start higher than the SwiftUI
    /// controls (under the status bar) when they keep to the safe area, as on the controller screen.
    func controlTarget(_ id: ControlID, round: Bool = false) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: ControlFramesKey.self,
                                       value: [ControlFrame(id: id, frame: proxy.frame(in: .global), isRound: round)])
            }
        )
    }
}

/// What the player's fingers are doing right now.
@Observable
final class TouchState {
    var pressed: Set<ControlID> = []
    var pressedButtons: Set<PadButton> = []
    /// Knob offset of the analog stick, from -1 to 1 on both axes.
    var stick: CGVector = .zero
}

/// Hosts the controls and the transparent touch layer above them.
struct ControlSurface<Content: View>: View {
    let input: InputState
    let touches: TouchState
    let haptics: Bool
    /// The button a shake of the iPhone presses: the Wii Remote's shake.
    var shakeButton: PadButton? = nil
    var onMenuKey: () -> Void = {}
    @ViewBuilder var content: Content
    @State private var frames: [ControlFrame] = []

    var body: some View {
        content
            .onPreferenceChange(ControlFramesKey.self) { frames = $0 }
            .overlay {
                TouchLayer(frames: frames, input: input, touches: touches, haptics: haptics, shakeButton: shakeButton,
                           onMenuKey: onMenuKey)
            }
    }
}

private struct TouchLayer: UIViewRepresentable {
    let frames: [ControlFrame]
    let input: InputState
    let touches: TouchState
    let haptics: Bool
    let shakeButton: PadButton?
    let onMenuKey: () -> Void

    func makeUIView(context: Context) -> TouchLayerView {
        let view = TouchLayerView()
        view.input = input
        view.touchState = touches
        return view
    }

    func updateUIView(_ view: TouchLayerView, context: Context) {
        view.frames = frames
        view.hapticsEnabled = haptics
        view.shakeButton = shakeButton
        view.onMenuKey = onMenuKey
    }
}

/// Tracks every finger separately, so a thumb can slide from one button to the
/// next and two buttons can be held at once. Also reads a hardware keyboard.
final class TouchLayerView: UIView {
    var frames: [ControlFrame] = []
    var input: InputState?
    var touchState: TouchState?
    var hapticsEnabled = true
    var shakeButton: PadButton?
    var onMenuKey: () -> Void = {}

    private var activeTouches: [ObjectIdentifier: (controls: Set<ControlID>, buttons: Set<PadButton>, stick: CGVector?)] = [:]
    private var heldKeys: Set<PadButton> = []
    private let feedback = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var canBecomeFirstResponder: Bool { true }

    // MARK: Shaking

    override func motionBegan(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake, let shakeButton else { return super.motionBegan(motion, with: event) }
        input?.set(shakeButton.mask, from: .motion)
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake, shakeButton != nil else { return super.motionEnded(motion, with: event) }
        input?.set(0, from: .motion)
    }

    override func motionCancelled(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        motionEnded(motion, with: event)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            becomeFirstResponder()
            feedback.prepare()
        }
    }

    /// Lets touches outside every control fall through to the views below.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let point = convert(point, to: nil)
        return frames.contains { $0.frame.insetBy(dx: -12, dy: -12).contains(point) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { track(touch) }
        publish(newPress: true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { track(touch) }
        publish(newPress: true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { activeTouches[ObjectIdentifier(touch)] = nil }
        publish(newPress: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    private func track(_ touch: UITouch) {
        let point = touch.location(in: nil)
        var controls = Set<ControlID>()
        var buttons = Set<PadButton>()
        var stick: CGVector?
        // A finger that started on the D-pad or stick stays there while it slides.
        let previous = activeTouches[ObjectIdentifier(touch)]?.controls ?? []
        let anchored = frames.first { ($0.id == .dpad || $0.id == .stick) && previous.contains($0.id) }

        for control in anchored.map({ [$0] }) ?? frames {
            switch control.id {
            case .dpad, .stick:
                guard anchored != nil || control.frame.insetBy(dx: -10, dy: -10).contains(point) else { continue }
                let center = CGPoint(x: control.frame.midX, y: control.frame.midY)
                let dx = point.x - center.x
                let dy = point.y - center.y
                let radius = control.frame.width / 2
                controls.insert(control.id)
                // The stick only moves the core's analog stick; the D-pad presses directions.
                if control.id == .stick {
                    let length = max(hypot(dx, dy), 1)
                    let clamped = min(length, radius * 0.6) / (radius * 0.6)
                    stick = CGVector(dx: dx / length * clamped, dy: dy / length * clamped)
                } else {
                    buttons.formUnion(Self.directions(dx: dx, dy: dy, deadZone: radius * 0.18))
                }
            case .button(let button):
                let hit: Bool
                if control.isRound {
                    let center = CGPoint(x: control.frame.midX, y: control.frame.midY)
                    hit = hypot(point.x - center.x, point.y - center.y) <= control.frame.width / 2 + 10
                } else {
                    hit = control.frame.insetBy(dx: -8, dy: -8).contains(point)
                }
                if hit {
                    controls.insert(control.id)
                    buttons.insert(button)
                }
            }
        }
        activeTouches[ObjectIdentifier(touch)] = (controls, buttons, stick)
    }

    /// Eight directions with a small dead zone in the middle.
    private static func directions(dx: CGFloat, dy: CGFloat, deadZone: CGFloat) -> Set<PadButton> {
        guard hypot(dx, dy) > deadZone else { return [] }
        let angle = atan2(-dy, dx) * 180 / .pi
        let sector = Int(((angle + 360 + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
        switch sector {
        case 0: return [.right]
        case 1: return [.right, .up]
        case 2: return [.up]
        case 3: return [.up, .left]
        case 4: return [.left]
        case 5: return [.left, .down]
        case 6: return [.down]
        default: return [.down, .right]
        }
    }

    private func publish(newPress: Bool) {
        let controls = activeTouches.values.reduce(into: Set<ControlID>()) { $0.formUnion($1.controls) }
        let buttons = activeTouches.values.reduce(into: Set<PadButton>()) { $0.formUnion($1.buttons) }
        let stick = activeTouches.values.compactMap(\.stick).first ?? .zero

        if newPress, hapticsEnabled, let state = touchState, !buttons.subtracting(state.pressedButtons).isEmpty {
            feedback.impactOccurred(intensity: 0.7)
        }
        input?.set(buttons.reduce(0) { $0 | $1.mask }, from: .touch)
        input?.setStick(.left, x: stick.dx, y: stick.dy, from: .touch)
        if touchState?.pressed != controls { touchState?.pressed = controls }
        if touchState?.pressedButtons != buttons { touchState?.pressedButtons = buttons }
        if touchState?.stick != stick { touchState?.stick = stick }
    }

    // MARK: Keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key?.keyCode else { continue }
            if key == .keyboardEscape || key == .keyboardTab {
                onMenuKey()
                handled = true
            } else if let button = KeyboardMapping.button(for: key) {
                heldKeys.insert(button)
                handled = true
            }
        }
        input?.set(heldKeys.reduce(0) { $0 | $1.mask }, from: .keyboard)
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if let key = press.key?.keyCode, let button = KeyboardMapping.button(for: key) {
                heldKeys.remove(button)
            }
        }
        input?.set(heldKeys.reduce(0) { $0 | $1.mask }, from: .keyboard)
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        heldKeys.removeAll()
        input?.set(0, from: .keyboard)
        super.pressesCancelled(presses, with: event)
    }
}

// MARK: - Control views

/// Look of the buttons: light on black in portrait, dark glass over the game in landscape.
struct ControlStyle {
    let fill: Color
    let pressedFill: Color
    let border: Color
    let label: Color
    /// Background of the Menu and fast-forward buttons.
    let barFill: Color
    let barBorder: Color

    static let portrait = ControlStyle(fill: .white.opacity(0.07), pressedFill: .white.opacity(0.24),
                                       border: .white.opacity(0.16), label: Palette.text,
                                       barFill: Palette.control, barBorder: .clear)
    static let overlay = ControlStyle(fill: Color(hex: 0x0D0E12, opacity: 0.45), pressedFill: .white.opacity(0.3),
                                      border: .white.opacity(0.28), label: .white,
                                      barFill: Color(hex: 0x0D0E12, opacity: 0.55), barBorder: .white.opacity(0.28))
}

struct DPad: View {
    let touches: TouchState
    let style: ControlStyle
    /// Width and height; the design's D-pad is 140 points.
    var size: CGFloat = 140

    var body: some View {
        let scale = size / 140
        ZStack(alignment: .topLeading) {
            Rectangle().fill(style.fill).frame(width: 48 * scale, height: 48 * scale).offset(x: 46 * scale, y: 46 * scale)
            arm(.up, systemImage: "chevron.up", x: 46, y: 0, corners: .init(topLeading: 10, bottomLeading: 4, bottomTrailing: 4, topTrailing: 10))
            arm(.right, systemImage: "chevron.right", x: 92, y: 46, corners: .init(topLeading: 4, bottomLeading: 4, bottomTrailing: 10, topTrailing: 10))
            arm(.down, systemImage: "chevron.down", x: 46, y: 92, corners: .init(topLeading: 4, bottomLeading: 10, bottomTrailing: 10, topTrailing: 4))
            arm(.left, systemImage: "chevron.left", x: 0, y: 46, corners: .init(topLeading: 10, bottomLeading: 10, bottomTrailing: 4, topTrailing: 4))
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .controlTarget(.dpad)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("D-pad")
    }

    private func arm(_ button: PadButton, systemImage: String, x: CGFloat, y: CGFloat, corners: RectangleCornerRadii) -> some View {
        let scale = size / 140
        let isPressed = touches.pressedButtons.contains(button)
        let shape = UnevenRoundedRectangle(cornerRadii: corners, style: .continuous)
        return Image(systemName: systemImage)
            .font(.system(size: 16 * scale, weight: .bold))
            .foregroundStyle(style.label.opacity(0.8))
            .frame(width: 48 * scale, height: 48 * scale)
            .background(isPressed ? style.pressedFill : style.fill, in: shape)
            .overlay(shape.strokeBorder(style.border, lineWidth: 1))
            .offset(x: x * scale, y: y * scale)
    }
}

struct AnalogStick: View {
    let touches: TouchState
    let style: ControlStyle
    /// Width and height; the design's stick is 140 points.
    var size: CGFloat = 140

    var body: some View {
        let knob = touches.stick
        let scale = size / 140
        ZStack {
            Circle().fill(style.fill.opacity(0.6))
            Circle().strokeBorder(style.border, lineWidth: 1)
            Circle()
                .fill(.white.opacity(touches.pressed.contains(.stick) ? 0.3 : 0.2))
                .frame(width: 60 * scale, height: 60 * scale)
                .shadow(color: .black.opacity(0.5), radius: 8, y: 6)
                .offset(x: knob.dx * 40 * scale, y: knob.dy * 40 * scale)
        }
        .frame(width: size, height: size)
        .controlTarget(.stick)
        .accessibilityLabel("Analoge stick")
    }
}

struct FaceButtons: View {
    let layout: ControlLayout
    let touches: TouchState
    let style: ControlStyle

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(layout.labels.enumerated()), id: \.offset) { index, label in
                let button = layout.faceButtons[index]
                let position = layout.facePositions[index]
                let size = layout.faceSizes[index]
                Text(label)
                    .font(.text(size < 52 ? 12 : (label.count > 1 ? 15 : 19), weight: 700))
                    .foregroundStyle(style.label)
                    .frame(width: size, height: size)
                    .background(touches.pressedButtons.contains(button) ? style.pressedFill : style.fill, in: Circle())
                    .overlay(Circle().strokeBorder(style.border, lineWidth: 1))
                    .controlTarget(.button(button), round: true)
                    .offset(x: position.x, y: position.y)
                    .accessibilityLabel("Knop \(layout.accessibilityName(ofFace: index))")
            }
        }
        .frame(width: 140, height: 140, alignment: .topLeading)
    }
}

struct ShoulderButton: View {
    let label: String
    let button: PadButton
    let touches: TouchState
    let style: ControlStyle
    var width: CGFloat = 96

    var body: some View {
        Text(label)
            .font(.text(14, weight: 700))
            .foregroundStyle(style.label)
            .frame(width: width, height: 36)
            .background(touches.pressedButtons.contains(button) ? style.pressedFill : style.fill,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(style.border, lineWidth: 1))
            .controlTarget(.button(button))
            .accessibilityLabel("Knop \(label)")
    }
}

struct CenterButtons: View {
    let layout: ControlLayout
    let touches: TouchState
    let style: ControlStyle

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(layout.center.enumerated()), id: \.offset) { index, label in
                let button = layout.centerButtons[index]
                Text(label)
                    .font(.text(12, weight: 600))
                    .foregroundStyle(style.label.opacity(0.85))
                    .padding(.horizontal, 14)
                    .frame(minWidth: 64)
                    .frame(height: 30)
                    .background(touches.pressedButtons.contains(button) ? style.pressedFill : style.fill, in: Capsule())
                    .overlay(Capsule().strokeBorder(style.border, lineWidth: 1))
                    .controlTarget(.button(button))
                    .accessibilityLabel(label == "−" ? "Min" : (label == "+" ? "Plus" : label))
            }
        }
    }
}
