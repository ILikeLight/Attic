import Foundation
import SevenZip

/// What identifies a dump in the No-Intro and Redump lists of the libretro-database.
enum GameFingerprint {
    /// CRC32 as No-Intro lists it: without the iNES or copier header, N64 in big-endian order.
    static func romCRC32(_ url: URL, system: GameSystem) -> UInt32? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = [UInt8]((try? handle.read(upToCount: 16)) ?? Data())
        var skip: UInt64 = 0
        var wordSwap = 0
        switch system {
        case .nes where head.starts(with: [0x4E, 0x45, 0x53, 0x1A]) && head.count == 16:
            skip = 16 + (head[6] & 0x04 != 0 ? 512 : 0)   // a trainer follows the header
        case .nes where head.starts(with: [0x46, 0x44, 0x53, 0x1A]):
            skip = 16                                       // Famicom Disk System header
        case .snes:
            skip = ((try? handle.seekToEnd()) ?? 0) % 1024 == 512 ? 512 : 0
        case .n64 where head.starts(with: [0x37, 0x80, 0x40, 0x12]):
            wordSwap = 2                                    // .v64: bytes swapped in pairs
        case .n64 where head.starts(with: [0x40, 0x12, 0x37, 0x80]):
            wordSwap = 4                                    // .n64: little-endian words
        default:
            break
        }
        guard (try? handle.seek(toOffset: skip)) != nil else { return nil }
        var crc: UInt32 = 0
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            var data = chunk
            if wordSwap > 0 {
                data.withUnsafeMutableBytes { raw in
                    let bytes = raw.bindMemory(to: UInt8.self)
                    for start in stride(from: 0, to: bytes.count - wordSwap + 1, by: wordSwap) {
                        if wordSwap == 2 {
                            bytes.swapAt(start, start + 1)
                        } else {
                            bytes.swapAt(start, start + 3)
                            bytes.swapAt(start + 1, start + 2)
                        }
                    }
                }
            }
            crc = data.withUnsafeBytes { attic_crc32(crc, $0.baseAddress, $0.count) }
        }
        return crc
    }

    /// The game code a PlayStation disc boots, from SYSTEM.CNF: "SCUS-94900".
    static func playStationSerial(_ reader: HeaderReader) -> String? {
        guard let disc = DiscImage(reader), let file = disc.file(["SYSTEM.CNF"]) else { return nil }
        let text = String(decoding: file, as: UTF8.self)
        // BOOT = cdrom:\SCUS_949.00;1
        guard let boot = text.range(of: #"BOOT\s*=\s*cdrom0?:\\*([^;\s]+)"#, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let program = text[boot].split(whereSeparator: { $0 == "\\" || $0 == ":" }).last.map(String.init) ?? ""
        return formattedSonySerial(program)
    }

    /// DISC_ID and TITLE of a PSP UMD image, from PSP_GAME/PARAM.SFO.
    static func playStationPortableInfo(_ reader: HeaderReader) -> (serial: String?, title: String?)? {
        guard let disc = DiscImage(reader), let file = disc.file(["PSP_GAME", "PARAM.SFO"]) else { return nil }
        let values = GameRecognizer.parseSFO(file)
        return (values["DISC_ID"].flatMap(formattedSonySerial), values["TITLE"])
    }

    /// "SCUS_949.00" or "ULUS10336" → "SCUS-94900" / "ULUS-10336", as the cases print them.
    static func formattedSonySerial(_ raw: String) -> String? {
        let key = GameDatabase.serialKey(raw)
        guard key.count >= 8, key.prefix(4).allSatisfy(\.isLetter), key.dropFirst(4).allSatisfy(\.isNumber) else { return nil }
        return "\(key.prefix(4))-\(key.dropFirst(4))"
    }
}

/// Reads small files from an ISO 9660 disc image with 2048-byte sectors or raw 2352-byte ones.
struct DiscImage {
    private let reader: HeaderReader
    private let sectorSize: UInt64
    private let dataOffset: UInt64

    init?(_ reader: HeaderReader) {
        self.reader = reader
        let sync: [UInt8] = [0x00] + Array(repeating: 0xFF, count: 10) + [0x00]
        if reader.bytes(at: 0, count: 12) == sync {
            // Raw sectors: data starts after the header, which is longer in mode 2 (PlayStation).
            sectorSize = 2352
            dataOffset = reader.bytes(at: 15, count: 1) == [2] ? 24 : 16
        } else {
            sectorSize = 2048
            dataOffset = 0
        }
        guard let volume = sector(16), Array(volume[1..<6]) == Array("CD001".utf8) else { return nil }
    }

    private func sector(_ number: UInt64) -> [UInt8]? {
        reader.bytes(at: number * sectorSize + dataOffset, count: 2048)
    }

    /// The contents of a file such as ["PSP_GAME", "PARAM.SFO"], if it is small.
    func file(_ path: [String], maxSize: Int = 64 << 10) -> [UInt8]? {
        guard let volume = sector(16) else { return nil }
        // The root directory's record sits at offset 156 of the volume descriptor.
        var extent = UInt64(Self.le32(volume, 156 + 2))
        var size = Int(Self.le32(volume, 156 + 10))
        for component in path {
            guard let record = find(component, inDirectoryAt: extent, size: size) else { return nil }
            (extent, size) = record
        }
        guard size <= maxSize else { return nil }
        var contents: [UInt8] = []
        for index in 0..<UInt64((size + 2047) / 2048) {
            guard let data = sector(extent + index) else { return nil }
            contents += data
        }
        return Array(contents.prefix(size))
    }

    private func find(_ name: String, inDirectoryAt extent: UInt64, size: Int) -> (UInt64, Int)? {
        let wanted = name.uppercased()
        for index in 0..<UInt64(min((size + 2047) / 2048, 64)) {
            guard let data = sector(extent + index) else { return nil }
            var offset = 0
            while offset + 33 < data.count {
                let length = Int(data[offset])
                guard length > 0 else { break }   // the rest of the sector is padding
                let nameLength = Int(data[offset + 32])
                if offset + 33 + nameLength <= data.count {
                    let recordName = String(decoding: data[(offset + 33)..<(offset + 33 + nameLength)], as: UTF8.self)
                    if recordName.split(separator: ";").first.map({ $0.uppercased() }) == wanted {
                        return (UInt64(Self.le32(data, offset + 2)), Int(Self.le32(data, offset + 10)))
                    }
                }
                offset += length
            }
        }
        return nil
    }

    private static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
