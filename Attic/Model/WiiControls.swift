import AtticLibretro
import Foundation

/// The controller a Wii game is played with, chosen on the game's page (`Game.wiiControls`).
enum WiiController: String, Codable, CaseIterable, Identifiable {
    /// A Wii Remote pointed at the screen, with a Nunchuk: most Wii games.
    case nunchuk
    /// A Wii Remote held sideways like an NES controller, as in New Super Mario Bros. Wii.
    case sideways
    /// A Classic Controller Pro, which many games such as Mario Kart Wii also take.
    case classic
    /// A GameCube controller, for games such as Super Smash Bros. Brawl. The Wii Remote is unplugged.
    case gameCube

    var id: Self { self }

    var title: String {
        switch self {
        case .nunchuk: "Wii Remote + Nunchuk"
        case .sideways: "Wii Remote dwars"
        case .classic: "Classic Controller"
        case .gameCube: "GameCube-controller"
        }
    }

    var shortTitle: String {
        switch self {
        case .nunchuk: "Nunchuk"
        case .sideways: "Dwars"
        case .classic: "Classic"
        case .gameCube: "GameCube"
        }
    }

    /// The device libretro Dolphin is told is plugged in (RETRO_DEVICE_WIIMOTE_* in its Input.cpp).
    var portDevice: UInt32 {
        let joypad = UInt32(RETRO_DEVICE_JOYPAD)
        return switch self {
        case .nunchuk: 3 << 8 | joypad
        case .sideways: 2 << 8 | joypad
        // The Pro: its L, R, ZL and ZR are plain buttons, where the original's L and R are analog triggers.
        case .classic: 5 << 8 | joypad
        case .gameCube: 6 << 8 | joypad
        }
    }

    /// A Wii Remote is in the player's hand, so it can move with the iPhone and be shaken.
    var isWiiRemote: Bool { self == .nunchuk || self == .sideways }

    var layout: ControlLayout {
        switch self {
        case .nunchuk:
            // Dolphin's Wii Remote with Nunchuk: 1 and 2 are Start and Select, C and Z are X and Y,
            // − and + are L and R, and Home is R3.
            ControlLayout(face: .diamond, labels: ["2", "A", "B", "1"], shoulders: ["C", "Z"], center: ["−", "Home", "+"],
                          centerOverride: [.l, .r3, .r], faceOverride: [.select, .a, .b, .start], shoulderOverride: [.x, .y])
        case .sideways:
            // Sideways, Dolphin reads 1 and 2 from B and A, and the Wii Remote's A and B from X and Y.
            ControlLayout(face: .two, labels: ["1", "2"], shoulders: ["A", "B"], center: ["−", "Home", "+"],
                          centerOverride: [.select, .r3, .start], shoulderOverride: [.x, .y])
        case .classic:
            ControlLayout(face: .diamond, labels: ["X", "A", "B", "Y"], shoulders: ["ZL", "L", "R", "ZR"], center: ["−", "Home", "+"],
                          centerOverride: [.select, .r3, .start])
        case .gameCube:
            GameSystem.gc.controls
        }
    }

    /// The left hand has the Nunchuk's or a controller's stick; a sideways Wii Remote only has its D-pad.
    var usesStick: Bool { self != .sideways }

    /// The Wii Remote's D-pad above the Nunchuk's stick, and the Classic Controller's above its left stick.
    var showsDPadWithStick: Bool { self == .nunchuk || self == .classic }
}

/// How a Wii game is played: its controller, and whether the Wii Remote moves with the iPhone.
struct WiiControls: Codable, Hashable {
    var controller: WiiController = .nunchuk
    /// The iPhone's accelerometer is the Wii Remote's: tilting, swinging and shaking it (`WiiMotion`).
    var motion = true
}

extension Game {
    /// The Wii controls chosen on the game's page, or a Wii Remote with Nunchuk that moves with the iPhone.
    var wiiSettings: WiiControls { wiiControls ?? WiiControls() }

    /// The buttons on the screen: the system's, or for the Wii those of the chosen controller.
    var controls: ControlLayout {
        system == .wii ? wiiSettings.controller.layout : system.controls
    }

    var usesStick: Bool {
        system == .wii ? wiiSettings.controller.usesStick : system.usesStick
    }

    var showsDPadWithStick: Bool {
        system == .wii ? wiiSettings.controller.showsDPadWithStick : system.showsDPadWithStick
    }

    /// The button a shake of the iPhone presses: Dolphin's "Shake Wiimote", while a Wii Remote is in use.
    var shakeButton: PadButton? {
        system == .wii && wiiSettings.controller.isWiiRemote ? system.shakeButton : nil
    }

    /// The device the core is told is plugged in, where it differs from the system's (`CoreProfile.portDevice`).
    var portDevice: UInt32? {
        system == .wii ? wiiSettings.controller.portDevice : nil
    }

    /// A Wii Remote's pointer, moved by a finger on the picture or by tilting the iPhone. With a Classic or
    /// GameCube controller the right stick is that controller's own.
    var hasWiiPointer: Bool {
        system == .wii && wiiSettings.controller.isWiiRemote
    }

    /// The Wii Remote follows the iPhone's movement in this game.
    var usesMotion: Bool {
        system == .wii && wiiSettings.controller.isWiiRemote && wiiSettings.motion
    }
}
