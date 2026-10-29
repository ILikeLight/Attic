import Foundation
import Observation

/// Where Attic keeps its files.
///
/// Games and saves live in Application Support. Documents is the folder the
/// Files app shows as "Attic"; with "Map in de gaten houden" on, anything put
/// there is imported.
struct LibraryPaths: Sendable {
    static let shared = LibraryPaths()

    let root: URL
    let documents: URL

    init() {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("Attic", isDirectory: true)
        documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for folder in [root, games, saves, system, covers, imports] {
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    var libraryFile: URL { root.appendingPathComponent("library.json") }
    var games: URL { root.appendingPathComponent("Games", isDirectory: true) }
    var saves: URL { root.appendingPathComponent("Saves", isDirectory: true) }
    /// BIOS files and other files cores ask for.
    var system: URL { root.appendingPathComponent("System", isDirectory: true) }
    /// Fetched box art, one JPEG per game.
    var covers: URL { root.appendingPathComponent("Covers", isDirectory: true) }
    var imports: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Imports", isDirectory: true) }

    func gameFolder(_ id: UUID) -> URL {
        games.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func gameFile(_ game: Game) -> URL {
        gameFolder(game.id).appendingPathComponent(game.fileName)
    }

    func saveFolder(_ id: UUID) -> URL {
        saves.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func coverFile(_ id: UUID) -> URL {
        covers.appendingPathComponent(id.uuidString + ".jpg")
    }
}

@MainActor
@Observable
final class Library {
    private(set) var games: [Game] = []
    let paths: LibraryPaths

    init(paths: LibraryPaths = .shared) {
        self.paths = paths
        load()
    }

    func game(_ id: UUID) -> Game? {
        games.first { $0.id == id }
    }

    /// The game shown under "Verder spelen".
    var continueGame: Game? {
        games.filter { $0.lastPlayedAt != nil }.max { ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast) }
    }

    /// Newest first, the order of the library grid.
    var sortedGames: [Game] {
        games.sorted { $0.addedAt > $1.addedAt }
    }

    func count(of system: GameSystem) -> Int {
        games.filter { $0.system == system }.count
    }

    func duplicate(of candidate: Game) -> Game? {
        games.first { game in
            guard game.system == candidate.system, game.fileSize == candidate.fileSize else { return false }
            if let a = game.crc32, let b = candidate.crc32 { return a == b }
            if let a = game.gameCode, let b = candidate.gameCode { return a == b }
            return game.originalFileName == candidate.originalFileName
        }
    }

    func add(_ game: Game) {
        games.append(game)
        save()
    }

    func update(_ id: UUID, _ change: (inout Game) -> Void) {
        guard let index = games.firstIndex(where: { $0.id == id }) else { return }
        change(&games[index])
        save()
    }

    func remove(_ id: UUID) {
        games.removeAll { $0.id == id }
        save()
        try? FileManager.default.removeItem(at: paths.gameFolder(id))
        try? FileManager.default.removeItem(at: paths.saveFolder(id))
        try? FileManager.default.removeItem(at: paths.coverFile(id))
    }

    func recordSession(_ id: UUID, duration: TimeInterval) {
        update(id) { game in
            game.lastPlayedAt = .now
            game.playTime += max(0, duration)
            game.isNew = false
        }
    }

    private func load() {
        let url = paths.libraryFile
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Game by game: one that cannot be read (a damaged entry, or a field another version
        // writes differently) costs only that game, not the whole library.
        if let entries = try? decoder.decode([ReadableGame].self, from: data) {
            games = entries.compactMap(\.game)
            if games.count < entries.count {
                keepCopy(of: url)
            }
        } else {
            // Not readable at all: keep the file, so saving the next change does not lose it.
            keepCopy(of: url)
        }
        // Drop entries whose files are gone, for example after a failed restore.
        games.removeAll { !FileManager.default.fileExists(atPath: paths.gameFile($0).path) }
    }

    /// Keeps a copy of a library file that could not be read whole, next to it.
    private func keepCopy(of url: URL) {
        let copy = url.deletingLastPathComponent()
            .appendingPathComponent("library-kapot-\(Int(Date.now.timeIntervalSince1970)).json")
        try? FileManager.default.copyItem(at: url, to: copy)
    }

    /// A game from library.json, or nil when its entry cannot be read.
    private struct ReadableGame: Decodable {
        let game: Game?

        init(from decoder: Decoder) throws {
            game = try? Game(from: decoder)
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(games) else { return }
        try? data.write(to: paths.libraryFile, options: .atomic)
    }
}
