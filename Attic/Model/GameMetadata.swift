import Foundation
import Observation
import UIKit

/// The game database lookup for games that are already in the library.
enum GameMetadata {
    /// Raised when the lookup learns something new, so older games are looked up again.
    /// 2: Dreamcast cue sheets, which older imports took for PlayStation discs.
    /// 3: 3DS installation files (CIA), which older imports kept whole.
    /// 4: the libretro-database instead of OpenVGDB, with Wii, 3DS and Dreamcast games too.
    static let version = 4

    /// What a second look at a game's file found.
    struct Lookup {
        /// PlayStation and PSP discs read again for their game code, or found to be another system's.
        var recognition: Recognition?
        /// The checksum No-Intro counts, where it differs from the file's own.
        var crc: UInt32?
        var entry: GameDatabase.Entry?
        /// The game taken out of a 3DS installation file (see Recognition.embeddedGame); the file can go.
        var unpackedFile: URL?
    }

    /// Reads the file where that tells more than an older import did, then looks the game up.
    static func lookUp(_ game: Game, file: URL) -> Lookup {
        var lookup = Lookup()
        var gameCode = game.gameCode
        if game.system == .n3ds, file.pathExtension.lowercased() == "cia", let recognition = GameRecognizer.recognize(file),
           recognition.unplayable == nil, let embedded = recognition.embeddedGame,
           let unpacked = try? ImportPipeline.unpackEmbeddedGame(of: file, range: embedded.range, fileExtension: embedded.fileExtension) {
            lookup.unpackedFile = unpacked
            lookup.recognition = GameRecognizer.recognize(unpacked) ?? recognition
            gameCode = lookup.recognition?.gameCode
        }
        if gameCode == nil, game.system == .ps1 || game.system == .psp, let recognition = GameRecognizer.recognize(file),
           recognition.gameCode != nil || recognition.system != game.system {
            lookup.recognition = recognition
            gameCode = recognition.gameCode
        }
        let system = lookup.recognition?.system ?? game.system
        if [.nes, .snes, .n64].contains(system), game.fileSize <= 128 << 20 {
            lookup.crc = GameFingerprint.romCRC32(file, system: system)
        }
        let crc = lookup.crc ?? game.crc32.flatMap { UInt32($0, radix: 16) }
        lookup.entry = GameDatabase.shared.entry(system: system, crc: crc, serial: gameCode, fileName: game.originalFileName)
        return lookup
    }

    static func apply(_ lookup: Lookup, to game: inout Game) {
        if let unpacked = lookup.unpackedFile {
            game.fileName = unpacked.lastPathComponent
            game.fileSize = Int64((try? unpacked.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        if let recognition = lookup.recognition {
            if recognition.system != game.system {
                game.system = recognition.system
                // The cover was looked for under the wrong system.
                game.boxArt = nil
                game.boxArtCheckedAt = nil
            }
            game.gameCode = recognition.gameCode
            game.recognizedBy = recognition.method
            game.region = recognition.region ?? game.region
        }
        if let crc = lookup.crc {
            game.crc32 = String(format: "%08X", crc)
        }
        if let entry = lookup.entry {
            game.apply(entry)
        }
        game.metadataVersion = version
    }
}

extension Game {
    /// Box art is worth looking for: never looked, or not found a month ago.
    var wantsBoxArt: Bool {
        boxArt == nil && (boxArtCheckedAt.map { Date.now.timeIntervalSince($0) > 30 * 86_400 } ?? true)
    }

    mutating func record(_ outcome: BoxArtFetcher.Outcome) {
        switch outcome {
        case .found(let art):
            boxArt = art
            boxArtCheckedAt = .now
        case .notFound:
            boxArtCheckedAt = .now
        case .failed:
            break
        }
    }
}

/// Brings games imported earlier up to date: the database lookup, and box art when
/// "Hoesjes automatisch ophalen" is on. One game at a time, in the background.
@MainActor
final class MetadataRefresher {
    private let library: Library
    private let settings: AppSettings
    private var running = false
    private var again = false

    init(library: Library, settings: AppSettings) {
        self.library = library
        self.settings = settings
    }

    func refresh() {
        guard !running else {
            again = true
            return
        }
        running = true
        Task {
            repeat {
                again = false
                await pass()
            } while again
            running = false
        }
    }

    private func pass() async {
        let fetcher = BoxArtFetcher(paths: library.paths)
        for id in library.games.map(\.id) {
            guard let game = library.game(id) else { continue }
            if (game.metadataVersion ?? 0) < GameMetadata.version {
                let file = library.paths.gameFile(game)
                let lookup = await Task.detached(priority: .utility) { GameMetadata.lookUp(game, file: file) }.value
                library.update(id) { GameMetadata.apply(lookup, to: &$0) }
                if lookup.unpackedFile != nil {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            guard settings.fetchCovers, let current = library.game(id), current.wantsBoxArt else { continue }
            let outcome = await fetcher.fetch(for: current)
            library.update(id) { $0.record(outcome) }
        }
    }
}

/// Box art pictures for the views, read from disk once.
@MainActor
@Observable
final class CoverStore {
    private let paths: LibraryPaths
    @ObservationIgnored private let images = NSCache<NSString, UIImage>()

    init(paths: LibraryPaths = .shared) {
        self.paths = paths
    }

    func image(for game: Game) -> UIImage? {
        guard let art = game.boxArt else { return nil }
        let key = "\(game.id.uuidString)/\(art.fetchedAt.timeIntervalSince1970)" as NSString
        if let image = images.object(forKey: key) { return image }
        guard let image = UIImage(contentsOfFile: paths.coverFile(game.id).path) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }
}
