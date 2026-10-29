import GameController
import UIKit

/// The places of players 2 to 4 in a game for more players (`EmulatorSession`), for controllers
/// beyond the first one.
@MainActor
protocol PlayerSeats: AnyObject {
    func claimPort() -> Int?
    func releasePort(_ port: Int)
    var remotePlayers: RemotePlayers { get }
}

/// Maps connected game controllers onto the libretro buttons, as the player set them up
/// (`ControllerMapping`; by default as on a Nintendo pad). The first controller plays player 1,
/// together with this iPhone's screen; in a game for more players each next controller becomes
/// player 2, 3 or 4 while there is a place, and else plays player 1 too.
@MainActor
final class GameControllerInput {
    private struct Seat {
        let controller: GCController
        /// 0 is player 1.
        let port: Int
        var mask: UInt32 = 0
        /// Made the first time the game makes this controller vibrate.
        var motor: HapticMotor?
    }

    private let input: InputState
    /// Systems with an analog stick get the left stick as a stick, the others as a D-pad.
    private let analogStick: Bool
    private let mapping: ControllerMapping
    private let seats: PlayerSeats?
    private var taken: [ObjectIdentifier: Seat] = [:]
    private var observers: [NSObjectProtocol] = []
    /// Called when a controller joins or leaves as player 2 to 4, with a short message.
    var onChange: (String) -> Void = { _ in }

    init(input: InputState, analogStick: Bool, mapping: ControllerMapping = ControllerMapping(), seats: PlayerSeats? = nil) {
        self.input = input
        self.analogStick = analogStick
        self.mapping = mapping
        self.seats = seats
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                self?.attach(note.object as? GCController)
            }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                self?.detach(note.object as? GCController)
            }
        })
        GCController.controllers().forEach(attach)
    }

    /// Connected controllers with the buttons of a game controller.
    static var connected: [GCController] {
        GCController.controllers().filter { $0.extendedGamepad != nil }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for seat in taken.values {
            seat.controller.extendedGamepad?.valueChangedHandler = nil
            seat.controller.playerIndex = .indexUnset
            seat.motor?.stop()
            if seat.port > 0 {
                seats?.releasePort(seat.port)
            }
        }
        taken = [:]
        input.set(0, from: .controller)
        releaseSticks()
    }

    /// A stick left pushed by a controller that is gone would keep steering, and keep the stick
    /// on the screen from working.
    private func releaseSticks() {
        input.setStick(.left, x: 0, y: 0, from: .controller)
        input.setStick(.right, x: 0, y: 0, from: .controller)
    }

    /// Makes the controllers of a player vibrate, at 0 to 1. False when none of them can, so the
    /// iPhone can vibrate instead.
    func rumble(port: Int, strength: Float) -> Bool {
        var handled = false
        for (id, seat) in taken where seat.port == port {
            if seat.motor == nil, strength > 0 {
                taken[id]?.motor = HapticMotor.controller(seat.controller)
            }
            if let motor = taken[id]?.motor {
                motor.set(strength)
                handled = true
            }
        }
        return handled
    }

    private func attach(_ controller: GCController?) {
        guard let controller, let pad = controller.extendedGamepad else { return }
        let id = ObjectIdentifier(controller)
        guard taken[id] == nil else { return }
        let port = taken.values.contains { $0.port == 0 } ? seats?.claimPort() ?? 0 : 0
        taken[id] = Seat(controller: controller, port: port)
        controller.playerIndex = GCControllerPlayerIndex(rawValue: port) ?? .indexUnset
        pad.valueChangedHandler = { [weak self] pad, _ in
            MainActor.assumeIsolated {
                self?.update(id, pad)
            }
        }
        if port > 0 {
            onChange("\(controller.vendorName ?? "Controller") is speler \(port + 1)")
        }
    }

    private func detach(_ controller: GCController?) {
        guard let controller, let seat = taken.removeValue(forKey: ObjectIdentifier(controller)) else { return }
        seat.motor?.stop()
        if seat.port > 0 {
            seats?.releasePort(seat.port)
            onChange("Controller van speler \(seat.port + 1) is weg")
        } else {
            updatePlayerOne()
            if !taken.values.contains(where: { $0.port == 0 }) {
                releaseSticks()
            }
        }
    }

    private func update(_ id: ObjectIdentifier, _ pad: GCExtendedGamepad) {
        guard let port = taken[id]?.port else { return }
        let mask = mapping.mask { pressed($0, on: pad) }
        taken[id]?.mask = mask
        // GameController counts up as positive, libretro down.
        let left = SIMD2(Double(pad.leftThumbstick.xAxis.value), Double(-pad.leftThumbstick.yAxis.value))
        let right = SIMD2(Double(pad.rightThumbstick.xAxis.value), Double(-pad.rightThumbstick.yAxis.value))
        if port == 0 {
            if analogStick {
                input.setStick(.left, x: left.x, y: left.y, from: .controller)
                input.setStick(.right, x: right.x, y: right.y, from: .controller)
            }
            updatePlayerOne()
        } else if let seats {
            func packed(_ stick: SIMD2<Double>) -> SIMD2<Int16> {
                analogStick ? SIMD2(Int16(stick.x * 0x7FFF), Int16(stick.y * 0x7FFF)) : .zero
            }
            seats.remotePlayers.set(port: port, mask: mask, left: packed(left), right: packed(right), motion: .zero)
        }
    }

    /// Player 1's buttons from all controllers that play it.
    private func updatePlayerOne() {
        let mask = taken.values.filter { $0.port == 0 }.reduce(0) { $0 | $1.mask }
        input.set(mask, from: .controller)
    }

    private func pressed(_ button: ControllerButton, on pad: GCExtendedGamepad) -> Bool {
        // Without an analog stick on the console, the left stick works as the D-pad.
        let stick = pad.leftThumbstick
        let stickPresses = !analogStick
        return switch button {
        case .south: pad.buttonA.isPressed
        case .east: pad.buttonB.isPressed
        case .west: pad.buttonX.isPressed
        case .north: pad.buttonY.isPressed
        case .l1: pad.leftShoulder.isPressed
        case .r1: pad.rightShoulder.isPressed
        case .l2: pad.leftTrigger.isPressed
        case .r2: pad.rightTrigger.isPressed
        case .l3: pad.leftThumbstickButton?.isPressed == true
        case .r3: pad.rightThumbstickButton?.isPressed == true
        case .menu: pad.buttonMenu.isPressed
        case .options: pad.buttonOptions?.isPressed == true
        case .up: pad.dpad.up.isPressed || stickPresses && stick.yAxis.value > 0.5
        case .down: pad.dpad.down.isPressed || stickPresses && stick.yAxis.value < -0.5
        case .left: pad.dpad.left.isPressed || stickPresses && stick.xAxis.value < -0.5
        case .right: pad.dpad.right.isPressed || stickPresses && stick.xAxis.value > 0.5
        }
    }
}

/// Keys of a hardware keyboard (also the Mac keyboard in the Simulator).
enum KeyboardMapping {
    static func button(for key: UIKeyboardHIDUsage) -> PadButton? {
        switch key {
        case .keyboardUpArrow, .keyboardW: .up
        case .keyboardDownArrow, .keyboardS: .down
        case .keyboardLeftArrow, .keyboardA: .left
        case .keyboardRightArrow, .keyboardD: .right
        case .keyboardX, .keyboardL: .a
        case .keyboardZ, .keyboardK: .b
        case .keyboardC, .keyboardI: .x
        case .keyboardV, .keyboardJ: .y
        case .keyboardQ: .l
        case .keyboardE: .r
        case .keyboardReturnOrEnter: .start
        case .keyboardDeleteOrBackspace, .keyboardRightShift: .select
        default: nil
        }
    }
}
