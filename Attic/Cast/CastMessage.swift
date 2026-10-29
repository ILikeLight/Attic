import Foundation

/// One message on a Chromecast's control connection: the protobuf `CastMessage` of the CASTV2
/// protocol (openscreen's cast_channel.proto), sent as a 4-byte big-endian length and then the
/// message. Attic only sends and reads text payloads, which hold JSON.
struct CastMessage: Equatable {
    var source: String
    var destination: String
    var namespace: String
    var payload: String

    /// The message with its length in front, ready to send.
    func framed() -> Data {
        var body = Data()
        body.appendVarint(field: 1, 0) // protocol_version: CASTV2_1_0
        body.appendText(field: 2, source)
        body.appendText(field: 3, destination)
        body.appendText(field: 4, namespace)
        body.appendVarint(field: 5, 0) // payload_type: STRING
        body.appendText(field: 6, payload)
        var framed = Data()
        let length = UInt32(body.count)
        framed.append(contentsOf: [UInt8(length >> 24), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)])
        framed.append(body)
        return framed
    }

    /// Reads a message without its length; nil when it is not one. A binary payload (the device
    /// check that Chrome asks for, which Attic doesn't) leaves `payload` empty.
    init?(body: Data) {
        var source: String?
        var destination: String?
        var namespace: String?
        var payload = ""
        var reader = Reader(bytes: [UInt8](body))
        while !reader.atEnd {
            guard let tag = reader.varint() else { return nil }
            switch tag & 7 {
            case 0:
                guard reader.varint() != nil else { return nil }
            case 2:
                guard let bytes = reader.lengthDelimited() else { return nil }
                let text = String(decoding: bytes, as: UTF8.self)
                switch tag >> 3 {
                case 2: source = text
                case 3: destination = text
                case 4: namespace = text
                case 6: payload = text
                default: break
                }
            case 1:
                guard reader.skip(8) else { return nil }
            case 5:
                guard reader.skip(4) else { return nil }
            default:
                return nil
            }
        }
        guard let source, let destination, let namespace else { return nil }
        self.init(source: source, destination: destination, namespace: namespace, payload: payload)
    }

    init(source: String, destination: String, namespace: String, payload: String) {
        self.source = source
        self.destination = destination
        self.namespace = namespace
        self.payload = payload
    }

    /// The JSON payload as a dictionary.
    var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        var atEnd: Bool { offset >= bytes.count }

        mutating func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while offset < bytes.count, shift < 64 {
                let byte = bytes[offset]
                offset += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }

        mutating func lengthDelimited() -> ArraySlice<UInt8>? {
            guard let length = varint(), length <= UInt64(bytes.count - offset) else { return nil }
            let start = offset
            offset += Int(length)
            return bytes[start..<offset]
        }

        mutating func skip(_ count: Int) -> Bool {
            guard bytes.count - offset >= count else { return false }
            offset += count
            return true
        }
    }
}

private extension Data {
    mutating func appendVarint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        append(UInt8(value))
    }

    mutating func appendVarint(field: UInt64, _ value: UInt64) {
        appendVarint(field << 3)
        appendVarint(value)
    }

    mutating func appendText(field: UInt64, _ text: String) {
        let bytes = Data(text.utf8)
        appendVarint(field << 3 | 2)
        appendVarint(UInt64(bytes.count))
        append(bytes)
    }
}
