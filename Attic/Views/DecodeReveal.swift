import SwiftUI

// The "decode" loading effect of ascii-reveal (github.com/quanhoangindex/ascii-reveal, MIT), redone in
// SwiftUI: the idea, none of its code. A picture or a text starts as light glyphs, condenses into dense
// ones and locks into the real thing, in a wave, as its progress goes from 0 to 1.

/// How far a reveal has come: it follows its target smoothly, and a whole reveal takes at least
/// 0.9 s, so a game that unpacks at once still shows it.
struct RevealPace: Equatable {
    var from = 0.0
    var to = 0.0
    var start = Date.distantPast

    private var duration: TimeInterval { max(0.3, abs(to - from) * 0.9) }

    func value(at time: Date) -> Double {
        let t = min(1, max(0, time.timeIntervalSince(start) / duration))
        return from + (to - from) * (1 - (1 - t) * (1 - t))
    }

    func remaining(at time: Date) -> TimeInterval {
        max(0, duration - time.timeIntervalSince(start))
    }

    /// Heads for `target` from where it is now, or from `origin` to start over.
    mutating func head(to target: Double, from origin: Double? = nil) {
        let now = Date.now
        from = origin ?? value(at: now)
        to = target
        start = now
    }
}

enum Decode {
    /// Light to dense, as in ascii-reveal's decode preset.
    static let ramp = Array(" .:-=+*#%@")

    /// A stable pseudo-random number in 0..<1 for a cell or letter (and a moment, to flicker).
    static func noise(_ a: Int, _ b: Int = 0) -> Double {
        var x = UInt64(truncatingIfNeeded: a &* 73_856_093 ^ b &* 19_349_663)
        x ^= x >> 33
        x = x &* 0xff51_afd7_ed55_8ccd
        x ^= x >> 33
        x = x &* 0xc4ce_b9fe_1a85_ec53
        x ^= x >> 33
        return Double(x % 10_000) / 10_000
    }

    /// Glyph changes per second while a letter or cell is still searching.
    static let flickerRate = 12.0
}

/// A game's cover drawn in letters in the cover's own colours, that decode from the middle outwards
/// as `progress` goes from 0 to 1 and give way to the real cover at the end. Without a game the
/// letters only flicker.
struct DecodingCover: View {
    @Environment(CoverStore.self) private var covers
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let game: Game?
    let progress: Double
    let size: CGSize
    var metrics: CoverMetrics = .badge

    @State private var pace = RevealPace()
    @State private var settled = false
    @State private var cells: [Cell] = []

    private static let columns = 18
    private static let rows = 21

    struct Cell {
        let color: Color
        /// Index in `Decode.ramp`: brighter parts of the cover get denser letters.
        let density: Int
    }

    /// What the cover looks like: a new picture decodes from the start, the same one goes on.
    private var pictureKey: String {
        guard let game else { return "" }
        return "\(game.system.rawValue)/\(game.title)/\(game.boxArt?.fetchedAt.timeIntervalSince1970 ?? 0)"
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: settled && game != nil && pace.to >= 1)) { timeline in
            let shown = pace.value(at: timeline.date)
            // The real cover comes in over the last part of the reveal.
            let cover = reduceMotion ? shown : min(1, max(0, (shown - 0.92) / 0.08))
            ZStack {
                Palette.raised
                if !reduceMotion && cover < 1 {
                    Canvas { context, canvasSize in
                        draw(in: &context, size: canvasSize, shown: shown, time: timeline.date.timeIntervalSinceReferenceDate)
                    }
                    .opacity(1 - cover)
                }
                if let game {
                    GameCover(game: game, metrics: metrics, showNewBadge: false)
                        .opacity(cover)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: metrics.radius, style: .continuous))
        }
        .frame(width: size.width, height: size.height)
        .task(id: pictureKey) {
            cells = game.map(sample) ?? []
            pace.head(to: progress, from: 0)
        }
        .onChange(of: progress) { _, target in
            pace.head(to: target)
        }
        .task(id: pace) {
            settled = false
            try? await Task.sleep(for: .seconds(pace.remaining(at: .now) + 0.05))
            settled = !Task.isCancelled
        }
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, shown: Double, time: TimeInterval) {
        let width = size.width / CGFloat(Self.columns)
        let height = size.height / CGFloat(Self.rows)
        let font = Font.system(size: height * 1.15, weight: .heavy, design: .monospaced)
        let glyphs = Decode.ramp.map { context.resolve(Text(String($0)).font(font)) }
        let moment = Int(time * Decode.flickerRate)
        // The wave runs from the middle outwards and a bit beyond 1, so the corners lock too. It goes
        // by area (the squared distance), so a third of the progress shows about a third of the cover.
        let front = shown * 1.15
        let band = 0.15
        for row in 0..<Self.rows {
            for column in 0..<Self.columns {
                let index = row * Self.columns + column
                let dx = (Double(column) + 0.5) / Double(Self.columns) - 0.5
                let dy = (Double(row) + 0.5) / Double(Self.rows) - 0.5
                let threshold = min(1, (dx * dx + dy * dy) / 0.5) * 0.85 + Decode.noise(index) * 0.15
                let cell = cells.indices.contains(index) ? cells[index] : nil
                let level: Int
                let color: Color
                if let cell, front >= threshold + band {
                    level = cell.density
                    color = cell.color
                } else if let cell, front >= threshold {
                    // Condensing: from light letters to the cell's own, with a little searching.
                    let found = (front - threshold) / band
                    let jitter = Int(Decode.noise(index, moment) * 3) - 1
                    level = min(Decode.ramp.count - 1, max(1, Int((Double(cell.density) * found).rounded()) + jitter))
                    color = cell.color.opacity(0.6 + 0.4 * found)
                } else {
                    level = 1 + Int(Decode.noise(index, moment / 3) * 2)
                    color = Palette.muted.opacity(0.45)
                }
                guard level > 0 else { continue }
                var glyph = glyphs[level]
                glyph.shading = .color(color)
                context.draw(glyph, at: CGPoint(x: (CGFloat(column) + 0.5) * width, y: (CGFloat(row) + 0.5) * height))
            }
        }
    }

    /// The cover's colour per cell: the cover drawn once, then shrunk to one pixel per cell.
    private func sample(_ game: Game) -> [Cell] {
        let renderer = ImageRenderer(content: GameCover(game: game, metrics: metrics, showNewBadge: false)
            .environment(covers)
            .environment(\.accent, accent)
            .frame(width: size.width, height: size.height))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return [] }
        let columns = Self.columns
        let rows = Self.rows
        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 8,
                                          bytesPerRow: columns * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }
        guard drawn else { return [] }
        return (0..<columns * rows).map { index in
            let red = Double(pixels[index * 4]) / 255
            let green = Double(pixels[index * 4 + 1]) / 255
            let blue = Double(pixels[index * 4 + 2]) / 255
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            // A little lighter, so dark parts of a cover still show on the dark background.
            let lift = 0.2
            return Cell(color: Color(red: red + (1 - red) * lift, green: green + (1 - green) * lift, blue: blue + (1 - blue) * lift),
                        density: max(1, min(Decode.ramp.count - 1, Int(luminance * Double(Decode.ramp.count)))))
        }
    }
}

/// Text that decodes letter by letter from left to right as `progress` goes from 0 to 1: a letter
/// still to come is a light glyph, then a denser one in the accent colour, then itself. It is drawn on
/// the text's own layout, so nothing shifts. A new text decodes from the start.
struct DecodingText: View {
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    let progress: Double

    @State private var pace = RevealPace()
    @State private var settled = false

    var body: some View {
        if reduceMotion {
            Text(text)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: settled && pace.to >= 1)) { timeline in
                Text(text)
                    .textRenderer(DecodeRenderer(shown: pace.value(at: timeline.date),
                                                 moment: Int(timeline.date.timeIntervalSinceReferenceDate * Decode.flickerRate),
                                                 characters: Array(text), accent: accent))
            }
            .task(id: text) {
                pace.head(to: progress, from: 0)
            }
            .onChange(of: progress) { _, target in
                pace.head(to: target)
            }
            .task(id: pace) {
                settled = false
                try? await Task.sleep(for: .seconds(pace.remaining(at: .now) + 0.05))
                settled = !Task.isCancelled
            }
        }
    }
}

private struct DecodeRenderer: TextRenderer {
    let shown: Double
    let moment: Int
    let characters: [Character]
    let accent: Color

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let slices = layout.flatMap { line in line.flatMap { run in run.map { $0 } } }
        // Spaces stay spaces when the letters can be told apart (one glyph per character).
        let spaces = slices.count == characters.count ? characters.map(\.isWhitespace) : []
        let count = Double(max(1, slices.count))
        let front = shown * 1.3
        let band = 0.3
        for (index, slice) in slices.enumerated() {
            let threshold = Double(index) / count * 0.85 + Decode.noise(index) * 0.15
            if front >= threshold + band || (spaces.indices.contains(index) && spaces[index]) {
                context.draw(slice)
                continue
            }
            let bounds = slice.typographicBounds.rect
            let level: Int
            let color: Color
            if front >= threshold {
                let found = (front - threshold) / band
                level = min(Decode.ramp.count - 1, 4 + Int(found * 5) + Int(Decode.noise(index, moment) * 2))
                color = accent
            } else {
                level = 1 + Int(Decode.noise(index, moment / 2) * 2)
                color = Palette.muted
            }
            var glyph = context.resolve(Text(String(Decode.ramp[level]))
                .font(.system(size: bounds.height * 0.62, weight: .bold, design: .monospaced)))
            glyph.shading = .color(color)
            context.draw(glyph, at: CGPoint(x: bounds.midX, y: bounds.midY))
        }
    }
}
