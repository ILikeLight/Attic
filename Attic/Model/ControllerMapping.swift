import Foundation

/// A button on a Bluetooth controller, by where it sits rather than what it is called: the face
/// buttons are named for their place (the bottom one is A on Xbox, ✕ on PlayStation, B on Switch).
enum ControllerButton: String, Codable, CaseIterable, Identifiable {
    case south, east, west, north, l1, r1, l2, r2, l3, r3, menu, options, up, down, left, right

    var id: Self { self }

    var title: String {
        switch self {
        case .south: "Onderste knop (A / ✕)"
        case .east: "Rechter knop (B / ○)"
        case .west: "Linker knop (X / □)"
        case .north: "Bovenste knop (Y / △)"
        case .l1: "L1 / LB"
        case .r1: "R1 / RB"
        case .l2: "L2 / LT"
        case .r2: "R2 / RT"
        case .l3: "Linkerstick indrukken"
        case .r3: "Rechterstick indrukken"
        case .menu: "Menu / Options / +"
        case .options: "View / Share / −"
        case .up: "D-pad omhoog"
        case .down: "D-pad omlaag"
        case .left: "D-pad links"
        case .right: "D-pad rechts"
        }
    }

    /// As on a Nintendo pad: the right face button is A, the bottom one B, the top one X, the left one Y.
    var defaultTarget: PadButton {
        switch self {
        case .south: .b
        case .east: .a
        case .west: .y
        case .north: .x
        case .l1: .l
        case .r1: .r
        case .l2: .l2
        case .r2: .r2
        case .l3: .l3
        case .r3: .r3
        case .menu: .start
        case .options: .select
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        }
    }
}

/// Which console button each controller button presses, for one way of playing: a system, or on
/// the Wii a system and its controller, since their buttons differ. Only changes are stored.
struct ControllerMapping: Equatable {
    /// Changed buttons; nil presses nothing.
    var changes: [ControllerButton: PadButton?] = [:]

    func target(of button: ControllerButton) -> PadButton? {
        if let change = changes[button] { return change }
        return button.defaultTarget
    }

    /// The buttons a controller press gives, for the libretro mask.
    func mask(_ pressed: (ControllerButton) -> Bool) -> UInt32 {
        ControllerButton.allCases.reduce(0) { mask, button in
            guard pressed(button), let target = target(of: button) else { return mask }
            return mask | target.mask
        }
    }
}

/// The ways of playing a mapping is kept for, with the console buttons on offer and their names.
struct ControlScheme: Identifiable, Hashable {
    let system: GameSystem
    /// The Wii's controller; nil for other systems.
    let wiiController: WiiController?

    var id: String {
        wiiController.map { "\(system.rawValue)-\($0.rawValue)" } ?? system.rawValue
    }

    var title: String {
        wiiController.map { "\(system.name) · \($0.title)" } ?? system.name
    }

    var layout: ControlLayout {
        wiiController?.layout ?? system.controls
    }

    /// Every way of playing, in the order of the systems.
    static var all: [ControlScheme] {
        GameSystem.allCases.filter(\.isPlayable).flatMap { system in
            system == .wii
                ? WiiController.allCases.map { ControlScheme(system: system, wiiController: $0) }
                : [ControlScheme(system: system, wiiController: nil)]
        }
    }

    static func of(_ game: Game) -> ControlScheme {
        ControlScheme(system: game.system, wiiController: game.system == .wii ? game.wiiSettings.controller : nil)
    }

    /// The console's buttons a controller button can press, with their names on that console.
    var targets: [(button: PadButton, title: String)] {
        let layout = layout
        var targets: [(PadButton, String)] = []
        for index in layout.labels.indices {
            targets.append((layout.faceButtons[index], layout.accessibilityName(ofFace: index)))
        }
        for (index, label) in layout.shoulders.enumerated() {
            targets.append((layout.shoulderButtons[index], label))
        }
        for (index, label) in layout.center.enumerated() {
            targets.append((layout.centerButtons[index], label))
        }
        targets += [(.up, "Omhoog"), (.down, "Omlaag"), (.left, "Links"), (.right, "Rechts")]
        // The Wii Remote's shake, which the touch screen does by shaking the iPhone.
        if wiiController?.isWiiRemote == true, let shake = system.shakeButton {
            targets.append((shake, "Schudden"))
        }
        // A button may appear twice (the N64's C buttons are also its right stick); keep the first.
        var seen = Set<PadButton>()
        return targets.filter { seen.insert($0.0).inserted }
    }

    func title(of button: PadButton?) -> String {
        guard let button else { return "Niets" }
        return targets.first { $0.button == button }?.title ?? "Niets"
    }
}
