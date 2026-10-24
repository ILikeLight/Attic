import Foundation
import QuartzCore
import UIKit

/// Measures how fast the cores run on this device. Launch the app with `-AtticBenchmark`:
/// every game in Documents/Benchmark then runs as fast as it can for ten seconds, without
/// sound or screen, and the results are printed and written to Documents/Benchmark/results.txt.
/// The app quits when it is done.
///
/// Next to a game, `<name>.state` is a save state to start from, so that play is measured
/// instead of the start-up, and each line of `<name>.options` is one run with other core
/// options: `key=value` pairs separated by spaces. Disc tracks (.bin) are read through their .cue.
/// `attic_warmup=<seconds>` sets the game time played before measuring (normally 2 s); a run
/// with a longer warm-up and no save state yet writes one for the runs after it, and
/// `attic_input=a@150,start@160` presses buttons during the warm-up; `attic_save=1` saves the state
/// after the warm-up also when there is one. The last frame of each run is saved as `<name>.png`.
enum CoreBenchmark {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-AtticBenchmark")
    }

    static func start(paths: LibraryPaths = .shared) {
        let thread = Thread {
            run(paths: paths)
            exit(0)
        }
        thread.name = "Attic benchmark"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private static func run(paths: LibraryPaths) {
        let folder = paths.documents.appendingPathComponent("Benchmark", isDirectory: true)
        let games = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { !["bin", "options"].contains($0.pathExtension.lowercased()) }
            .filter { !GameRecognizer.ignoredExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap { url in GameRecognizer.recognize(url).map { (url: url, system: $0.system) } }
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        var lines = ["Attic snelheidsmeting · \(deviceModel) · \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        report(lines[0])
        for game in games {
            for options in optionSets(for: game.url) {
                lines.append(measure(game.url, system: game.system, options: options, paths: paths))
                report(lines.last!)
            }
        }
        lines.append("Warmte na afloop: \(thermalState)")
        report(lines.last!)
        try? lines.joined(separator: "\n").appending("\n")
            .write(to: folder.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
    }

    /// The core options of each run from `<name>.options`; without that file one run with the profile's own.
    private static func optionSets(for url: URL) -> [[String: String]] {
        let file = url.deletingPathExtension().appendingPathExtension("options")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [[:]] }
        let sets = text.split(whereSeparator: \.isNewline).map { line in
            Dictionary(line.split(separator: " ").compactMap { pair -> (String, String)? in
                let parts = pair.split(separator: "=", maxSplits: 1)
                return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
            }, uniquingKeysWith: { $1 })
        }
        return sets.isEmpty ? [[:]] : sets
    }

    private static func measure(_ url: URL, system: GameSystem, options: [String: String], paths: LibraryPaths) -> String {
        let chosen = options.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let name = "\(system.shortName) · \(url.lastPathComponent)" + (chosen.isEmpty ? "" : " [\(chosen)]")
        guard let profile = CoreProfile.forSystem(system), let api = profile.api() else {
            return "\(name): geen emulator"
        }
        // `attic_warmup=<seconds>` is game time to play before measuring, and `attic_input` the
        // buttons to press then; neither is a core option.
        var coreOptions = options
        let warmup = coreOptions.removeValue(forKey: "attic_warmup").flatMap(Double.init) ?? 2
        let presses = coreOptions.removeValue(forKey: "attic_input").map(buttonPresses) ?? []
        let replacesState = coreOptions.removeValue(forKey: "attic_save") == "1"
        let saves = FileManager.default.temporaryDirectory.appendingPathComponent("Benchmark", isDirectory: true)
        try? FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        profile.linkSystemFiles(into: paths.system)
        let frameBuffer = FrameBuffer()
        let input = InputState()
        let core = LibretroCore(api: api, options: profile.options.merging(coreOptions) { $1 }, rightStickButtons: profile.rightStickButtons,
                                portDevice: profile.portDevice, ports: profile.ports, preferredRenderer: profile.renderer,
                                frameBuffer: frameBuffer, input: input,
                                audio: AudioOutput(), systemDirectory: paths.system, saveDirectory: saves)
        do {
            try core.load(gameAt: url)
        } catch {
            return "\(name): \(error.localizedDescription)"
        }
        defer { core.unload() }
        let stateURL = url.deletingPathExtension().appendingPathExtension("state")
        let state = try? Data(contentsOf: stateURL)
        if let state, !core.unserialize(state) {
            // Mupen64Plus only takes a state once it has run a frame.
            core.runFrame()
            guard core.unserialize(state) else { return "\(name): de save state laadt niet" }
        }

        // Some play first, so start-up work does not count. A longer warm-up without a save state
        // ends in one, so the next runs start where this one measures.
        for frame in 0..<Int(core.framesPerSecond * warmup) {
            // Each press holds its button for a quarter of a second of game time.
            let time = Double(frame) / core.framesPerSecond
            let held = presses.filter { (0..<0.25).contains(time - $0.time) }.reduce(UInt32(0)) { $0 | $1.button.mask }
            input.set(held, from: .controller)
            core.runFrame()
        }
        input.set(0, from: .controller)
        if state == nil && warmup > 2 || replacesState, let made = core.serialize() {
            try? made.write(to: stateURL)
        }
        let monitor = PerformanceMonitor(statistics: core.statistics, sampleRate: core.sampleRate)
        _ = monitor.sample()
        var times: [Double] = []
        let start = CACurrentMediaTime()
        var last = start
        while last - start < 10 {
            core.runFrame()
            let now = CACurrentMediaTime()
            times.append(now - last)
            last = now
        }
        let figures = monitor.sample(threadCount: 3)
        // The last frame, to see what was measured.
        try? frameBuffer.image()?.pngData()?.write(to: url.deletingPathExtension().appendingPathExtension("png"))

        let fps = Double(times.count) / (last - start)
        let sorted = times.sorted()
        let p95 = sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
        var line = String(format: "%@: %.0f frames per seconde = %.1f× echte snelheid (%.2f fps) · per frame gemiddeld %.1f ms, 95%% binnen %.1f ms, langste %.1f ms (budget %.1f ms)",
                          name, fps, fps / core.framesPerSecond, core.framesPerSecond,
                          (last - start) / Double(times.count) * 1000, p95 * 1000, sorted.last! * 1000,
                          1000 / core.framesPerSecond)
        // A core that runs the game in its own thread (Flycast) can skip frames: its sound tells
        // how far the game got, and each thread's processor time per second of game time.
        if let figures, let speed = figures.speed, speed > 0 {
            let threads = figures.threads.map { String(format: "%@ %.2f", $0.name, $0.load / speed) }.joined(separator: ", ")
            line += String(format: " · spel volgens geluid %.2f× · kern per spelseconde: %@", speed, threads)
        }
        return line
    }

    /// `a@150,start@160`: a button (as in `PadButton`) and the game time in seconds to press it.
    private static func buttonPresses(_ text: String) -> [(button: PadButton, time: Double)] {
        text.split(separator: ",").compactMap { entry in
            let parts = entry.split(separator: "@")
            guard parts.count == 2, let time = Double(parts[1]),
                  let button = PadButton.allCases.first(where: { "\($0)" == parts[0].lowercased() }) else { return nil }
            return (button, time)
        }
    }

    private static func report(_ line: String) {
        print(line)
        fflush(stdout)
    }

    private static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private static var thermalState: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "normaal"
        case .fair: "iets warm"
        case .serious: "warm (iOS remt af)"
        case .critical: "heet (iOS remt sterk af)"
        @unknown default: "onbekend"
        }
    }
}
