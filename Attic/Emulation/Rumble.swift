import CoreHaptics
import GameController
import os
import Synchronization

/// The vibration a core asks for (a Rumble Pak, a Wii Remote's motor and the like), per controller
/// port: a strong and a weak motor from 0 to 1. Set on the core's thread; a change of strength goes
/// to the main thread, where the session hands it to a controller, this iPhone or a joined iPhone.
final class RumbleLevels: Sendable {
    private let levels = Mutex([SIMD2<Float>](repeating: .zero, count: 4))
    private let changed: @Sendable (Int, Float) -> Void

    init(changed: @escaping @Sendable (Int, Float) -> Void) {
        self.changed = changed
    }

    func set(port: Int, strong: Bool, strength: UInt16) {
        guard (0..<4).contains(port) else { return }
        let value = Float(strength) / 0xFFFF
        // Cores repeat the same strength every frame; only a real change is passed on.
        let change: Float? = levels.withLock { levels in
            let before = max(levels[port].x, levels[port].y)
            if strong {
                levels[port].x = value
            } else {
                levels[port].y = value
            }
            let after = max(levels[port].x, levels[port].y)
            return abs(after - before) > 0.02 || (after == 0) != (before == 0) ? after : nil
        }
        if let change {
            changed(port, change)
        }
    }

    /// Stops every motor, as when the game is paused.
    func stopAll() {
        let running: [Int] = levels.withLock { levels in
            let running = levels.indices.filter { levels[$0] != .zero }
            for port in running {
                levels[port] = .zero
            }
            return running
        }
        for port in running {
            changed(port, 0)
        }
    }
}

/// One vibration motor: a controller's (DualSense, Xbox, Switch and others) or this iPhone's.
/// A continuous haptic plays while the strength is above zero, at that strength.
@MainActor
final class HapticMotor {
    private let engine: CHHapticEngine
    private var player: CHHapticAdvancedPatternPlayer?
    private var strength: Float = 0

    private init(engine: CHHapticEngine) {
        self.engine = engine
        engine.playsHapticsOnly = true
        engine.resetHandler = { [weak self] in
            Task { @MainActor in
                self?.player = nil
                try? self?.engine.start()
            }
        }
    }

    /// This iPhone's Taptic Engine, if it has one (not in the Simulator).
    static func phone() -> HapticMotor? {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics, let engine = try? CHHapticEngine() else { return nil }
        return HapticMotor(engine: engine)
    }

    /// The controller's motors, if iOS can drive them.
    static func controller(_ controller: GCController) -> HapticMotor? {
        guard let engine = controller.haptics?.createEngine(withLocality: .default) else { return nil }
        return HapticMotor(engine: engine)
    }

    func set(_ value: Float) {
        guard abs(value - strength) > 0.01 || (value == 0) != (strength == 0) else { return }
        strength = value
        guard value > 0.01 else {
            try? player?.stop(atTime: CHHapticTimeImmediate)
            player = nil
            return
        }
        if player == nil {
            let event = CHHapticEvent(eventType: .hapticContinuous,
                                      parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                                                   CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)],
                                      relativeTime: 0, duration: 30)
            guard let pattern = try? CHHapticPattern(events: [event], parameters: []),
                  let player = try? engine.makeAdvancedPlayer(with: pattern) else { return }
            player.loopEnabled = true
            try? engine.start()
            try? player.start(atTime: CHHapticTimeImmediate)
            self.player = player
        }
        try? player?.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: value, relativeTime: 0)],
                                    atTime: CHHapticTimeImmediate)
    }

    func stop() {
        set(0)
        engine.stop()
    }
}

/// Hands a game's vibration to the player it is meant for: the Bluetooth controllers on that
/// player's port that can vibrate, else for player 1 this iPhone, and for a player on another
/// iPhone a message to that iPhone (`MultiplayerHost`).
@MainActor
final class RumbleOutput {
    /// The setting "Trillen in spellen"; off, nothing vibrates.
    var isEnabled: Bool {
        didSet {
            if !isEnabled {
                stop()
            }
        }
    }
    weak var controllers: GameControllerInput?
    weak var multiplayer: MultiplayerHost?
    private var phone: HapticMotor?
    private var strengths: [Int: Float] = [:]

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    func set(port: Int, strength: Float) {
        guard isEnabled || strength == 0 else { return }
        Logger.emulation.debug("Trillen speler \(port + 1): \(strength, format: .fixed(precision: 2))")
        strengths[port] = strength
        if controllers?.rumble(port: port, strength: strength) == true {
            if port == 0 {
                phone?.set(0)
            }
            return
        }
        if port == 0 {
            if phone == nil, strength > 0 {
                phone = HapticMotor.phone()
            }
            phone?.set(strength)
        } else {
            multiplayer?.rumble(port: port, strength: strength)
        }
    }

    func stop() {
        for port in strengths.keys {
            _ = controllers?.rumble(port: port, strength: 0)
            if port > 0 {
                multiplayer?.rumble(port: port, strength: 0)
            }
        }
        strengths = [:]
        phone?.stop()
        phone = nil
    }
}
