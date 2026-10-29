import Foundation
import UIKit

/// Fetches box art: from GameTDB by game code for the DS, 3DS, GameCube and Wii, and from the
/// libretro thumbnails by No-Intro or Redump name for the rest (and as a second try).
struct BoxArtFetcher {
    enum Outcome {
        case found(BoxArt)
        /// The servers answered, but none has a picture of this game.
        case notFound
        /// Offline or a server problem: worth trying again later.
        case failed

        var art: BoxArt? {
            if case .found(let art) = self { art } else { nil }
        }
    }

    let paths: LibraryPaths

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    func fetch(for game: Game) async -> Outcome {
        var failed = false
        for (url, source) in Self.candidates(for: game) {
            do {
                let (data, response) = try await Self.session.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                // Only "not there" (404) counts as no picture; a server error (500, 503, too many
                // requests) is tried again next time instead of after a month.
                guard status == 200, let image = UIImage(data: data) else {
                    if status != 404 && status != 200 {
                        failed = true
                    }
                    continue
                }
                guard let backdrop = store(image, for: game.id) else { return .failed }
                return .found(BoxArt(source: source, fetchedAt: .now, backdrop: backdrop))
            } catch {
                failed = true
            }
        }
        return failed ? .failed : .notFound
    }

    /// Where to look, best first.
    static func candidates(for game: Game) -> [(URL, BoxArt.Source)] {
        var urls: [(URL, BoxArt.Source)] = []
        if let code = game.gameCode, code.count >= 4, let art = gameTDBArt(game.system) {
            for region in gameTDBRegions(code) {
                if let url = URL(string: "https://art.gametdb.com/\(art.folder)/\(art.kind)/\(region)/\(code).\(art.format)") {
                    urls.append((url, .gameTDB))
                }
            }
        }
        if let folder = libretroFolder(for: game) {
            for name in thumbnailNames(for: game) {
                // The thumbnail files replace characters that file systems do not allow.
                let file = String(name.map { "&*/:`<>?\\|\"".contains($0) ? "_" : $0 })
                var components = URLComponents()
                components.scheme = "https"
                components.host = "thumbnails.libretro.com"
                components.path = "/\(folder)/Named_Boxarts/\(file).png"
                if let url = components.url {
                    urls.append((url, .libretro))
                }
            }
        }
        return urls
    }

    /// GameTDB's folder and picture size per system; GameCube covers live with the Wii ones.
    private static func gameTDBArt(_ system: GameSystem) -> (folder: String, kind: String, format: String)? {
        switch system {
        case .ds: ("ds", "coverM", "jpg")
        case .n3ds: ("3ds", "coverM", "jpg")
        case .gc, .wii: ("wii", "cover", "png")
        default: nil
        }
    }

    /// GameTDB sorts pictures by language; the fourth letter of the code gives the region.
    private static func gameTDBRegions(_ code: String) -> [String] {
        let letter = code[code.index(code.startIndex, offsetBy: 3)]
        let first = switch letter {
        case "E": "US"
        case "J": "JA"
        case "K": "KO"
        case "W", "C": "ZH"
        case "D": "DE"
        case "F": "FR"
        case "S": "ES"
        case "I": "IT"
        case "H": "NL"
        case "U": "AU"
        case "R": "RU"
        default: "EN"
        }
        var regions: [String] = []
        for region in [first, "EN", "US", "JA"] where !regions.contains(region) {
            regions.append(region)
        }
        return regions
    }

    private static func libretroFolder(for game: Game) -> String? {
        switch game.system {
        case .gb: game.isColor ? "Nintendo - Game Boy Color" : "Nintendo - Game Boy"
        case .gba: "Nintendo - Game Boy Advance"
        case .nes: game.fileName.lowercased().hasSuffix(".fds") ? "Nintendo - Family Computer Disk System" : "Nintendo - Nintendo Entertainment System"
        case .snes: "Nintendo - Super Nintendo Entertainment System"
        case .n64: "Nintendo - Nintendo 64"
        case .ds: "Nintendo - Nintendo DS"
        case .n3ds: "Nintendo - Nintendo 3DS"
        case .gc: "Nintendo - GameCube"
        case .wii: "Nintendo - Wii"
        case .ps1: "Sony - PlayStation"
        case .psp: "Sony - PlayStation Portable"
        case .md: "Sega - Mega Drive - Genesis"
        case .dc: "Sega - Dreamcast"
        case .arcade: nil
        }
    }

    /// The database name; without one, a file named the No-Intro way ("Super Mario 64 (USA).z64").
    private static func thumbnailNames(for game: Game) -> [String] {
        var names: [String] = []
        if let name = game.databaseName {
            names.append(name)
            // Games on several discs often have one picture for all of them.
            names.append(name.replacingOccurrences(of: #" \(Disc \d+\)"#, with: "", options: .regularExpression))
        } else {
            // A Dreamcast "disc.gdi" carries its name on the archive it came in.
            for file in [game.originalFileName, game.archiveName].compactMap({ $0 }) {
                let base = (file as NSString).deletingPathExtension
                if base.range(of: #" \([^)]+\)"#, options: .regularExpression) != nil {
                    names.append(base)
                }
            }
        }
        var unique: [String] = []
        for name in names where !unique.contains(name) {
            unique.append(name)
        }
        return unique
    }

    /// Saves the picture as a JPEG of at most 600 pixels; returns its average colour.
    private func store(_ image: UIImage, for id: UUID) -> UInt32? {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let factor = min(1, 600 / max(pixels.width, pixels.height, 1))
        let size = CGSize(width: (pixels.width * factor).rounded(), height: (pixels.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = scaled.jpegData(compressionQuality: 0.85),
              (try? data.write(to: paths.coverFile(id), options: .atomic)) != nil else { return nil }
        return Self.averageColour(scaled)
    }

    private static func averageColour(_ image: UIImage) -> UInt32 {
        guard let cgImage = image.cgImage else { return 0x202024 }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return 0x202024 }
        var sums = [0, 0, 0]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<3 {
                sums[channel] += Int(pixels[index + channel])
            }
        }
        let count = side * side
        return UInt32(sums[0] / count) << 16 | UInt32(sums[1] / count) << 8 | UInt32(sums[2] / count)
    }
}
