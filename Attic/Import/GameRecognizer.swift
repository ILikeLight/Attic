import Foundation

/// What the recognizer found out about one file.
struct Recognition {
    var system: GameSystem
    var method: RecognitionMethod
    var gameCode: String?
    var headerTitle: String?
    var region: String?
    var isColor = false
    /// Files that belong to the game, such as the .bin tracks of a .cue sheet.
    var companions: [URL] = []
    /// The part of the file that is the game itself, kept on its own when the game is imported:
    /// the NCCH inside a 3DS installation file (CIA), which is stored as a .cxi.
    var embeddedGame: (range: Range<UInt64>, fileExtension: String)?
    /// Why the game cannot be played, such as encryption; the import stops with this message.
    var unplayable: String?
    /// Short description for the import screen, e.g. "Wii-schijf · spelcode SB4P01".
    var summary: String
}

/// Recognizes games by their content: header magic, game codes and checksums.
/// The file name only counts when nothing in the file gives the system away.
enum GameRecognizer {
    static let ignoredExtensions: Set<String> = [
        "txt", "nfo", "diz", "jpg", "jpeg", "png", "gif", "bmp", "webp", "pdf", "url", "sfv", "md5", "sha1", "html", "htm",
        "db", "ini", "cfg", "xml", "json", "log", "srm", "sav", "state", "doc", "docx", "rtf", "dll", "plist", "md",
    ]

    static func recognize(_ url: URL) -> Recognition? {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent
        if ignoredExtensions.contains(ext) || name.hasPrefix(".") || name.hasPrefix("._") {
            return nil
        }
        guard let reader = HeaderReader(url: url) else { return nil }

        let checks: [() -> Recognition?] = [
            { gameBoyAdvance(reader) },
            { nintendoDS(reader, ext: ext) },
            { gameBoy(reader, ext: ext) },
            { dolphinDisc(reader, ext: ext) },
            { nintendo3DS(reader) },
            { nintendo3DSInstallFile(reader, ext: ext) },
            { nintendo64(reader) },
            { nes(reader) },
            { playStationPortable(reader, ext: ext) },
            { dreamcastCueSheet(url, ext: ext) },
            { playStation(reader, ext: ext, url: url) },
            { playStationExecutable(reader) },
            { megaDrive(reader) },
            { elfProgram(reader) },
            { superNintendo(reader, ext: ext) },
            { descriptorFile(url, ext: ext) },
            { byExtension(ext) },
        ]
        for check in checks {
            if let recognition = check() { return recognition }
        }
        return nil
    }

    // MARK: Nintendo handhelds

    /// First bytes of the Nintendo logo that every GBA and DS cartridge carries.
    private static let nintendoLogo: [UInt8] = [0x24, 0xFF, 0xAE, 0x51, 0x69, 0x9A, 0xA2, 0x21, 0x3D, 0x84, 0x82, 0x0A]

    private static func gameBoyAdvance(_ reader: HeaderReader) -> Recognition? {
        guard let header = reader.bytes(at: 0, count: 0xC0), header[0xB2] == 0x96 else { return nil }
        var checksum: UInt8 = 0
        for byte in header[0xA0...0xBC] { checksum = checksum &- byte }
        checksum = checksum &- 0x19
        let logoMatches = Array(header[4..<16]) == nintendoLogo
        guard logoMatches || checksum == header[0xBD] else { return nil }

        let code = ascii(header[0xAC..<0xB0]).flatMap(validCode)
        return Recognition(
            system: .gba,
            method: code == nil ? .header : .gameCode,
            gameCode: code,
            headerTitle: ascii(header[0xA0..<0xAC]),
            region: region(fromCode: code, disc: false),
            summary: code.map { "Game Boy Advance · spelcode \($0)" } ?? "Game Boy Advance · herkend aan de spelkop"
        )
    }

    private static func nintendoDS(_ reader: HeaderReader, ext: String) -> Recognition? {
        guard let header = reader.bytes(at: 0, count: 0x200) else { return nil }
        // Homebrew may leave out the logo, but its header checksum is still right.
        let storedChecksum = UInt16(header[0x15E]) | UInt16(header[0x15F]) << 8
        guard Array(header[0xC0..<0xCC]) == nintendoLogo || (ext == "nds" && crc16(header[0..<0x15E]) == storedChecksum) else {
            return nil
        }
        let code = ascii(header[0x0C..<0x10]).flatMap(validCode)
        return Recognition(
            system: .ds,
            method: code == nil ? .header : .gameCode,
            gameCode: code,
            headerTitle: ascii(header[0x00..<0x0C]),
            region: region(fromCode: code, disc: false),
            summary: code.map { "Nintendo DS · spelcode \($0)" } ?? "Nintendo DS · herkend aan de spelkop"
        )
    }

    private static func gameBoy(_ reader: HeaderReader, ext: String) -> Recognition? {
        guard let header = reader.bytes(at: 0, count: 0x150) else { return nil }
        let logo: [UInt8] = [0xCE, 0xED, 0x66, 0x66, 0xCC, 0x0D, 0x00, 0x0B]
        var checksum: UInt8 = 0
        for byte in header[0x134...0x14C] { checksum = checksum &- byte &- 1 }
        let logoMatches = Array(header[0x104..<0x10C]) == logo
        guard logoMatches || (checksum == header[0x14D] && ["gb", "gbc", "sgb"].contains(ext)) else { return nil }

        let colorFlag = header[0x143]
        let isColor = colorFlag == 0x80 || colorFlag == 0xC0
        let title = ascii(header[0x134..<(isColor ? 0x143 : 0x144)])
        return Recognition(
            system: .gb,
            method: .header,
            headerTitle: title,
            region: header[0x14A] == 0 ? "JPN" : nil,
            isColor: isColor,
            summary: isColor ? "Game Boy Color · herkend aan de spelkop" : "Game Boy · herkend aan de spelkop"
        )
    }

    private static func nintendo3DS(_ reader: HeaderReader) -> Recognition? {
        guard let magic = reader.bytes(at: 0x100, count: 4) else { return nil }
        var ncch: UInt64?
        if magic == Array("NCSD".utf8), let table = reader.bytes(at: 0x120, count: 4) {
            ncch = UInt64(le32(table, 0)) * 0x200
        } else if magic == Array("NCCH".utf8) {
            ncch = 0
        }
        if let ncch, let game = threeDSGame(reader, at: ncch) {
            return Recognition(
                system: .n3ds,
                method: game.code == nil ? .header : .gameCode,
                gameCode: game.code,
                region: region(fromCode: game.code, disc: false),
                unplayable: game.encrypted ? encrypted3DS : nil,
                summary: game.code.map { "Nintendo 3DS · spelcode \($0)" } ?? "Nintendo 3DS · herkend aan de spelkop"
            )
        }
        if reader.bytes(at: 0, count: 4) == Array("3DSX".utf8) {
            return Recognition(system: .n3ds, method: .header, summary: "Nintendo 3DS · homebrew (3DSX)")
        }
        return nil
    }

    private static let encrypted3DS = "Dit 3DS-spel is versleuteld, en Azahar speelt alleen ontsleutelde spellen. Ontsleutel het met je eigen 3DS, bijvoorbeeld met GodMode9."

    /// The game code of the NCCH (a 3DS program) at `offset`, and whether it is still encrypted,
    /// which Azahar can no longer undo: its NoCrypto flag is off.
    private static func threeDSGame(_ reader: HeaderReader, at offset: UInt64) -> (code: String?, encrypted: Bool)? {
        guard let header = reader.bytes(at: offset + 0x100, count: 0x90), Array(header[0..<4]) == Array("NCCH".utf8) else { return nil }
        let product = ascii(header[0x50..<0x60])
        let code = product.flatMap { $0.split(separator: "-").last.map(String.init) }.flatMap(validCode)
        return (code, header[0x8F] & 0x04 == 0)
    }

    /// A 3DS installation file (CIA). Its first content is the game itself, an NCCH as in a .cxi,
    /// which Azahar starts without installing anything.
    private static func nintendo3DSInstallFile(_ reader: HeaderReader, ext: String) -> Recognition? {
        guard ext == "cia", let header = reader.bytes(at: 0, count: 0x20), le32(header, 0) == 0x2020 else { return nil }
        // Certificates, ticket, title metadata and contents follow the header, each on a 64-byte boundary.
        func aligned(_ value: UInt64) -> UInt64 { (value + 63) & ~63 }
        let certificates = aligned(0x2020)
        let ticket = aligned(certificates + UInt64(le32(header, 0x08)))
        let metadata = aligned(ticket + UInt64(le32(header, 0x0C)))
        let contents = aligned(metadata + UInt64(le32(header, 0x10)))
        guard let signature = reader.bytes(at: metadata, count: 4) else { return nil }
        let signatureSize: UInt64 = switch be32(signature, 0) {
        case 0x10003: 0x200 + 0x3C  // RSA-4096
        case 0x10004: 0x100 + 0x3C  // RSA-2048
        case 0x10005: 0x3C + 0x40   // ECDSA
        default: 0
        }
        // The title metadata's header, its content info table, then one record per content.
        let record = 0xC4 + 0x900
        guard signatureSize > 0, let title = reader.bytes(at: metadata + 4 + signatureSize, count: record + 0x30) else { return nil }
        let kind = be64(title, 0x4C) >> 32
        let encryptedContent = title[record + 7] & 0x01 != 0
        let length = be64(title, record + 8)
        let game = threeDSGame(reader, at: contents)

        var problem: String?
        if kind != 0x0004_0000 && kind != 0x0004_0002 {
            problem = "Dit is een update of extra inhoud voor een 3DS-spel, geen spel. Die kan Attic nog niet installeren."
        } else if encryptedContent || game == nil || game?.encrypted == true {
            problem = encrypted3DS
        }
        let code = game?.code
        return Recognition(
            system: .n3ds,
            method: code == nil ? .header : .gameCode,
            gameCode: code,
            region: region(fromCode: code, disc: false),
            embeddedGame: (contents..<(contents + length), "cxi"),
            unplayable: problem,
            summary: "Nintendo 3DS · installatiebestand (CIA)" + (code.map { ", spelcode \($0)" } ?? "")
        )
    }

    // MARK: Wii and GameCube

    private static func dolphinDisc(_ reader: HeaderReader, ext: String) -> Recognition? {
        guard let start = reader.bytes(at: 0, count: 8) else { return nil }
        var headerOffset: UInt64?
        var container = "schijf"
        if start.starts(with: Array("WBFS".utf8)) {
            headerOffset = 0x200
            container = "WBFS"
        } else if start.starts(with: Array("RVZ".utf8) + [1]) || start.starts(with: Array("WIA".utf8) + [1]) {
            headerOffset = 0x58
            container = start[0] == UInt8(ascii: "R") ? "RVZ" : "WIA"
        } else if start.starts(with: Array("CISO".utf8)) && ext != "cso" {
            headerOffset = 0x8000
            container = "CISO"
        } else {
            headerOffset = 0
        }
        guard let offset = headerOffset, let header = reader.bytes(at: offset, count: 0x60) else { return nil }
        let isWii = Array(header[0x18..<0x1C]) == [0x5D, 0x1C, 0x9E, 0xA3]
        let isGameCube = Array(header[0x1C..<0x20]) == [0xC2, 0x33, 0x9F, 0x3D]
        guard isWii || isGameCube else { return nil }

        let code = ascii(header[0x00..<0x06]).flatMap(validCode)
        let system: GameSystem = isWii ? .wii : .gc
        let kind = isWii ? "Wii-schijf" : "GameCube-schijf"
        let label = container == "schijf" ? kind : "\(kind) (\(container))"
        return Recognition(
            system: system,
            method: code == nil ? .header : .gameCode,
            gameCode: code,
            headerTitle: ascii(header[0x20..<0x60]),
            region: region(fromCode: code, disc: true),
            summary: code.map { "\(label) · spelcode \($0)" } ?? label
        )
    }

    // MARK: Other Nintendo

    private static func nintendo64(_ reader: HeaderReader) -> Recognition? {
        guard var header = reader.bytes(at: 0, count: 0x40) else { return nil }
        switch Array(header[0..<4]) {
        case [0x80, 0x37, 0x12, 0x40]:
            break
        case [0x37, 0x80, 0x40, 0x12]:
            for i in stride(from: 0, to: header.count, by: 2) { header.swapAt(i, i + 1) }
        case [0x40, 0x12, 0x37, 0x80]:
            for i in stride(from: 0, to: header.count, by: 4) {
                header.swapAt(i, i + 3)
                header.swapAt(i + 1, i + 2)
            }
        default:
            return nil
        }
        let code = ascii(header[0x3B..<0x3F]).flatMap(validCode)
        return Recognition(
            system: .n64,
            method: code == nil ? .header : .gameCode,
            gameCode: code,
            headerTitle: ascii(header[0x20..<0x34]),
            region: region(fromCode: code, disc: false),
            summary: code.map { "Nintendo 64 · spelcode \($0)" } ?? "Nintendo 64 · herkend aan de spelkop"
        )
    }

    private static func nes(_ reader: HeaderReader) -> Recognition? {
        guard let magic = reader.bytes(at: 0, count: 4) else { return nil }
        if magic == [0x4E, 0x45, 0x53, 0x1A] {
            return Recognition(system: .nes, method: .header, summary: "NES · iNES-kop gevonden")
        }
        if magic == [0x46, 0x44, 0x53, 0x1A] {
            return Recognition(system: .nes, method: .header, summary: "Famicom Disk System")
        }
        return nil
    }

    private static func superNintendo(_ reader: HeaderReader, ext: String) -> Recognition? {
        let copierHeader: UInt64 = reader.size % 1024 == 512 ? 512 : 0
        for base in [0x7FC0, 0xFFC0, 0x40FFC0] as [UInt64] {
            guard let header = reader.bytes(at: base + copierHeader, count: 32) else { continue }
            let complement = UInt16(header[0x1C]) | UInt16(header[0x1D]) << 8
            let checksum = UInt16(header[0x1E]) | UInt16(header[0x1F]) << 8
            let titleBytes = header[0..<21]
            let printable = titleBytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
            guard complement ^ checksum == 0xFFFF, printable || ["sfc", "smc"].contains(ext) else { continue }
            let region: String? = switch header[0x19] {
            case 0: "JPN"
            case 1: "USA"
            case 2...12: "EUR"
            default: nil
            }
            return Recognition(system: .snes, method: .header, headerTitle: ascii(titleBytes), region: region,
                               summary: "Super Nintendo · herkend aan de spelkop")
        }
        return nil
    }

    // MARK: Sony

    private static func playStationPortable(_ reader: HeaderReader, ext: String) -> Recognition? {
        if let volume = reader.bytes(at: 0x8000, count: 0x28), Array(volume[1..<6]) == Array("CD001".utf8),
           ascii(volume[8..<0x28])?.hasPrefix("PSP GAME") == true {
            let info = GameFingerprint.playStationPortableInfo(reader)
            let code = info?.serial
            return Recognition(
                system: .psp,
                method: code == nil ? .header : .gameCode,
                gameCode: code,
                headerTitle: info?.title,
                region: code.flatMap(regionFromSonyCode),
                summary: code.map { "PSP · spelcode \($0)" } ?? "PSP · UMD-schijf"
            )
        }
        if ext == "cso", reader.bytes(at: 0, count: 4) == Array("CISO".utf8) {
            return Recognition(system: .psp, method: .header, summary: "PSP · gecomprimeerde UMD (CSO)")
        }
        if reader.bytes(at: 0, count: 4) == [0x00, 0x50, 0x42, 0x50], let header = reader.bytes(at: 0, count: 0x28) {
            let sfoOffset = UInt64(le32(header, 0x08))
            let sfoEnd = UInt64(le32(header, 0x0C))
            if sfoEnd > sfoOffset, sfoEnd - sfoOffset < 0x10000, let sfo = reader.bytes(at: sfoOffset, count: Int(sfoEnd - sfoOffset)) {
                let values = parseSFO(sfo)
                let isPS1 = values["CATEGORY"] == "ME"
                let code = values["DISC_ID"].map { GameFingerprint.formattedSonySerial($0) ?? $0 }
                return Recognition(
                    system: isPS1 ? .ps1 : .psp,
                    method: code == nil ? .header : .gameCode,
                    gameCode: code,
                    headerTitle: values["TITLE"],
                    region: code.flatMap(regionFromSonyCode),
                    summary: code.map { "\(isPS1 ? "PlayStation" : "PSP") · spelcode \($0)" } ?? (isPS1 ? "PlayStation (EBOOT)" : "PSP (EBOOT)")
                )
            }
        }
        return nil
    }

    private static func playStation(_ reader: HeaderReader, ext: String, url: URL) -> Recognition? {
        if ext == "cue" {
            let companions = cueTracks(url)
            if let first = companions.first, let track = HeaderReader(url: first), isPlayStationImage(track) {
                return playStationDisc(track, companions: companions, summary: "PlayStation-schijf · cue-sheet")
            }
            return Recognition(system: .ps1, method: .fileExtension, companions: companions, summary: "PlayStation · cue-sheet")
        }
        if ext == "chd", reader.bytes(at: 0, count: 8) == Array("MComprHD".utf8) {
            if chdIsGDROM(reader) {
                return Recognition(system: .dc, method: .header, summary: "Dreamcast · GD-ROM (CHD)")
            }
            return Recognition(system: .ps1, method: .header, summary: "Schijf (CHD) · aangenomen PlayStation")
        }
        if isPlayStationImage(reader) {
            return playStationDisc(reader, companions: [], summary: "PlayStation-schijf · herkend aan de schijfkop")
        }
        return nil
    }

    /// A PlayStation disc, with the game code from SYSTEM.CNF when it has one.
    private static func playStationDisc(_ reader: HeaderReader, companions: [URL], summary: String) -> Recognition {
        let code = GameFingerprint.playStationSerial(reader)
        return Recognition(
            system: .ps1,
            method: code == nil ? .header : .gameCode,
            gameCode: code,
            region: code.flatMap(regionFromSonyCode),
            companions: companions,
            summary: code.map { "PlayStation-schijf · spelcode \($0)" } ?? summary
        )
    }

    private static func isPlayStationImage(_ reader: HeaderReader) -> Bool {
        let sync: [UInt8] = [0x00] + Array(repeating: 0xFF, count: 10) + [0x00]
        if reader.bytes(at: 0, count: 12) == sync {
            // Raw 2352-byte sectors: the volume descriptor is sector 16, after a 24-byte header.
            return reader.bytes(at: 16 * 2352 + 24 + 8, count: 11) == Array("PLAYSTATION".utf8)
        }
        return reader.bytes(at: 0x8008, count: 11) == Array("PLAYSTATION".utf8)
    }

    /// A bare PlayStation program, as homebrew and test programs come.
    private static func playStationExecutable(_ reader: HeaderReader) -> Recognition? {
        guard reader.bytes(at: 0, count: 8) == Array("PS-X EXE".utf8) else { return nil }
        return Recognition(system: .ps1, method: .header, summary: "PlayStation · programma (PS-EXE)")
    }

    /// A homebrew program as an ELF file; its machine type says for which console.
    private static func elfProgram(_ reader: HeaderReader) -> Recognition? {
        guard let header = reader.bytes(at: 0, count: 20), Array(header[0..<4]) == [0x7F, 0x45, 0x4C, 0x46] else { return nil }
        let machine = header[5] == 2 ? UInt16(header[18]) << 8 | UInt16(header[19]) : UInt16(header[18]) | UInt16(header[19]) << 8
        switch machine {
        case 42: return Recognition(system: .dc, method: .header, summary: "Dreamcast · programma (ELF)")
        // Dolphin sees itself whether a PowerPC program is for the GameCube or the Wii.
        case 20: return Recognition(system: .gc, method: .header, summary: "GameCube of Wii · programma (ELF)")
        default: return nil
        }
    }

    // MARK: Sega

    private static func megaDrive(_ reader: HeaderReader) -> Recognition? {
        guard let header = reader.bytes(at: 0x100, count: 0x100),
              ascii(header[0..<16])?.hasPrefix("SEGA") == true || ascii(header[1..<16])?.hasPrefix("SEGA") == true else { return nil }
        let overseas = ascii(header[0x50..<0x80])
        let domestic = ascii(header[0x20..<0x50])
        return Recognition(system: .md, method: .header, headerTitle: overseas ?? domestic, summary: "Mega Drive · herkend aan de spelkop")
    }

    /// What the boot header (IP.BIN) at the start of a Dreamcast disc's data track says.
    private struct DreamcastHeader {
        var productNumber: String?
        var region: String?
        var title: String?
    }

    private static func dreamcastHeader(_ reader: HeaderReader) -> DreamcastHeader? {
        // Raw 2352-byte sectors start with a 16-byte header (24 in mode 2); 2048-byte images hold the data only.
        for offset: UInt64 in [16, 24, 0] {
            guard let meta = reader.bytes(at: offset, count: 0x100), Array(meta[0..<15]) == Array("SEGA SEGAKATANA".utf8) else { continue }
            // One letter per area the disc is sold in: J, U and E. A disc for one area gives the region.
            let areas = zip(meta[0x30..<0x33], ["JPN", "USA", "EUR"]).filter { $0.0 > 0x20 }.map(\.1)
            return DreamcastHeader(productNumber: ascii(meta[0x40..<0x4A]), region: areas.count == 1 ? areas[0] : nil,
                                   title: ascii(meta[0x80..<0x100]))
        }
        return nil
    }

    /// A Dreamcast disc as a cue sheet, the way Redump stores GD-ROMs: the sheet marks the
    /// high-density area, and a data track starts with the boot header. Other cue sheets are left
    /// to the PlayStation.
    private static func dreamcastCueSheet(_ url: URL, ext: String) -> Recognition? {
        guard ext == "cue" else { return nil }
        let companions = cueTracks(url)
        let header = companions.lazy.compactMap { HeaderReader(url: $0).flatMap(dreamcastHeader) }.first
        let sheet = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
        guard header != nil || sheet.uppercased().contains("HIGH-DENSITY AREA") else { return nil }
        return dreamcastDisc(header, companions: companions, summary: "Dreamcast · GD-ROM (cue-sheet)")
    }

    private static func dreamcastDisc(_ header: DreamcastHeader?, companions: [URL], summary: String) -> Recognition {
        let code = header?.productNumber
        return Recognition(system: .dc, method: code == nil ? .header : .gameCode, gameCode: code, headerTitle: header?.title,
                           region: header?.region, companions: companions,
                           summary: code.map { "Dreamcast-schijf · spelcode \($0)" } ?? summary)
    }

    private static func chdIsGDROM(_ reader: HeaderReader) -> Bool {
        guard let header = reader.bytes(at: 0, count: 0x40), be32(header, 12) == 5 else { return false }
        var offset = be64(header, 0x30)
        var visited = 0
        while offset != 0, visited < 64, let entry = reader.bytes(at: offset, count: 16) {
            if Array(entry[0..<4]) == Array("CHGD".utf8) { return true }
            offset = be64(entry, 8)
            visited += 1
        }
        return false
    }

    // MARK: Descriptor files and extensions

    private static func descriptorFile(_ url: URL, ext: String) -> Recognition? {
        guard ext == "gdi" else { return nil }
        let companions = gdiTracks(url)
        let header = companions.lazy.compactMap { HeaderReader(url: $0).flatMap(dreamcastHeader) }.first
        return dreamcastDisc(header, companions: companions, summary: "Dreamcast · GD-ROM (GDI)")
    }

    private static func byExtension(_ ext: String) -> Recognition? {
        let unambiguous: [String: GameSystem] = [
            "gba": .gba, "agb": .gba, "gb": .gb, "gbc": .gb, "nds": .ds, "3ds": .n3ds, "cci": .n3ds, "cia": .n3ds,
            "3dsx": .n3ds, "z64": .n64, "n64": .n64, "v64": .n64, "sfc": .snes, "smc": .snes, "nes": .nes,
            "rvz": .wii, "wbfs": .wii, "wad": .wii, "gcz": .gc, "gcm": .gc, "cso": .psp, "md": .md, "gen": .md,
            "smd": .md, "cdi": .dc, "gdi": .dc,
            // Homebrew for the GameCube or Wii; Dolphin sees which of the two it is.
            "dol": .gc,
        ]
        guard let system = unambiguous[ext] else { return nil }
        return Recognition(system: system, method: .fileExtension, summary: "\(system.name) · herkend aan de extensie")
    }

    /// Track files named in a .cue sheet.
    static func cueTracks(_ url: URL) -> [URL] {
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
            return []
        }
        let folder = url.deletingLastPathComponent()
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.uppercased().hasPrefix("FILE ") else { return nil }
            let rest = trimmed.dropFirst(5)
            let name: Substring
            if rest.first == "\"", let end = rest.dropFirst().firstIndex(of: "\"") {
                name = rest[rest.index(after: rest.startIndex)..<end]
            } else {
                name = rest.split(separator: " ").first ?? ""
            }
            let track = folder.appendingPathComponent(String(name))
            return FileManager.default.fileExists(atPath: track.path) ? track : nil
        }
    }

    /// Track files named in a Dreamcast .gdi file.
    static func gdiTracks(_ url: URL) -> [URL] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let folder = url.deletingLastPathComponent()
        return text.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 5 else { return nil }
            var name = String(fields[4])
            if name.hasPrefix("\""), let quoted = line.split(separator: "\"").dropFirst().first {
                name = String(quoted)
            }
            let track = folder.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: track.path) ? track : nil
        }
    }

    // MARK: Helpers

    /// Region from the fourth character of a Nintendo game code (SB4P01 → P → PAL).
    static func region(fromCode code: String?, disc: Bool) -> String? {
        guard let code, code.count >= 4 else { return nil }
        let letter = code[code.index(code.startIndex, offsetBy: 3)]
        switch letter {
        case "E": return "USA"
        case "J": return "JPN"
        case "K": return "KOR"
        case "C": return "CHN"
        case "W": return "TWN"
        case "A": return "Wereld"
        case "P", "D", "F", "S", "I", "H", "X", "Y", "Z", "U", "V", "L", "M", "R": return disc ? "PAL" : "EUR"
        default: return nil
        }
    }

    private static func regionFromSonyCode(_ code: String) -> String? {
        if code.hasPrefix("SLES") || code.hasPrefix("SCES") || code.hasPrefix("ULES") || code.hasPrefix("UCES") { return "EUR" }
        if code.hasPrefix("SLUS") || code.hasPrefix("SCUS") || code.hasPrefix("ULUS") || code.hasPrefix("UCUS") { return "USA" }
        if code.hasPrefix("SLPS") || code.hasPrefix("SCPS") || code.hasPrefix("SLPM") || code.hasPrefix("ULJS") || code.hasPrefix("ULJM") || code.hasPrefix("UCJS") { return "JPN" }
        return nil
    }

    /// Region from tags such as "(Europe)" or "(USA, Europe)" in a file name.
    static func region(fromFileName name: String) -> String? {
        let lower = name.lowercased()
        let tags: [(String, String)] = [
            ("(world)", "Wereld"), ("(usa, europe)", "USA/EUR"), ("(europe)", "EUR"), ("(usa)", "USA"), ("(japan)", "JPN"),
            ("(germany)", "EUR"), ("(france)", "EUR"), ("(netherlands)", "EUR"), ("(spain)", "EUR"), ("(italy)", "EUR"),
            ("(korea)", "KOR"), ("(e)", "EUR"), ("(u)", "USA"), ("(j)", "JPN"), ("(pal)", "PAL"), ("(ntsc)", "USA"),
        ]
        return tags.first { lower.contains($0.0) }?.1
    }

    private static func validCode(_ code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 4, trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return trimmed.uppercased()
    }

    /// Printable ASCII up to the first zero byte, trimmed; nil when empty or binary.
    static func ascii(_ bytes: ArraySlice<UInt8>) -> String? {
        let text = bytes.prefix { $0 != 0 }
        guard !text.isEmpty, text.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        let string = String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return string.isEmpty ? nil : string
    }

    static func parseSFO(_ data: [UInt8]) -> [String: String] {
        guard data.count >= 20, Array(data[0..<4]) == [0x00, 0x50, 0x53, 0x46] else { return [:] }
        let keyTable = Int(le32(data, 8))
        let dataTable = Int(le32(data, 12))
        let count = Int(le32(data, 16))
        var values: [String: String] = [:]
        for index in 0..<min(count, 64) {
            let entry = 20 + index * 16
            guard entry + 16 <= data.count else { break }
            let keyOffset = keyTable + Int(UInt16(data[entry]) | UInt16(data[entry + 1]) << 8)
            let format = UInt16(data[entry + 2]) | UInt16(data[entry + 3]) << 8
            let length = Int(le32(data, entry + 4))
            let valueOffset = dataTable + Int(le32(data, entry + 12))
            guard keyOffset < data.count, valueOffset + length <= data.count, format == 0x0204 else { continue }
            let key = String(decoding: data[keyOffset...].prefix { $0 != 0 }, as: UTF8.self)
            let value = String(decoding: data[valueOffset..<(valueOffset + length)].prefix { $0 != 0 }, as: UTF8.self)
            values[key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return values
    }

    /// CRC-16 as used in Nintendo DS headers (initial value 0xFFFF, polynomial 0xA001).
    private static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }

    private static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func be64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        UInt64(be32(bytes, offset)) << 32 | UInt64(be32(bytes, offset + 4))
    }
}

/// Reads parts of a file: the first 64 KB are kept in memory, the rest is read on demand.
final class HeaderReader {
    let size: UInt64
    private let handle: FileHandle
    private let prefix: [UInt8]

    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = try? handle.seekToEnd() else { return nil }
        self.handle = handle
        self.size = size
        try? handle.seek(toOffset: 0)
        prefix = [UInt8]((try? handle.read(upToCount: 0x10000)) ?? Data())
    }

    deinit {
        try? handle.close()
    }

    func bytes(at offset: UInt64, count: Int) -> [UInt8]? {
        guard count > 0, offset + UInt64(count) <= size else { return nil }
        if offset + UInt64(count) <= UInt64(prefix.count) {
            return Array(prefix[Int(offset)..<(Int(offset) + count)])
        }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: count), data.count == count else { return nil }
        return [UInt8](data)
    }
}
