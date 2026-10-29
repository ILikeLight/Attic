import Foundation
import Observation
import UIKit

/// A save state: a snapshot of the whole console that can be resumed later.
struct SaveState: Identifiable, Codable, Hashable {
    /// File name without extension: "auto" or "slot-3".
    let id: String
    /// Nil for the auto-save made when stopping.
    let slot: Int?
    let date: Date

    var label: String {
        if let slot { return "Slot \(slot)" }
        return "Auto-save"
    }
}

/// Reads and writes save states on disk. Each state is three files:
/// `<id>.state` (the core's data), `<id>.png` (a screenshot) and `<id>.json`.
@MainActor
@Observable
final class SaveStateStore {
    private let paths: LibraryPaths
    /// Bumped on every write, so views that list states refresh.
    private(set) var revision = 0
    @ObservationIgnored private var cache: [UUID: [SaveState]] = [:]
    @ObservationIgnored private let thumbnails = NSCache<NSString, UIImage>()

    init(paths: LibraryPaths = .shared) {
        self.paths = paths
    }

    private func folder(_ gameID: UUID) -> URL {
        paths.saveFolder(gameID).appendingPathComponent("States", isDirectory: true)
    }

    /// Auto-save first, then slots from newest to oldest.
    func states(for gameID: UUID) -> [SaveState] {
        _ = revision
        if let cached = cache[gameID] { return cached }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(gameID), includingPropertiesForKeys: nil)) ?? []
        let states = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(SaveState.self, from: Data(contentsOf: $0)) }
            .sorted { lhs, rhs in
                if (lhs.slot == nil) != (rhs.slot == nil) { return lhs.slot == nil }
                return lhs.date > rhs.date
            }
        cache[gameID] = states
        return states
    }

    func latest(for gameID: UUID) -> SaveState? {
        states(for: gameID).max { $0.date < $1.date }
    }

    func autosave(for gameID: UUID) -> SaveState? {
        states(for: gameID).first { $0.slot == nil }
    }

    func nextSlot(for gameID: UUID) -> Int {
        (states(for: gameID).compactMap(\.slot).max() ?? 0) + 1
    }

    func data(for state: SaveState, gameID: UUID) -> Data? {
        try? Data(contentsOf: folder(gameID).appendingPathComponent(state.id + ".state"))
    }

    func thumbnail(for state: SaveState, gameID: UUID) -> UIImage? {
        let key = "\(gameID.uuidString)/\(state.id)/\(state.date.timeIntervalSince1970)" as NSString
        if let image = thumbnails.object(forKey: key) { return image }
        let url = folder(gameID).appendingPathComponent(state.id + ".png")
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        thumbnails.setObject(image, forKey: key)
        return image
    }

    @discardableResult
    func write(_ data: Data, thumbnail: UIImage?, slot: Int?, gameID: UUID) -> SaveState? {
        let state = SaveState(id: slot.map { "slot-\($0)" } ?? "auto", slot: slot, date: .now)
        let folder = folder(gameID)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent(state.id + ".state"), options: .atomic)
            if let png = thumbnail?.pngData() {
                try png.write(to: folder.appendingPathComponent(state.id + ".png"), options: .atomic)
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(state).write(to: folder.appendingPathComponent(state.id + ".json"), options: .atomic)
        } catch {
            return nil
        }
        cache[gameID] = nil
        revision += 1
        return state
    }

    /// Keeps a state as a new slot with its own date, for an auto-save that is about to be replaced.
    func keepAsSlot(_ state: SaveState, gameID: UUID) -> SaveState? {
        let folder = folder(gameID)
        let slot = nextSlot(for: gameID)
        let kept = SaveState(id: "slot-\(slot)", slot: slot, date: state.date)
        do {
            for ext in ["state", "png"] {
                let source = folder.appendingPathComponent("\(state.id).\(ext)")
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("\(kept.id).\(ext)"))
                }
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(kept).write(to: folder.appendingPathComponent(kept.id + ".json"), options: .atomic)
        } catch {
            return nil
        }
        cache[gameID] = nil
        revision += 1
        return kept
    }

    /// Removes the state's three files.
    func delete(_ state: SaveState, gameID: UUID) {
        let folder = folder(gameID)
        for ext in ["state", "png", "json"] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(state.id).\(ext)"))
        }
        cache[gameID] = nil
        revision += 1
    }

    func forget(_ gameID: UUID) {
        cache[gameID] = nil
        revision += 1
    }
}
