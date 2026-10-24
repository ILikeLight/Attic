import Foundation
import SwiftUI

/// How the importer worked out which game a file is.
enum RecognitionMethod: String, Codable {
    /// A game code in the file header, such as SB4P01 or BZME.
    case gameCode
    /// A valid header without a game code (NES, SNES, Game Boy).
    case header
    /// Only the file extension matched.
    case fileExtension
}

struct Game: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var system: GameSystem
    /// Game Boy only: the game is made for the Game Boy Color.
    var isColor = false
    var region: String?
    var year: String?
    var gameCode: String?
    var headerTitle: String?
    var recognizedBy: RecognitionMethod
    /// File name of the game inside its library folder.
    var fileName: String
    var originalFileName: String
    var archiveName: String?
    var fileSize: Int64
    var crc32: String?
    var addedAt: Date
    var lastPlayedAt: Date?
    var playTime: TimeInterval = 0
    var isFavorite = false
    var isNew = true
    var artSeed: Int
    /// The No-Intro or Redump name of the database entry the game matched (`GameDatabase`).
    var databaseName: String?
    /// Fetched box art; without it the generated cover is shown.
    var boxArt: BoxArt?
    /// When box art was last looked for, found or not.
    var boxArtCheckedAt: Date?
    /// The version of the database lookup the game has had (see `GameMetadata`).
    var metadataVersion: Int?
    /// Speed settings chosen for this game instead of the defaults for all games, by core option
    /// (see `PerformanceSetting`).
    var performance: [String: String]?
    /// The Wii controller and motion chosen on the game's page (see `wiiSettings`).
    var wiiControls: WiiControls?
    /// N64: a Rumble Pak in the controllers instead of a Controller Pak, chosen on the game's page.
    var rumblePak: Bool?

    var shortLabel: String {
        system == .gb && !isColor ? "GB" : system.shortName
    }

    var cover: CoverStyle { CoverStyle(seed: artSeed) }

    /// The title split for the cover: a small line above a large one,
    /// e.g. "The Legend of Zelda" over "The Minish Cap".
    var coverLines: (pre: String?, main: String) {
        TitleFormatter.coverLines(for: title)
    }

    /// Title, year and region from the game database.
    mutating func apply(_ entry: GameDatabase.Entry) {
        title = entry.title
        year = entry.year.map(String.init) ?? year
        region = entry.region ?? region
        databaseName = entry.name
    }
}

/// A cover picture from the internet, kept as Covers/<game id>.jpg.
struct BoxArt: Codable, Hashable {
    enum Source: String, Codable {
        case gameTDB, libretro

        var name: String {
            switch self {
            case .gameTDB: "GameTDB"
            case .libretro: "libretro"
            }
        }
    }

    var source: Source
    var fetchedAt: Date
    /// The picture's average colour (RGB), shown around box art that does not fill the card.
    var backdrop: UInt32
}

// MARK: - Cover art

/// Generated cover: a coloured card with one large shape, as in the prototype.
struct CoverStyle {
    let background: Color
    let foreground: Color
    let motifColor: Color
    let motif: Motif

    struct Motif {
        /// Position of the shape as a fraction of the card's width and height.
        let x: CGFloat
        let y: CGFloat
        /// Size as a fraction of the card's width.
        let size: CGFloat
        /// Corner radius as a fraction of the shape's size (0.5 is a circle).
        let radius: CGFloat
        let rotation: Double
    }

    static let motifs = [
        Motif(x: 0.42, y: 0.14, size: 0.92, radius: 0.5, rotation: 0),
        Motif(x: 0.34, y: 0.04, size: 0.82, radius: 0.22, rotation: 18),
        Motif(x: -0.34, y: 0.30, size: 0.90, radius: 0.5, rotation: 0),
        Motif(x: 0.46, y: 0.30, size: 0.68, radius: 0.16, rotation: 45),
    ]

    static let palettes: [(background: UInt32, foreground: UInt32, motif: UInt32, motifOpacity: Double)] = [
        (0x1B2150, 0xFFD34D, 0xFFD34D, 0.18),
        (0x2E6A3A, 0xF4E9C4, 0xF4E9C4, 0.16),
        (0x0E6B5A, 0xE6F7EE, 0xE6F7EE, 0.16),
        (0xC2332B, 0xFFF1DD, 0xFFF1DD, 0.18),
        (0x7DB94A, 0x17290B, 0x17290B, 0.12),
        (0x2347A6, 0xFFE15A, 0xFFE15A, 0.18),
        (0xE0682C, 0x2A1406, 0x2A1406, 0.14),
        (0x3A2C6E, 0xF2C14E, 0xF2C14E, 0.16),
        (0x1E5FD0, 0xFFFFFF, 0xFFFFFF, 0.16),
        (0x6B2D5C, 0xFFD6E8, 0xFFD6E8, 0.15),
        (0x24323F, 0x8FE3CF, 0x8FE3CF, 0.14),
        (0xB8912F, 0x231A05, 0x231A05, 0.13),
    ]

    init(seed: Int) {
        let palette = Self.palettes[abs(seed) % Self.palettes.count]
        background = Color(hex: palette.background)
        foreground = Color(hex: palette.foreground)
        motifColor = Color(hex: palette.motif, opacity: palette.motifOpacity)
        motif = Self.motifs[abs(seed / Self.palettes.count) % Self.motifs.count]
    }
}

// MARK: - Display text

enum DisplayText {
    static func lastPlayed(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "Nog niet" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Vandaag" }
        if calendar.isDateInYesterday(date) { return "Gisteren" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days < 7 { return "\(days) dagen geleden" }
        if days < 14 { return "Vorige week" }
        if days < 31 { return "\(days / 7) weken geleden" }
        if days < 62 { return "Vorige maand" }
        return date.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "nl_NL")))
    }

    static func playTime(_ seconds: TimeInterval, played: Bool) -> String {
        guard played else { return "–" }
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "Net begonnen" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) u \(String(format: "%02d", minutes % 60)) min"
    }

    static func fileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = bytes >= 1_000_000_000 ? [.useGB] : (bytes >= 1_000_000 ? [.useMB] : [.useKB])
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
            .replacingOccurrences(of: ".", with: ",")
    }

    static func savedAt(_ date: Date, now: Date = .now) -> String {
        if now.timeIntervalSince(date) < 60 { return "Zojuist" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Vandaag, " + date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "nl_NL")))
        }
        return lastPlayed(date, now: now)
    }
}

// MARK: - Titles

enum TitleFormatter {
    private static let keepUppercase: Set<String> = [
        "DS", "3D", "3DS", "II", "III", "IV", "VI", "VII", "VIII", "IX", "XI", "XII", "EX", "GBA", "GB", "HD",
        "RPG", "USA", "UK", "EU", "NES", "SNES", "N64", "DX", "SP", "VS", "GP", "F1", "F-ZERO", "NBA", "NFL",
        "FIFA", "WWE", "TV", "GT", "XL", "UFO", "DK", "WWF",
    ]
    private static let smallWords: Set<String> = ["of", "the", "and", "a", "an", "in", "on", "to", "for", "de", "het", "een", "en", "van", "vs."]
    private static let junkWords: Set<String> = ["backup", "rom", "roms", "dump", "copy", "kopie", "game", "final", "new", "untitled", "fixed", "trimmed", "decrypted"]

    /// Turns "Legend of Zelda, The - The Minish Cap (Europe) (En,Fr).gba" into
    /// "The Legend of Zelda: The Minish Cap". Returns nil for names that say nothing,
    /// such as "smg2" or "SMG2_backup".
    static func title(fromFileName fileName: String) -> String? {
        var name = (fileName as NSString).deletingPathExtension
        name = name.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: "_", with: " ")
        if !name.contains(" ") {
            // "attic-nes-test" or "super.mario.land": separators instead of spaces.
            name = name.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "-", with: " ")
        }
        name = name.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // "Legend of Zelda, The - ..." → "The Legend of Zelda - ..."
        if let match = name.range(of: #"^([^,\-:]+), (The|A|An|De|Het)(\b.*)$"#, options: .regularExpression) {
            let whole = String(name[match])
            let parts = whole.components(separatedBy: ", ")
            if parts.count >= 2 {
                let head = parts[0]
                let rest = parts.dropFirst().joined(separator: ", ")
                let article = rest.prefix { $0 != " " }
                let tail = rest.dropFirst(article.count)
                name = "\(article) \(head)\(tail)"
            }
        }
        name = name.replacingOccurrences(of: " - ", with: ": ")

        let words = name.split(separator: " ").map { String($0) }
        let letters = name.filter(\.isLetter).count
        let hasJunk = words.contains { junkWords.contains($0.lowercased()) }
        let looksLikeCode = words.count == 1 && name.contains(where: \.isNumber)
        if letters < 3 || hasJunk || looksLikeCode || (words.count == 1 && name.count <= 4) {
            return nil
        }
        if name == name.uppercased() || name == name.lowercased() {
            return titleCase(name)
        }
        return name
    }

    /// "SUPER MARIO GALAXY 2" → "Super Mario Galaxy 2".
    static func titleCase(_ raw: String) -> String {
        let words = raw.split(whereSeparator: { $0 == " " }).map(String.init)
        return words.enumerated().map { index, word in
            let upper = word.uppercased()
            if keepUppercase.contains(upper) { return upper }
            let lower = word.lowercased()
            if index > 0 && smallWords.contains(lower) { return lower }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }

    static func coverLines(for title: String) -> (pre: String?, main: String) {
        for separator in [": ", " - "] {
            if let range = title.range(of: separator) {
                let pre = String(title[..<range.lowerBound])
                let main = String(title[range.upperBound...])
                if !pre.isEmpty && !main.isEmpty { return (pre, main) }
            }
        }
        let words = title.split(separator: " ")
        if words.count >= 3, let last = words.last, last.allSatisfy({ $0.isNumber }) || ["II", "III", "IV", "DX"].contains(String(last)) {
            return (words.dropLast().joined(separator: " "), String(last))
        }
        return (nil, title)
    }
}
