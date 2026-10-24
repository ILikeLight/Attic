import CoreGraphics

/// The libretro joypad buttons, numbered as RETRO_DEVICE_ID_JOYPAD_*.
enum PadButton: Int, CaseIterable, Hashable {
    case b = 0, y, select, start, up, down, left, right, a, x, l, r, l2, r2, l3, r3

    var mask: UInt32 { 1 << UInt32(rawValue) }
}

/// The 14 systems from the prototype, with their emulator and file formats.
enum GameSystem: String, Codable, CaseIterable, Identifiable {
    case wii, gc, n3ds, ds, gba, gb, n64, snes, nes, ps1, psp, md, dc, arcade

    var id: String { rawValue }

    var name: String {
        switch self {
        case .wii: "Wii"
        case .gc: "GameCube"
        case .n3ds: "Nintendo 3DS"
        case .ds: "Nintendo DS"
        case .gba: "Game Boy Advance"
        case .gb: "Game Boy en Color"
        case .n64: "Nintendo 64"
        case .snes: "Super Nintendo"
        case .nes: "NES"
        case .ps1: "PlayStation"
        case .psp: "PSP"
        case .md: "Mega Drive"
        case .dc: "Dreamcast"
        case .arcade: "Arcade"
        }
    }

    var shortName: String {
        switch self {
        case .wii: "Wii"
        case .gc: "GC"
        case .n3ds: "3DS"
        case .ds: "DS"
        case .gba: "GBA"
        case .gb: "GBC"
        case .n64: "N64"
        case .snes: "SNES"
        case .nes: "NES"
        case .ps1: "PS1"
        case .psp: "PSP"
        case .md: "MD"
        case .dc: "DC"
        case .arcade: "ARC"
        }
    }

    /// The open-source emulator that runs this system.
    var coreName: String {
        switch self {
        case .wii, .gc: "Dolphin"
        case .n3ds: "Azahar"
        case .ds: "melonDS"
        case .gba, .gb: "mGBA"
        case .n64: "Mupen64Plus"
        case .snes: "bsnes"
        case .nes: "Nestopia"
        case .ps1: "PCSX ReARMed"
        case .psp: "PPSSPP"
        case .md: "Genesis Plus GX"
        case .dc: "Flycast"
        case .arcade: "FBNeo"
        }
    }

    var extensions: [String] {
        switch self {
        case .wii: ["iso", "rvz", "wbfs", "wad", "wia", "ciso"]
        case .gc: ["iso", "rvz", "gcz", "gcm", "ciso"]
        case .n3ds: ["3ds", "cci", "3dsx", "cia", "cxi"]
        case .ds: ["nds"]
        case .gba: ["gba", "agb"]
        case .gb: ["gb", "gbc", "sgb"]
        case .n64: ["z64", "n64", "v64"]
        case .snes: ["sfc", "smc"]
        case .nes: ["nes"]
        case .ps1: ["cue", "bin", "chd", "pbp"]
        case .psp: ["iso", "cso", "pbp"]
        case .md: ["md", "gen", "bin", "smd"]
        case .dc: ["gdi", "cue", "chd", "cdi"]
        case .arcade: ["zip"]
        }
    }

    /// The formats as listed on the Systems screen.
    var formatList: String {
        switch self {
        case .wii: ".iso .rvz .wbfs .wad"
        case .gc: ".iso .rvz .gcz"
        case .n3ds: ".3ds .cci .cxi .cia .3dsx"
        case .ds: ".nds"
        case .gba: ".gba"
        case .gb: ".gb .gbc"
        case .n64: ".z64 .n64 .v64"
        case .snes: ".sfc .smc"
        case .nes: ".nes"
        case .ps1: ".cue .bin .chd .pbp"
        case .psp: ".iso .cso .pbp"
        case .md: ".md .gen .bin"
        case .dc: ".gdi .cue .chd .cdi"
        case .arcade: ".zip"
        }
    }

    enum Group: String, CaseIterable {
        case nintendo = "Nintendo", sony = "Sony", sega = "Sega", other = "Overig"
    }

    var group: Group {
        switch self {
        case .wii, .gc, .n3ds, .ds, .gba, .gb, .n64, .snes, .nes: .nintendo
        case .ps1, .psp: .sony
        case .md, .dc: .sega
        case .arcade: .other
        }
    }

    /// Whether this build contains an emulator for the system.
    var isPlayable: Bool {
        switch self {
        case .gba, .gb, .nes, .snes, .ds, .ps1, .n64, .gc, .wii, .dc, .n3ds, .psp: true
        default: false
        }
    }

    /// The button a shake of the iPhone presses: Dolphin's "Shake Wiimote".
    var shakeButton: PadButton? {
        self == .wii ? .r2 : nil
    }

    /// The phase of the plan (LEESMIJ.md) in which the emulator arrives.
    var plannedPhase: Int? {
        switch self {
        case .gba, .gb: 1
        case .nes, .snes, .ds, .ps1: 2
        case .n64, .psp: 3
        case .n3ds, .wii, .gc: 4
        case .md, .dc, .arcade: nil
        }
    }

    var availability: String {
        if isPlayable { return "Speelbaar" }
        if let phase = plannedPhase { return "Fase \(phase)" }
        return "Later"
    }

    /// When the emulator of a system that cannot be played yet arrives, to follow its name:
    /// "komt in fase 4", or "komt in een volgende versie".
    var arrival: String {
        plannedPhase.map { "komt in fase \($0)" } ?? "komt in een volgende versie"
    }

    var is3D: Bool {
        switch self {
        case .wii, .gc, .n3ds, .ds, .n64, .ps1, .psp, .dc: true
        default: false
        }
    }

    /// Players who can play at once, each on a controller port: the others join from another
    /// iPhone (`MultiplayerHost`), on the Wii each with its own Wii Remote and its movement.
    /// Handhelds need a console per player, which the cores do not emulate.
    var maxPlayers: Int {
        switch self {
        case .nes, .snes, .ps1: 2
        case .n64, .gc, .wii, .dc: 4
        default: 1
        }
    }

    /// On the 3DS the stick is the Circle Pad, on the PSP the analog nub.
    var usesStick: Bool {
        switch self {
        case .wii, .gc, .n64, .dc, .n3ds, .psp: true
        default: false
        }
    }

    /// Systems whose games use the D-pad as much as the stick: both are on the screen, the D-pad
    /// above the stick as on a PSP.
    var showsDPadWithStick: Bool {
        self == .psp || self == .dc
    }

    var controlsDescription: String {
        switch self {
        case .wii: "Wii Remote + Nunchuk"
        case .ds, .n3ds: "Knoppen + aanraakscherm"
        default: showsDPadWithStick ? "D-pad, analoge stick + knoppen" : usesStick ? "Analoge stick + knoppen" : "D-pad + knoppen"
        }
    }

    var screen: ScreenLayout {
        switch self {
        case .wii, .psp: .wide
        case .gba: .gba
        case .gb: .gb
        case .ds: .ds
        case .n3ds: .n3ds
        default: .tv
        }
    }

    var controls: ControlLayout {
        let ps = ["Driehoek", "Rondje", "Kruisje", "Vierkant"]
        switch self {
        case .wii:
            // A game can choose another Wii controller (`Game.controls`).
            return WiiController.nunchuk.layout
        case .gc:
            // Dolphin reads the GameCube's Z from R, and its L and R triggers from L2 and R2.
            return ControlLayout(face: .diamond, labels: ["Y", "A", "B", "X"], shoulders: ["L", "R"], center: ["Z", "Start"],
                                 centerOverride: [.r, .start], faceOverride: [.y, .a, .b, .x], shoulderOverride: [.l2, .r2])
        case .n3ds, .ds, .snes:
            return ControlLayout(face: .diamond, labels: ["X", "A", "B", "Y"], shoulders: ["L", "R"], center: ["Select", "Start"])
        case .gba:
            return ControlLayout(face: .two, labels: ["B", "A"], shoulders: ["L", "R"], center: ["Select", "Start"])
        case .gb, .nes:
            return ControlLayout(face: .two, labels: ["B", "A"], shoulders: [], center: ["Select", "Start"])
        case .n64:
            // The prototype has four face buttons; games such as Super Mario 64 need all four C buttons
            // for the camera, so they sit in a small diamond next to a big A and B. Z is the trigger.
            return ControlLayout(face: .n64, labels: ["C↑", "C→", "C↓", "C←", "B", "A"],
                                 names: ["C omhoog", "C rechts", "C omlaag", "C links", "B", "A"],
                                 shoulders: ["L", "R"], center: ["Z", "Start"], centerOverride: [.l2, .start])
        case .ps1:
            // L2 and R2 are not in the prototype, but many PlayStation games need them.
            return ControlLayout(face: .diamond, labels: ["△", "○", "✕", "□"], names: ps, shoulders: ["L2", "L1", "R1", "R2"],
                                 center: ["Select", "Start"])
        case .psp:
            return ControlLayout(face: .diamond, labels: ["△", "○", "✕", "□"], names: ps, shoulders: ["L", "R"], center: ["Select", "Start"])
        case .md:
            return ControlLayout(face: .three, labels: ["A", "B", "C"], shoulders: [], center: ["Start"])
        case .dc:
            // Flycast reads the Dreamcast's analog triggers from L2 and R2.
            return ControlLayout(face: .diamond, labels: ["Y", "B", "A", "X"], shoulders: ["L", "R"], center: ["Start"],
                                 shoulderOverride: [.l2, .r2])
        case .arcade:
            return ControlLayout(face: .diamond, labels: ["1", "2", "3", "4"], shoulders: [], center: ["Munt", "Start"])
        }
    }
}

/// Screen shape per system, from the LAYOUT table of the prototype.
enum ScreenLayout {
    case wide, tv, gba, gb, ds, n3ds

    /// Width / height of the (top) screen.
    var aspectRatio: CGFloat {
        switch self {
        case .wide: 16.0 / 9.0
        case .tv: 4.0 / 3.0
        case .gba: 3.0 / 2.0
        case .gb: 10.0 / 9.0
        case .ds: 4.0 / 3.0
        case .n3ds: 5.0 / 3.0
        }
    }

    var isDual: Bool { self == .ds || self == .n3ds }

    /// Where the two screens of a DS or 3DS are in the core's picture, as fractions of it.
    /// The 3DS picture is as wide as its top screen (400 pixels); the bottom screen (320) sits
    /// in the middle below it.
    var topRegion: CGRect { CGRect(x: 0, y: 0, width: 1, height: 0.5) }
    var bottomRegion: CGRect {
        self == .n3ds ? CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.5) : CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
    }
    /// Width / height of the bottom screen.
    var bottomAspectRatio: CGFloat { 4.0 / 3.0 }
}

/// Touch layout of the buttons for one system.
struct ControlLayout {
    enum Face {
        /// Four buttons in a diamond: top, right, bottom, left.
        case diamond
        /// Two buttons on a slant, as on the Game Boy.
        case two
        /// Three buttons on a slant, as on the Mega Drive.
        case three
        /// The N64: four small C buttons in a diamond, with B and A beside them.
        case n64
    }

    let face: Face
    let labels: [String]
    var names: [String]? = nil
    let shoulders: [String]
    let center: [String]
    /// The libretro buttons of the center row, where they differ from the usual Select and Start.
    var centerOverride: [PadButton]? = nil
    /// The libretro buttons of the face buttons and shoulders, where the core expects others.
    var faceOverride: [PadButton]? = nil
    var shoulderOverride: [PadButton]? = nil

    /// The libretro button for each face label.
    var faceButtons: [PadButton] {
        if let faceOverride { return faceOverride }
        return switch face {
        case .diamond: [.x, .a, .b, .y]
        case .two: [.b, .a]
        case .three: [.y, .b, .a]
        // The C buttons use buttons the N64 core ignores; `CoreProfile` turns them into its right stick.
        // The core reads the N64's A from libretro's B and its B from Y.
        case .n64: [.x, .r3, .a, .l3, .y, .b]
        }
    }

    /// Diameter of each face button.
    var faceSizes: [CGFloat] {
        face == .n64 ? [36, 36, 36, 36, 52, 52] : Array(repeating: 52, count: labels.count)
    }

    /// Left half of the shoulders sits on the left, the other half on the right.
    var shoulderButtons: [PadButton] {
        shoulderOverride ?? (shoulders.count == 4 ? [.l2, .l, .r, .r2] : Array([PadButton.l, .r].prefix(shoulders.count)))
    }

    var leftShoulders: Range<Int> { 0..<(shoulders.count + 1) / 2 }
    var rightShoulders: Range<Int> { (shoulders.count + 1) / 2..<shoulders.count }

    var centerButtons: [PadButton] {
        if let centerOverride { return centerOverride }
        return switch center.count {
        case 1: [.start]
        case 2: [.select, .start]
        default: [.select, .l3, .start]
        }
    }

    /// Offsets of the face buttons inside their 140×140 area, from the POS table of the prototype.
    var facePositions: [CGPoint] {
        switch face {
        case .diamond: [CGPoint(x: 44, y: 0), CGPoint(x: 88, y: 44), CGPoint(x: 44, y: 88), CGPoint(x: 0, y: 44)]
        case .two: [CGPoint(x: 6, y: 64), CGPoint(x: 82, y: 26)]
        case .three: [CGPoint(x: 0, y: 74), CGPoint(x: 44, y: 44), CGPoint(x: 88, y: 14)]
        case .n64: [CGPoint(x: 82, y: -2), CGPoint(x: 112, y: 28), CGPoint(x: 82, y: 58), CGPoint(x: 52, y: 28),
                    CGPoint(x: -8, y: 48), CGPoint(x: 34, y: 86)]
        }
    }

    func accessibilityName(ofFace index: Int) -> String {
        names?[index] ?? labels[index]
    }
}
