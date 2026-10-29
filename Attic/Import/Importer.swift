import Foundation
import Observation

/// One import as shown in the sheet: four steps with progress.
@MainActor
@Observable
final class ImportJob: Identifiable {
    enum Step: Int, CaseIterable {
        case extract, recognize, metadata, add

        var title: String {
            switch self {
            case .extract: "Uitpakken"
            case .recognize: "Systeem herkennen"
            case .metadata: "Titel en gegevens"
            case .add: "Toevoegen aan bibliotheek"
            }
        }

        var waiting: String {
            switch self {
            case .extract: "Archief openen"
            case .recognize: "Wacht op het uitpakken"
            case .metadata: "Titel, regio en hoes"
            case .add: "Bijna klaar"
            }
        }
    }

    enum Status {
        case waiting, active, done, failed
    }

    struct StepState {
        var status: Status = .waiting
        var detail: String
        var monospaced = false
    }

    enum Outcome {
        case added([Game], duplicates: [Game])
        case duplicate(Game)
        case failed(String)
    }

    let id = UUID()
    let sourceName: String
    let sourceSize: Int64
    private(set) var steps: [Step: StepState]
    private(set) var current: Step = .extract
    /// Extraction progress, 0–1.
    var progress: Double = 0
    /// The game as far as known, for the sheet's cover and title: while unpacking the one the
    /// archive's name promises (`ImportPipeline.expectedGame`), then the one that was recognized.
    var preview: Game?
    private(set) var outcome: Outcome?

    init(sourceName: String, sourceSize: Int64) {
        self.sourceName = sourceName
        self.sourceSize = sourceSize
        steps = Dictionary(uniqueKeysWithValues: Step.allCases.map { ($0, StepState(detail: $0.waiting)) })
    }

    func state(of step: Step) -> StepState { steps[step] ?? StepState(detail: step.waiting) }

    func begin(_ step: Step, _ detail: String, monospaced: Bool = false) {
        current = step
        steps[step] = StepState(status: .active, detail: detail, monospaced: monospaced)
    }

    func update(_ step: Step, _ detail: String) {
        steps[step]?.detail = detail
    }

    func complete(_ step: Step, _ detail: String, monospaced: Bool = false) {
        steps[step] = StepState(status: .done, detail: detail, monospaced: monospaced)
    }

    func finish(_ outcome: Outcome) {
        if case .failed(let message) = outcome {
            steps[current] = StepState(status: .failed, detail: message)
        }
        self.outcome = outcome
    }
}

/// Imports files one after another. Imports started from the sheet show their
/// progress there; imports from the watched folder report with a toast.
@MainActor
@Observable
final class ImportCoordinator {
    struct Request {
        let url: URL
        var securityScoped = false
        /// The file is ours (Documents, Inbox or the demo), so it may be moved or deleted.
        var ownsSource = false
        var interactive = true
    }

    private(set) var current: ImportJob?
    private var queue: [Request] = []
    private var running = false

    private let library: Library
    private let settings: AppSettings
    private let toasts: ToastCenter
    private let paths: LibraryPaths

    init(library: Library, settings: AppSettings, toasts: ToastCenter, paths: LibraryPaths = .shared) {
        self.library = library
        self.settings = settings
        self.toasts = toasts
        self.paths = paths
    }

    func enqueue(_ request: Request) {
        queue.append(request)
        runNext()
    }

    func importDemo() {
        guard let url = Bundle.main.url(forResource: "Attic Demo", withExtension: "gba") else { return }
        enqueue(Request(url: url))
    }

    func dismissFinished() {
        if current?.outcome != nil {
            current = nil
        }
    }

    private func runNext() {
        guard !running, !queue.isEmpty else { return }
        running = true
        let request = queue.removeFirst()
        Task {
            await perform(request)
            running = false
            runNext()
        }
    }

    private func perform(_ request: Request) async {
        let url = request.url
        let scoped = request.securityScoped && url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let job = ImportJob(sourceName: url.lastPathComponent, sourceSize: size)
        if request.interactive {
            current = job
        }
        let pipeline = ImportPipeline(paths: paths)
        await pipeline.run(request, job: job, library: library, cleanupArchives: settings.cleanupArchives,
                           fetchCovers: settings.fetchCovers)

        guard !request.interactive else { return }
        switch job.outcome {
        case .added(let games, _):
            if let game = games.first {
                toasts.show("\(game.title) staat in je bibliotheek")
            }
        case .duplicate(let game):
            toasts.show("\(game.title) staat al in je bibliotheek")
        case .failed(let message):
            toasts.show("\(url.lastPathComponent): \(message)", isError: true)
        case nil:
            break
        }
    }
}

/// The four import steps: unpack, recognize, gather details, add.
struct ImportPipeline {
    let paths: LibraryPaths

    private struct Candidate {
        let file: URL
        let recognition: Recognition
    }

    private enum PipelineError: LocalizedError {
        case noGame
        case copyFailed

        var errorDescription: String? {
            switch self {
            case .noGame: "Geen spel gevonden in dit bestand"
            case .copyFailed: "Het bestand kon niet worden gelezen"
            }
        }
    }

    @MainActor
    func run(_ request: ImportCoordinator.Request, job: ImportJob, library: Library, cleanupArchives: Bool, fetchCovers: Bool) async {
        let source = request.url
        let workspace = paths.imports.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let files = workspace.appendingPathComponent("files", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        // While unpacking, the sheet already shows the game an official archive name promises,
        // and fetches its cover meanwhile; step 3 takes that cover if the name told the truth.
        let expected = Self.expectedGame(for: source)
        job.preview = expected
        var expectedCover: Task<BoxArtFetcher.Outcome, Never>?
        if fetchCovers, let expected {
            expectedCover = Task { [paths] in
                let outcome = await BoxArtFetcher(paths: paths).fetch(for: expected)
                if job.preview?.id == expected.id {
                    job.preview?.record(outcome)
                }
                return outcome
            }
        }
        defer {
            expectedCover?.cancel()
            if let expected {
                try? FileManager.default.removeItem(at: paths.coverFile(expected.id))
            }
        }

        // 1. Unpack
        let kind = ArchiveKind.detect(source)
        do {
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            if let kind {
                job.begin(.extract, kind == .zip ? "Zip-archief openen" : "7z-archief openen")
                try await extract(source, kind: kind, to: files, job: job)
            } else {
                // A copy on the same volume is a clone, so this is instant and the
                // original stays untouched until the game is safely in the library.
                job.begin(.extract, "Bestand lezen")
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.copyItem(at: source, to: files.appendingPathComponent(source.lastPathComponent))
                }.value
                job.progress = 1
            }
        } catch {
            job.finish(.failed((error as? LocalizedError)?.errorDescription ?? PipelineError.copyFailed.localizedDescription))
            return
        }
        job.complete(.extract, kind == nil ? "Geen archief, direct gelezen" : "Uitgepakt")

        // 2. Recognize
        job.begin(.recognize, "Bestanden onderzoeken…")
        var candidates = await Task.detached(priority: .userInitiated) { Self.recognizeAll(in: files) }.value
        // A game that cannot be played, such as an encrypted 3DS game, stops the import unless others can.
        let problems = candidates.compactMap(\.recognition.unplayable)
        candidates.removeAll { $0.recognition.unplayable != nil }
        if candidates.isEmpty, let problem = problems.first {
            job.finish(.failed(problem))
            return
        }
        // A 3DS installation file holds the game itself, which is kept on its own (see Recognition.embeddedGame).
        if candidates.contains(where: { $0.recognition.embeddedGame != nil }) {
            job.update(.recognize, "Spel uit het installatiebestand halen…")
            let unpacking = candidates
            do {
                candidates = try await Task.detached(priority: .userInitiated) { try unpacking.map(Self.unpacked) }.value
            } catch {
                job.finish(.failed("Het spel kon niet worden bewaard. Is er genoeg opslagruimte?"))
                return
            }
        }
        guard let first = candidates.first else {
            job.finish(.failed(PipelineError.noGame.localizedDescription))
            return
        }
        let mainSize = Self.size(of: first.file) + first.recognition.companions.reduce(0) { $0 + Self.size(of: $1) }
        job.complete(.extract, kind == nil ? "Geen archief, direct gelezen" : "\(first.file.lastPathComponent) · \(DisplayText.fileSize(mainSize))",
                     monospaced: kind != nil)
        job.complete(.recognize, first.recognition.summary)

        // 3. Title, details and box art
        job.begin(.metadata, "Spelkop lezen…")
        var games: [(game: Game, candidate: Candidate)] = []
        for candidate in candidates {
            let game = await makeGame(candidate, archiveName: kind == nil ? nil : source.lastPathComponent)
            games.append((game, candidate))
        }
        if fetchCovers {
            let fetcher = BoxArtFetcher(paths: paths)
            for index in games.indices where library.duplicate(of: games[index].game) == nil {
                if index == 0, let expected, let art = await expectedCover?.value.art,
                   expected.system == games[0].game.system, expected.databaseName == games[0].game.databaseName,
                   (try? FileManager.default.copyItem(at: paths.coverFile(expected.id), to: paths.coverFile(games[0].game.id))) != nil {
                    games[0].game.record(.found(art))
                    continue
                }
                job.update(.metadata, "Hoes ophalen…")
                games[index].game.record(await fetcher.fetch(for: games[index].game))
            }
        }
        let lead = games[0].game
        job.preview = lead
        job.complete(.metadata, [lead.title, lead.region, lead.year].compactMap { $0 }.joined(separator: " · "))

        // 4. Add
        job.begin(.add, lead.system.isPlayable ? "\(lead.system.coreName) klaarzetten…" : "Toevoegen…")
        var added: [Game] = []
        var duplicates: [Game] = []
        for (game, candidate) in games {
            if let existing = library.duplicate(of: game) {
                duplicates.append(existing)
                continue
            }
            do {
                try store(candidate, as: game)
                library.add(game)
                added.append(game)
            } catch {
                try? FileManager.default.removeItem(at: paths.coverFile(game.id))
                job.finish(.failed("Het spel kon niet worden bewaard. Is er genoeg opslagruimte?"))
                return
            }
        }

        // The game now lives in the library; tidy up files that were ours.
        var cleaned = false
        if request.ownsSource, !source.path.hasPrefix(Bundle.main.bundlePath), kind == nil || cleanupArchives {
            cleaned = (try? FileManager.default.removeItem(at: source)) != nil && kind != nil
        }

        if added.isEmpty, let existing = duplicates.first {
            job.complete(.add, "Stond al in je bibliotheek")
            job.finish(.duplicate(existing))
            return
        }
        let extra = added.count > 1 ? " · \(added.count) spellen" : ""
        job.complete(.add, (cleaned ? "Klaar · archief opgeruimd" : "Klaar om te spelen") + extra)
        job.finish(.added(added, duplicates: duplicates))
    }

    @MainActor
    private func extract(_ source: URL, kind: ArchiveKind, to folder: URL, job: ImportJob) async throws {
        try await Task.detached(priority: .userInitiated) {
            let archive = try openArchive(source, kind: kind)
            let total = max(archive.totalSize, 1)
            var lastReport = Date.distantPast
            try archive.extractAll(to: folder) { written in
                let now = Date()
                if now.timeIntervalSince(lastReport) > 0.08 || written >= total {
                    lastReport = now
                    let fraction = min(1, Double(written) / Double(total))
                    Task { @MainActor in
                        job.progress = fraction
                        job.update(.extract, "\(Int(fraction * 100))% · \(DisplayText.fileSize(Int64(written)))")
                    }
                }
                return true
            }
        }.value
        job.progress = 1
    }

    /// Every recognized game in the folder, largest first. Tracks named in a
    /// .cue or .gdi belong to that sheet and are not games on their own.
    private static func recognizeAll(in folder: URL) -> [Candidate] {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [.skipsHiddenFiles])
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathComponents.contains("__MACOSX") { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(url)
            }
        }
        var candidates: [Candidate] = []
        var companions = Set<String>()
        for file in files where ["cue", "gdi"].contains(file.pathExtension.lowercased()) {
            if let recognition = GameRecognizer.recognize(file) {
                candidates.append(Candidate(file: file, recognition: recognition))
                recognition.companions.forEach { companions.insert($0.standardizedFileURL.path) }
            }
        }
        for file in files where !["cue", "gdi"].contains(file.pathExtension.lowercased()) {
            guard !companions.contains(file.standardizedFileURL.path), let recognition = GameRecognizer.recognize(file) else { continue }
            candidates.append(Candidate(file: file, recognition: recognition))
        }
        return candidates.sorted { size(of: $0.file) > size(of: $1.file) }
    }

    /// The candidate with the game inside its file stored on its own, in place of that file.
    private static func unpacked(_ candidate: Candidate) throws -> Candidate {
        guard let embedded = candidate.recognition.embeddedGame else { return candidate }
        let game = try unpackEmbeddedGame(of: candidate.file, range: embedded.range, fileExtension: embedded.fileExtension)
        try? FileManager.default.removeItem(at: candidate.file)
        var recognition = GameRecognizer.recognize(game) ?? candidate.recognition
        recognition.summary = candidate.recognition.summary
        recognition.embeddedGame = nil
        return Candidate(file: game, recognition: recognition)
    }

    /// Writes the bytes `range` of `file` next to it, with the same name and `fileExtension`.
    static func unpackEmbeddedGame(of file: URL, range: Range<UInt64>, fileExtension: String) throws -> URL {
        let destination = file.deletingPathExtension().appendingPathExtension(fileExtension)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let input = try FileHandle(forReadingFrom: file)
            let output = try FileHandle(forWritingTo: destination)
            defer {
                try? input.close()
                try? output.close()
            }
            try input.seek(toOffset: range.lowerBound)
            var remaining = range.upperBound - range.lowerBound
            while remaining > 0 {
                let chunk = try autoreleasepool { try input.read(upToCount: Int(min(remaining, 8 << 20))) }
                guard let chunk, !chunk.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                try output.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
    }

    private func makeGame(_ candidate: Candidate, archiveName: String?) async -> Game {
        let recognition = candidate.recognition
        let file = candidate.file
        let size = Self.size(of: file) + recognition.companions.reduce(0) { $0 + Self.size(of: $1) }
        // Cartridge games are small enough to checksum; disc images use their game code.
        let crc: UInt32? = size <= 128 << 20
            ? await Task.detached(priority: .userInitiated) { GameFingerprint.romCRC32(file, system: recognition.system) }.value
            : nil

        let title = Self.title(for: file.lastPathComponent, archiveName: archiveName, recognition: recognition)
        let fromName = GameRecognizer.region(fromFileName: file.lastPathComponent)
            ?? archiveName.flatMap(GameRecognizer.region(fromFileName:))
        // A Game Boy header only says "Japan or not"; a tag like "(Europe)" says more.
        let region = recognition.system == .gb ? (fromName ?? recognition.region) : (recognition.region ?? fromName)

        var game = Game(
            id: UUID(),
            title: title,
            system: recognition.system,
            isColor: recognition.isColor,
            region: region,
            year: nil,
            gameCode: recognition.gameCode,
            headerTitle: recognition.headerTitle,
            recognizedBy: recognition.method,
            fileName: file.lastPathComponent,
            originalFileName: file.lastPathComponent,
            archiveName: archiveName,
            fileSize: size,
            crc32: crc.map { String(format: "%08X", $0) },
            addedAt: .now,
            artSeed: 0
        )
        if let entry = GameDatabase.shared.entry(system: recognition.system, crc: crc, serial: recognition.gameCode,
                                                 fileName: file.lastPathComponent) {
            game.apply(entry)
        }
        game.metadataVersion = GameMetadata.version
        game.artSeed = Self.seed(for: game.title)
        return game
    }

    /// The game an official No-Intro or Redump file name promises, from the database alone, so the
    /// sheet can show it before the archive is unpacked. Nil for other names.
    static func expectedGame(for source: URL) -> Game? {
        guard let (system, entry) = GameDatabase.shared.entry(named: source.lastPathComponent) else { return nil }
        var game = Game(
            id: UUID(),
            title: entry.title,
            system: system,
            region: entry.region,
            year: nil,
            gameCode: entry.serial,
            headerTitle: nil,
            recognizedBy: .fileExtension,
            fileName: source.lastPathComponent,
            originalFileName: source.lastPathComponent,
            archiveName: source.lastPathComponent,
            fileSize: 0,
            crc32: nil,
            addedAt: .now,
            artSeed: 0
        )
        game.apply(entry)
        game.artSeed = seed(for: game.title)
        return game
    }

    /// Discs carry their full title in the header; cartridges only an abbreviation,
    /// so for those a tidy file name wins.
    static func title(for fileName: String, archiveName: String?, recognition: Recognition) -> String {
        let header = recognition.headerTitle.map { $0 == $0.uppercased() ? TitleFormatter.titleCase($0) : $0 }
        let fullHeaderTitles: Set<GameSystem> = [.wii, .gc, .n64, .md, .snes, .psp, .ps1]
        if fullHeaderTitles.contains(recognition.system), let header {
            return header
        }
        // Dreamcast GD-ROM sets are often just "disc.gdi" with track01.bin and so on.
        let base = (fileName as NSString).deletingPathExtension.lowercased()
        let named = !["disc", "disk", "game", "gdi", "image"].contains(base)
        return (named ? TitleFormatter.title(fromFileName: fileName) : nil)
            ?? archiveName.flatMap(TitleFormatter.title(fromFileName:))
            ?? header
            ?? (fileName as NSString).deletingPathExtension
    }

    /// A stable number for the cover style, so a game keeps its colours.
    static func seed(for title: String) -> Int {
        title.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
    }

    private func store(_ candidate: Candidate, as game: Game) throws {
        let folder = paths.gameFolder(game.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: candidate.file, to: folder.appendingPathComponent(game.fileName))
        for companion in candidate.recognition.companions {
            try FileManager.default.moveItem(at: companion, to: folder.appendingPathComponent(companion.lastPathComponent))
        }
    }

    private static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
