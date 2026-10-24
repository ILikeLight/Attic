import Compression
import Foundation
import SevenZip

enum ArchiveError: LocalizedError {
    case unreadable
    case corrupt
    case encrypted
    case unsupported
    case outOfMemory
    case writeFailed
    case cancelled

    init(sevenZipStatus status: Int32) {
        switch status {
        case 1: self = .unreadable
        case 3: self = .unsupported
        case 5: self = .outOfMemory
        case 6: self = .writeFailed
        case 7: self = .cancelled
        default: self = .corrupt
        }
    }

    var errorDescription: String? {
        switch self {
        case .unreadable: "Het archief kon niet worden geopend"
        case .corrupt: "Het archief is beschadigd of onvolledig"
        case .encrypted: "Dit archief is beveiligd met een wachtwoord"
        case .unsupported: "Dit archief gebruikt een compressiemethode die Attic nog niet kent"
        case .outOfMemory: "Niet genoeg geheugen om dit archief uit te pakken"
        case .writeFailed: "Uitpakken mislukt. Is er genoeg opslagruimte?"
        case .cancelled: "Uitpakken gestopt"
        }
    }
}

enum ArchiveKind {
    case zip, sevenZip

    /// Looks at the first bytes, not at the extension.
    static func detect(_ url: URL) -> ArchiveKind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 6), data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        if bytes[0] == 0x50, bytes[1] == 0x4B, (bytes[2] == 3 && bytes[3] == 4) || (bytes[2] == 5 && bytes[3] == 6) {
            return .zip
        }
        if bytes.count == 6, bytes == [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C] {
            return .sevenZip
        }
        return nil
    }
}

protocol Archive: AnyObject {
    /// Total unpacked size of all files, for the progress bar.
    var totalSize: UInt64 { get }
    /// Extracts everything into `directory`. `progress` gets the bytes written so far and returns false to cancel.
    func extractAll(to directory: URL, progress: @escaping (UInt64) -> Bool) throws
}

func openArchive(_ url: URL, kind: ArchiveKind) throws -> Archive {
    switch kind {
    case .zip: try ZipArchive(url: url)
    case .sevenZip: try SevenZipArchive(url: url)
    }
}

/// Makes a relative path from an archive safe to use: no absolute paths, no "..".
func sanitizedArchivePath(_ path: String) -> String? {
    let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        .map(String.init)
        .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
    return parts.isEmpty ? nil : parts.joined(separator: "/")
}

// MARK: - 7z

private final class ProgressBox {
    let report: (UInt64) -> Bool
    init(_ report: @escaping (UInt64) -> Bool) { self.report = report }
}

/// A .7z archive, read with the LZMA SDK of 7-Zip (AtticCores/Sources/SevenZip).
final class SevenZipArchive: Archive {
    private let handle: OpaquePointer

    init(url: URL) throws {
        var status: Int32 = 0
        let opened = url.withUnsafeFileSystemRepresentation { path in
            path.flatMap { attic_7z_open($0, &status) }
        }
        guard let opened else { throw ArchiveError(sevenZipStatus: status) }
        handle = opened
    }

    deinit {
        attic_7z_close(handle)
    }

    var totalSize: UInt64 { attic_7z_total_size(handle) }

    func extractAll(to directory: URL, progress: @escaping (UInt64) -> Bool) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let box = ProgressBox(progress)
        let context = Unmanaged.passUnretained(box).toOpaque()
        let status = directory.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return 6 }
            return attic_7z_extract_all(handle, path, { context, written in
                guard let context else { return true }
                return Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue().report(written)
            }, context)
        }
        withExtendedLifetime(box) {}
        if status != 0 {
            throw ArchiveError(sevenZipStatus: status)
        }
    }
}

// MARK: - Zip

/// A .zip archive, read with Apple's Compression framework (stored and deflate, including zip64).
final class ZipArchive: Archive {
    struct Entry {
        let path: String
        let method: UInt16
        let flags: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64

        var isDirectory: Bool { path.hasSuffix("/") || path.hasSuffix("\\") }
    }

    let entries: [Entry]
    private let handle: FileHandle
    private static let chunkSize = 1 << 20

    init(url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ArchiveError.unreadable }
        self.handle = handle
        entries = try Self.readCentralDirectory(handle)
    }

    deinit {
        try? handle.close()
    }

    var totalSize: UInt64 {
        entries.filter { !$0.isDirectory }.reduce(0) { $0 + $1.uncompressedSize }
    }

    func extractAll(to directory: URL, progress: @escaping (UInt64) -> Bool) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: UInt64 = 0
        for entry in entries {
            guard let relative = sanitizedArchivePath(entry.path) else { continue }
            let destination = directory.appendingPathComponent(relative)
            if entry.isDirectory {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try extract(entry, to: destination, written: &written, progress: progress)
        }
        _ = progress(written)
    }

    private func extract(_ entry: Entry, to destination: URL, written: inout UInt64, progress: (UInt64) -> Bool) throws {
        if entry.flags & 1 != 0 { throw ArchiveError.encrypted }
        guard entry.method == 0 || entry.method == 8 else { throw ArchiveError.unsupported }

        try handle.seek(toOffset: entry.localHeaderOffset)
        guard let headerData = try handle.read(upToCount: 30), headerData.count == 30 else { throw ArchiveError.corrupt }
        let header = [UInt8](headerData)
        guard Self.u32(header, 0) == 0x0403_4B50 else { throw ArchiveError.corrupt }
        let dataStart = entry.localHeaderOffset + 30 + UInt64(Self.u16(header, 26)) + UInt64(Self.u16(header, 28))
        try handle.seek(toOffset: dataStart)

        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let output = try? FileHandle(forWritingTo: destination) else { throw ArchiveError.writeFailed }
        defer { try? output.close() }

        var crc: UInt32 = 0
        if entry.method == 0 {
            var remaining = entry.compressedSize
            while remaining > 0 {
                let count = Int(min(UInt64(Self.chunkSize), remaining))
                guard let data = try handle.read(upToCount: count), data.count == count else { throw ArchiveError.corrupt }
                try write(data, to: output)
                crc = data.withUnsafeBytes { attic_crc32(crc, $0.baseAddress, $0.count) }
                remaining -= UInt64(count)
                written += UInt64(count)
                if !progress(written) { throw ArchiveError.cancelled }
            }
        } else {
            try inflate(entry, into: output, crc: &crc, written: &written, progress: progress)
        }
        if crc != entry.crc32 { throw ArchiveError.corrupt }
    }

    private func inflate(_ entry: Entry, into output: FileHandle, crc: inout UInt32, written: inout UInt64, progress: (UInt64) -> Bool) throws {
        let chunk = Self.chunkSize
        let source = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer {
            source.deallocate()
            destination.deallocate()
            stream.deallocate()
        }
        // COMPRESSION_ZLIB is raw deflate (RFC 1951), which is what zip uses.
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ArchiveError.outOfMemory
        }
        defer { compression_stream_destroy(stream) }

        var remaining = entry.compressedSize
        stream.pointee.src_ptr = UnsafePointer(source)
        stream.pointee.src_size = 0
        stream.pointee.dst_ptr = destination
        stream.pointee.dst_size = chunk

        while true {
            if stream.pointee.src_size == 0 && remaining > 0 {
                let count = Int(min(UInt64(chunk), remaining))
                guard let data = try handle.read(upToCount: count), data.count == count else { throw ArchiveError.corrupt }
                data.copyBytes(to: source, count: count)
                stream.pointee.src_ptr = UnsafePointer(source)
                stream.pointee.src_size = count
                remaining -= UInt64(count)
            }
            let flags = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(stream, flags)
            let produced = chunk - stream.pointee.dst_size
            if produced > 0 {
                let buffer = UnsafeBufferPointer(start: destination, count: produced)
                try write(buffer, to: output)
                crc = attic_crc32(crc, destination, produced)
                written += UInt64(produced)
                stream.pointee.dst_ptr = destination
                stream.pointee.dst_size = chunk
                if !progress(written) { throw ArchiveError.cancelled }
            }
            switch status {
            case COMPRESSION_STATUS_END:
                return
            case COMPRESSION_STATUS_OK:
                if remaining == 0 && stream.pointee.src_size == 0 && produced == 0 {
                    throw ArchiveError.corrupt
                }
            default:
                throw ArchiveError.corrupt
            }
        }
    }

    private func write(_ bytes: some DataProtocol, to output: FileHandle) throws {
        do {
            try output.write(contentsOf: bytes)
        } catch {
            throw ArchiveError.writeFailed
        }
    }

    // MARK: Central directory

    private static func readCentralDirectory(_ handle: FileHandle) throws -> [Entry] {
        let fileSize = try handle.seekToEnd()
        let tailSize = min(fileSize, 65_557)
        let tailStart = fileSize - tailSize
        try handle.seek(toOffset: tailStart)
        let tail = [UInt8](try handle.read(upToCount: Int(tailSize)) ?? Data())
        guard tail.count >= 22 else { throw ArchiveError.corrupt }

        var eocd: Int?
        var index = tail.count - 22
        while index >= 0 {
            if tail[index] == 0x50, tail[index + 1] == 0x4B, tail[index + 2] == 0x05, tail[index + 3] == 0x06 {
                eocd = index
                break
            }
            index -= 1
        }
        guard let eocd else { throw ArchiveError.corrupt }

        var count = UInt64(u16(tail, eocd + 10))
        var directorySize = UInt64(u32(tail, eocd + 12))
        var directoryOffset = UInt64(u32(tail, eocd + 16))

        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            // Zip64: the locator sits right before the end-of-central-directory record.
            let locator = eocd - 20
            guard locator >= 0, u32(tail, locator) == 0x0706_4B50 else { throw ArchiveError.corrupt }
            let recordOffset = u64(tail, locator + 8)
            try handle.seek(toOffset: recordOffset)
            let record = [UInt8](try handle.read(upToCount: 56) ?? Data())
            guard record.count == 56, u32(record, 0) == 0x0606_4B50 else { throw ArchiveError.corrupt }
            count = u64(record, 32)
            directorySize = u64(record, 40)
            directoryOffset = u64(record, 48)
        }

        guard directoryOffset + directorySize <= fileSize, directorySize < 256 << 20 else { throw ArchiveError.corrupt }
        try handle.seek(toOffset: directoryOffset)
        let directory = [UInt8](try handle.read(upToCount: Int(directorySize)) ?? Data())
        guard directory.count == Int(directorySize) else { throw ArchiveError.corrupt }

        var entries: [Entry] = []
        var position = 0
        for _ in 0..<count {
            guard position + 46 <= directory.count, u32(directory, position) == 0x0201_4B50 else { throw ArchiveError.corrupt }
            let flags = u16(directory, position + 8)
            let method = u16(directory, position + 10)
            let crc = u32(directory, position + 16)
            var compressed = UInt64(u32(directory, position + 20))
            var uncompressed = UInt64(u32(directory, position + 24))
            let nameLength = Int(u16(directory, position + 28))
            let extraLength = Int(u16(directory, position + 30))
            let commentLength = Int(u16(directory, position + 32))
            var localOffset = UInt64(u32(directory, position + 42))
            let nameStart = position + 46
            let extraStart = nameStart + nameLength
            guard extraStart + extraLength + commentLength <= directory.count else { throw ArchiveError.corrupt }

            let nameBytes = Array(directory[nameStart..<extraStart])
            let name = decodeName(nameBytes, utf8: flags & 0x800 != 0)

            // Zip64 extra field: only the values that overflowed are present, in this order.
            var extra = extraStart
            while extra + 4 <= extraStart + extraLength {
                let id = u16(directory, extra)
                let size = Int(u16(directory, extra + 2))
                if id == 0x0001 {
                    var field = extra + 4
                    if uncompressed == 0xFFFF_FFFF, field + 8 <= extra + 4 + size { uncompressed = u64(directory, field); field += 8 }
                    if compressed == 0xFFFF_FFFF, field + 8 <= extra + 4 + size { compressed = u64(directory, field); field += 8 }
                    if localOffset == 0xFFFF_FFFF, field + 8 <= extra + 4 + size { localOffset = u64(directory, field) }
                }
                extra += 4 + size
            }

            entries.append(Entry(path: name, method: method, flags: flags, crc32: crc, compressedSize: compressed,
                                 uncompressedSize: uncompressed, localHeaderOffset: localOffset))
            position = extraStart + extraLength + commentLength
        }
        return entries
    }

    private static func decodeName(_ bytes: [UInt8], utf8: Bool) -> String {
        if let name = String(bytes: bytes, encoding: .utf8) {
            return name
        }
        let dos = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue))
        return String(bytes: bytes, encoding: String.Encoding(rawValue: dos)) ?? String(decoding: bytes, as: UTF8.self)
    }

    static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(u16(bytes, offset)) | UInt32(u16(bytes, offset + 2)) << 16
    }

    static func u64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        UInt64(u32(bytes, offset)) | UInt64(u32(bytes, offset + 4)) << 32
    }
}
