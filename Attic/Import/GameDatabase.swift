import Foundation
import SQLite3

/// Titles, years and regions from the libretro-database (CC BY-SA 4.0), packed into GameDB.sqlite by
/// `Database/build_database.py`. Cartridges are found by the checksum No-Intro lists, discs, DS and
/// 3DS games by their game code.
final class GameDatabase: @unchecked Sendable {
    struct Entry {
        /// The No-Intro or Redump name, such as "Super Mario 64 (USA)"; also the name of its libretro thumbnail.
        let name: String
        let title: String
        let year: Int?
        let region: String?
        /// The game code without separators, such as RM8P; nil for most cartridges.
        let serial: String?
    }

    static let shared = GameDatabase()

    private var db: OpaquePointer?
    private let lock = NSLock()

    private init() {
        guard let url = Bundle.main.url(forResource: "GameDB", withExtension: "sqlite") else { return }
        // Immutable: the file lives in the app bundle, so SQLite needs no locks or journal.
        let uri = "file:\(url.path)?immutable=1"
        if sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) != SQLITE_OK {
            sqlite3_close(db)
            db = nil
        }
    }

    /// The exact dump by its checksum, otherwise by a file named the No-Intro or Redump way, such as
    /// "Crash Bandicoot (USA).chd" (which tells the revision too), otherwise the game by its code.
    func entry(system: GameSystem, crc: UInt32?, serial: String?, fileName: String? = nil) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        if let crc, let entry = first(where: "crc = ?", system: system, value: .integer(Int64(crc))) {
            return entry
        }
        if let name = fileName.map({ ($0 as NSString).deletingPathExtension }), name.contains(" ("),
           let entry = first(where: "name = ?", system: system, value: .text(name)) {
            return entry
        }
        // GameCube and Wii discs are listed by the first four letters of their ID: GW7E69 is GW7E.
        if let serial = serial.map({ [.gc, .wii].contains(system) ? String(Self.serialKey($0).prefix(4)) : Self.serialKey($0) }),
           !serial.isEmpty, let entry = first(where: "serial = ?", system: system, value: .text(serial)) {
            return entry
        }
        return nil
    }

    /// The game a file or archive named the No-Intro or Redump way is, whatever its system, such as
    /// "Mario Party 8 (Europe) (En,Fr,De,Es,It).7z" or "Tetris (World).gb.zip". Nil when no list or
    /// several systems' lists have the name.
    func entry(named fileName: String) -> (system: GameSystem, entry: Entry)? {
        var name = (fileName as NSString).deletingPathExtension
        // A game's own extension inside the archive's, as in "Tetris (World).gb.zip".
        if (name as NSString).pathExtension.count <= 4, !(name as NSString).pathExtension.isEmpty {
            name = (name as NSString).deletingPathExtension
        }
        guard name.contains(" (") else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let found = GameSystem.allCases.compactMap { system in
            first(where: "name = ?", system: system, value: .text(name)).map { (system: system, entry: $0) }
        }
        return found.count == 1 ? found[0] : nil
    }

    /// Game codes are compared without separators: SCUS-94900 and SCUS_949.00 are SCUS94900.
    static func serialKey(_ serial: String) -> String {
        String(serial.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII })
    }

    private enum Value {
        case integer(Int64)
        case text(String)
    }

    private func first(where condition: String, system: GameSystem, value: Value) -> Entry? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        let sql = "SELECT name, title, year, region, serial FROM games WHERE system = ? AND \(condition) LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, system.rawValue, -1, Self.transient)
        switch value {
        case .integer(let number): sqlite3_bind_int64(statement, 2, number)
        case .text(let text): sqlite3_bind_text(statement, 2, text, -1, Self.transient)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Entry(
            name: String(cString: sqlite3_column_text(statement, 0)),
            title: String(cString: sqlite3_column_text(statement, 1)),
            year: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 2)),
            region: sqlite3_column_text(statement, 3).map { String(cString: $0) },
            serial: sqlite3_column_text(statement, 4).map { String(cString: $0) }
        )
    }

    /// SQLite copies bound strings.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
