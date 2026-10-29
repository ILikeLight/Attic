import Foundation
import Synchronization

/// Measures how evenly the input of each player on another iPhone comes in, before anything is
/// done to make a joined Wii Remote smoother: how many messages arrive, the gaps between them,
/// how long the network holds them up, how many get lost, and how many frames of the game see
/// nothing new. Shown under Prestaties tonen, and written to Library/Caches/Samenspelen.log (the
/// figures, every second) and Samenspelen-aankomst.csv (every message), to read back from an
/// iPhone after a test like Prestaties.log.
final class LinkMonitor: Sendable {
    struct Figures: Equatable, Identifiable {
        /// The controller port: 1 is player 2.
        let port: Int
        var id: Int { port }
        var route: String
        /// Input messages per second.
        var perSecond: Double
        /// Time between two messages coming in, in milliseconds.
        var gapMedian: Double
        var gap95: Double
        var gapMax: Double
        /// How much longer than the quickest one a message took to come in (ms): the network's
        /// unevenness, apart from the controller's. Nil from a controller that sends no stamps.
        var delay95: Double?
        var delayMax: Double?
        /// Share of the messages that never came; nil without stamps.
        var lost: Double?
        /// Share of the frames since the previous figures that got no new message, and two or more.
        var emptyFrames: Double?
        var crowdedFrames: Double?
    }

    private struct Arrival {
        /// This iPhone's uptime, in seconds.
        let time: Double
        /// The controller's uptime when it sent the message, in seconds; nil without a stamp.
        let sent: Double?
        let sequence: Int?
    }

    private struct Track {
        /// The messages of the last `window` seconds.
        var arrivals: [Arrival] = []
        var lastStamp: InputStamp?
        /// The stamp's time and number counted on past their wrapping around.
        var sent = 0.0
        var sequence = 0
        /// Messages up to this time are in the CSV file.
        var logged = 0.0
        var route = "?"
        var frames: RemotePlayers.FrameCount?
    }

    /// Seconds the figures look back.
    private static let window = 3.0
    private let tracks = Mutex<[Int: Track]>([:])

    /// A message from the player on `port` came in, on the network queue.
    func arrived(port: Int, stamp: InputStamp?) {
        let time = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        tracks.withLock { tracks in
            var track = tracks[port] ?? Track()
            var sent: Double?
            var sequence: Int?
            if let stamp {
                if let last = track.lastStamp {
                    track.sent += Double(Int32(bitPattern: stamp.sent &- last.sent)) / 10_000
                    track.sequence += Int(Int16(bitPattern: stamp.sequence &- last.sequence))
                } else {
                    track.sent = Double(stamp.sent) / 10_000
                    track.sequence = Int(stamp.sequence)
                }
                track.lastStamp = stamp
                sent = track.sent
                sequence = track.sequence
            }
            track.arrivals.append(Arrival(time: time, sent: sent, sequence: sequence))
            if let first = track.arrivals.first, time - first.time > Self.window * 2 {
                track.arrivals.removeAll { time - $0.time > Self.window }
            }
            tracks[port] = track
        }
    }

    func setRoute(_ route: String, port: Int) {
        tracks.withLock { $0[port, default: Track()].route = route }
    }

    func remove(port: Int) {
        tracks.withLock { $0[port] = nil }
    }

    /// The figures of the players on `ports`, with the frame counts of ports 1 to 3
    /// (`RemotePlayers.frameCounts`); also writes them to the log files. Called once a second.
    func figures(ports: [Int], frames: [RemotePlayers.FrameCount]) -> [Figures] {
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        var lines: [String] = []
        var rows: [String] = []
        let figures = tracks.withLock { tracks in
            ports.sorted().map { port in
                var track = tracks[port] ?? Track()
                let recent = track.arrivals.filter { now - $0.time <= Self.window }
                var figures = Self.figures(of: recent, port: port, route: track.route, span: Self.window)
                let count = (1...3).contains(port) ? frames[port - 1] : RemotePlayers.FrameCount()
                if let previous = track.frames, count.frames > previous.frames {
                    let total = Double(count.frames - previous.frames)
                    figures.emptyFrames = Double(count.empty - previous.empty) / total
                    figures.crowdedFrames = Double(count.crowded - previous.crowded) / total
                }
                track.frames = count
                for arrival in track.arrivals where arrival.time > track.logged {
                    rows.append(String(format: "%d,%.2f,%@,%@", port + 1, arrival.time * 1000,
                                       arrival.sent.map { String(format: "%.2f", $0 * 1000) } ?? "",
                                       arrival.sequence.map(String.init) ?? ""))
                }
                track.logged = track.arrivals.last?.time ?? track.logged
                tracks[port] = track
                lines.append(Self.line(figures))
                return figures
            }
        }
        if !lines.isEmpty {
            let time = Date.now.formatted(date: .omitted, time: .standard)
            Self.append(lines.map { "\(time) \($0)\n" }.joined(), to: "Samenspelen.log", header: nil)
            Self.append(rows.map { $0 + "\n" }.joined(), to: "Samenspelen-aankomst.csv",
                        header: "speler,aankomst_ms,verzonden_ms,volgnummer\n")
        }
        return figures
    }

    private static func figures(of arrivals: [Arrival], port: Int, route: String, span: Double) -> Figures {
        let gaps = zip(arrivals.dropFirst(), arrivals).map { ($0.time - $1.time) * 1000 }.sorted()
        var figures = Figures(port: port, route: route, perSecond: Double(arrivals.count) / span,
                              gapMedian: percentile(gaps, 0.5), gap95: percentile(gaps, 0.95), gapMax: gaps.last ?? 0)
        // The time on the way is unknown, as the two clocks differ, but not how much each message
        // took longer than the quickest one.
        let stamped = arrivals.compactMap { arrival in arrival.sent.map { (arrival.time - $0) * 1000 } }
        if stamped.count > 1, let quickest = stamped.min() {
            let delays = stamped.map { $0 - quickest }.sorted()
            figures.delay95 = percentile(delays, 0.95)
            figures.delayMax = delays.last
        }
        let numbers = arrivals.compactMap(\.sequence)
        if let first = numbers.min(), let last = numbers.max(), last > first {
            figures.lost = max(0, 1 - Double(Set(numbers).count) / Double(last - first + 1))
        }
        return figures
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
    }

    private static func line(_ figures: Figures) -> String {
        var parts = [String(format: "speler %d via %@ | %.0f/s | gat %.0f/%.0f/%.0f ms", figures.port + 1, figures.route,
                            figures.perSecond, figures.gapMedian, figures.gap95, figures.gapMax)]
        if let delay95 = figures.delay95, let delayMax = figures.delayMax {
            parts.append(String(format: "netwerk %.0f/%.0f ms", delay95, delayMax))
        }
        if let lost = figures.lost {
            parts.append(String(format: "kwijt %.1f%%", lost * 100))
        }
        if let empty = figures.emptyFrames, let crowded = figures.crowdedFrames {
            parts.append(String(format: "beelden leeg %.0f%%, 2+ %.0f%%", empty * 100, crowded * 100))
        }
        return parts.joined(separator: " | ")
    }

    /// Kept small: a new file once it passes 2 MB.
    private static func append(_ text: String, to name: String, header: String?) {
        guard !text.isEmpty else { return }
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 2_000_000 || !FileManager.default.fileExists(atPath: url.path) {
            try? Data((header ?? "").utf8).write(to: url)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }
}
