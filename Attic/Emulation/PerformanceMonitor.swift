import Darwin
import Foundation
import QuartzCore

/// Measures how a running game keeps up, for the figures over the game (Settings › Prestaties
/// tonen): the frames the core delivers per second, the game's speed by the game time its sound
/// covers, and the threads of the app that use the most processor time.
final class PerformanceMonitor {
    struct Figures {
        var framesPerSecond: Double
        /// Times the core was run per second: the app's pace.
        var runsPerSecond: Double
        /// Game time per real time: 1 is full speed. Nil while the core gives no sound.
        var speed: Double?
        /// The busiest threads: a short name and their share of one processor core (1 is all of it).
        var threads: [(name: String, load: Double)]
    }

    private struct Reading {
        let time: Double
        let frames: Int
        let audioFrames: Int
        let runs: Int
        let threads: [UInt64: Double]
    }

    private let statistics: CoreStatistics
    private let sampleRate: Double
    private var mainThread: UInt64 = 0
    private var last: Reading?

    /// Made on the main thread, the figures call that thread "app".
    init(statistics: CoreStatistics, sampleRate: Double) {
        self.statistics = statistics
        self.sampleRate = sampleRate
        if Thread.isMainThread {
            pthread_threadid_np(nil, &mainThread)
        }
    }

    /// The figures since the previous call, with the `threadCount` busiest threads; nil the first time.
    func sample(threadCount: Int = 2) -> Figures? {
        let threads = threadTimes()
        let reading = Reading(time: CACurrentMediaTime(), frames: statistics.frames.load(ordering: .relaxed),
                              audioFrames: statistics.audioFrames.load(ordering: .relaxed),
                              runs: statistics.runs.load(ordering: .relaxed), threads: threads.mapValues(\.time))
        defer { last = reading }
        guard let last, reading.time > last.time else { return nil }
        let elapsed = reading.time - last.time
        let loads = threads.compactMap { id, thread in
            last.threads[id].map { (name: thread.name, load: (thread.time - $0) / elapsed) }
        }
        let audioFrames = reading.audioFrames - last.audioFrames
        return Figures(framesPerSecond: Double(reading.frames - last.frames) / elapsed,
                       runsPerSecond: Double(reading.runs - last.runs) / elapsed,
                       speed: audioFrames > 0 && sampleRate > 0 ? Double(audioFrames) / sampleRate / elapsed : nil,
                       threads: Array(loads.sorted { $0.load > $1.load }.prefix(threadCount)))
    }

    /// Processor time (user and system, in seconds) and a short name of each thread of the app, by thread ID.
    private func threadTimes() -> [UInt64: (time: Double, name: String)] {
        var list: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [:] }
        defer {
            for index in 0..<Int(count) {
                mach_port_deallocate(mach_task_self_, list[index])
            }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
        }
        var result: [UInt64: (time: Double, name: String)] = [:]
        for index in 0..<Int(count) {
            let thread = list[index]
            var basic = thread_basic_info()
            var identifier = thread_identifier_info()
            guard Self.info(thread, THREAD_BASIC_INFO, &basic) == KERN_SUCCESS,
                  Self.info(thread, THREAD_IDENTIFIER_INFO, &identifier) == KERN_SUCCESS else { continue }
            let time = Double(basic.user_time.seconds + basic.system_time.seconds)
                + Double(basic.user_time.microseconds + basic.system_time.microseconds) / 1_000_000
            result[identifier.thread_id] = (time, identifier.thread_id == mainThread ? "app" : Self.name(of: thread))
        }
        return result
    }

    private static func info<Info>(_ thread: thread_act_t, _ flavor: Int32, _ value: inout Info) -> kern_return_t {
        var count = mach_msg_type_number_t(MemoryLayout<Info>.size / MemoryLayout<natural_t>.size)
        return withUnsafeMutablePointer(to: &value) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(flavor), $0, &count)
            }
        }
    }

    /// The thread's name without its details: "Flycast-emu" becomes "Flycast". Attic's own
    /// emulation thread, which runs the core (and draws for Flycast), is "emulatie".
    private static func name(of thread: thread_act_t) -> String {
        guard let pthread = pthread_from_mach_thread_np(thread) else { return "thread" }
        var buffer = [CChar](repeating: 0, count: 64)
        pthread_getname_np(pthread, &buffer, buffer.count)
        let name = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        if name == "Attic emulation" {
            return "emulatie"
        }
        return name.split(whereSeparator: { " -:_.".contains($0) }).first.map(String.init) ?? "thread"
    }
}

/// The figures also go to Library/Caches/Prestaties.log, to read back from an iPhone after a test
/// (`xcrun devicectl device copy from --domain-type appDataContainer --domain-identifier app.attic`).
enum PerformanceLog {
    private static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Prestaties.log")

    static func write(_ figures: PerformanceMonitor.Figures, game: String, coreFramesPerSecond: Double, sampleRate: Double) {
        let threads = figures.threads.map { "\($0.name) \(Int($0.load * 100))%" }.joined(separator: ", ")
        let speed = figures.speed.map { "\(Int($0 * 100))%" } ?? "-"
        let line = String(format: "%@ %@ | %.1f beelden/s, %.1f rondes/s, snelheid %@ | kern meldt %.2f fps, %.0f Hz | %@\n",
                          Date.now.formatted(date: .omitted, time: .standard), game, figures.framesPerSecond,
                          figures.runsPerSecond, speed, coreFramesPerSecond, sampleRate, threads)
        // Kept small: a new file once it passes 256 kB.
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 256_000 || !FileManager.default.fileExists(atPath: url.path) {
            try? Data().write(to: url)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
