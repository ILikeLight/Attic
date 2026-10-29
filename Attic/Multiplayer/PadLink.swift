import Foundation
import Network

/// How an iPhone that plays a game (`MultiplayerHost`) and iPhones that join it as controllers
/// (`MultiplayerClient`) find and talk to each other: Bonjour over the local network, and also
/// directly between iPhones (peer-to-peer Wi-Fi, as AirDrop) when they share no network, with
/// small UDP messages. A message that gets lost is made good by the next one: the host repeats
/// its answer and the controller its buttons, so nothing waits for a resend.
enum PadLink {
    static let serviceType = "_attic-pad._udp"
    /// Raised when the messages change; a controller and host of different versions do not see each other.
    static let version: UInt8 = 3

    /// `direct`: also straight between iPhones (AWDL), not only over a Wi-Fi network both are on
    /// (`AppSettings.directWiFi`). Off on either iPhone keeps their messages on the network.
    static func parameters(direct: Bool) -> NWParameters {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = direct
        parameters.serviceClass = .interactiveVoice
        return parameters
    }

    /// How a connection runs, for the figures under Prestaties tonen: straight to the other iPhone
    /// (AWDL, or Apple's low-latency link), over the Wi-Fi network, or the interface's own name.
    static func route(of path: NWPath?) -> String {
        guard let path, path.status == .satisfied else { return "geen verbinding" }
        let names = path.availableInterfaces.map(\.name)
        let local = path.localEndpoint.map { "\($0)" } ?? ""
        if names.first.map({ $0.hasPrefix("awdl") || $0.hasPrefix("llw") }) == true
            || local.contains("%awdl") || local.contains("%llw") {
            return "rechtstreeks (\(names.first ?? "awdl"))"
        }
        if path.usesInterfaceType(.wifi) {
            return "wifi-netwerk (\(names.first ?? "wifi"))"
        }
        return names.first ?? "onbekend"
    }

    /// The game a host plays, in its Bonjour TXT record, so a controller can show it before joining.
    static func txtRecord(title: String, system: GameSystem) -> NWTXTRecord {
        NWTXTRecord(["v": String(version), "game": String(title.prefix(80)), "system": system.rawValue])
    }
}

enum PadMessage: Equatable {
    enum Status: UInt8 {
        case waiting, accepted, rejected, full, ended
    }

    /// A controller asks to join, and asks again until it hears back.
    case hello(client: UUID)
    /// The host's answer, repeated while the controller is in: its player number (2 to 4), the game,
    /// and for the Wii the controller it is played with (`WiiController`, empty otherwise).
    case status(Status, player: Int, system: String, title: String, controller: String)
    /// A controller's buttons (libretro's, `PadButton.mask`) and sticks (-0x7FFF to 0x7FFF, y down),
    /// and with a Wii Remote its accelerometer as `WiiMotion` reads it (g; zero without movement).
    /// The stamp comes after the rest, so a host of an earlier 0.5 build reads the message all the
    /// same; from such a controller it is nil.
    case input(client: UUID, mask: UInt32, left: SIMD2<Int16>, right: SIMD2<Int16>, motion: SIMD3<Float>, stamp: InputStamp?)
    case leave(client: UUID)
    /// The host: how hard the game makes this player's controller vibrate, 0 to 255. Sent when it
    /// changes and with every answer, so a lost one is made good.
    case rumble(strength: UInt8)

    private static let magic: [UInt8] = [0x41, 0x50]  // "AP"

    func encoded() -> Data {
        var data = Data(Self.magic + [PadLink.version])
        switch self {
        case .hello(let client):
            data.append(1)
            data.append(client)
        case .status(let status, let player, let system, let title, let controller):
            data.append(2)
            data.append(status.rawValue)
            data.append(UInt8(clamping: player))
            data.append(string: system)
            data.append(string: title)
            data.append(string: controller)
        case .input(let client, let mask, let left, let right, let motion, let stamp):
            data.append(3)
            data.append(client)
            data.append(little: mask)
            for value in [left.x, left.y, right.x, right.y] {
                data.append(little: UInt16(bitPattern: value))
            }
            // In thousandths of g, up to ±32 g.
            for value in [motion.x, motion.y, motion.z] {
                data.append(little: UInt16(bitPattern: Int16(clamping: Int((value * 1000).rounded()))))
            }
            if let stamp {
                data.append(little: stamp.sequence)
                data.append(little: stamp.sent)
            }
        case .leave(let client):
            data.append(4)
            data.append(client)
        case .rumble(let strength):
            data.append(5)
            data.append(strength)
        }
        return data
    }

    init?(_ data: Data) {
        var reader = Reader(bytes: [UInt8](data))
        guard reader.bytes(2) == Self.magic, reader.byte() == PadLink.version, let type = reader.byte() else { return nil }
        switch type {
        case 1:
            guard let client = reader.uuid() else { return nil }
            self = .hello(client: client)
        case 2:
            guard let raw = reader.byte(), let status = Status(rawValue: raw), let player = reader.byte(),
                  let system = reader.string(), let title = reader.string(), let controller = reader.string() else { return nil }
            self = .status(status, player: Int(player), system: system, title: title, controller: controller)
        case 3:
            guard let client = reader.uuid(), let mask = reader.uint32(),
                  let lx = reader.int16(), let ly = reader.int16(), let rx = reader.int16(), let ry = reader.int16(),
                  let mx = reader.int16(), let my = reader.int16(), let mz = reader.int16() else { return nil }
            let motion = SIMD3(Float(mx), Float(my), Float(mz)) / 1000
            let stamp = reader.uint16().flatMap { sequence in reader.uint32().map { InputStamp(sequence: sequence, sent: $0) } }
            self = .input(client: client, mask: mask, left: SIMD2(lx, ly), right: SIMD2(rx, ry), motion: motion, stamp: stamp)
        case 4:
            guard let client = reader.uuid() else { return nil }
            self = .leave(client: client)
        case 5:
            guard let strength = reader.byte() else { return nil }
            self = .rumble(strength: strength)
        default:
            return nil
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func bytes(_ count: Int) -> [UInt8]? {
            guard offset + count <= bytes.count else { return nil }
            defer { offset += count }
            return Array(bytes[offset..<offset + count])
        }

        mutating func byte() -> UInt8? { bytes(1)?[0] }

        mutating func uint32() -> UInt32? {
            bytes(4).map { $0.reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        }

        mutating func uint16() -> UInt16? {
            bytes(2).map { UInt16($0[0]) | UInt16($0[1]) << 8 }
        }

        mutating func int16() -> Int16? {
            bytes(2).map { Int16(bitPattern: UInt16($0[0]) | UInt16($0[1]) << 8) }
        }

        mutating func uuid() -> UUID? {
            guard let b = bytes(16) else { return nil }
            return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
        }

        mutating func string() -> String? {
            guard let length = byte(), let utf8 = bytes(Int(length)) else { return nil }
            return String(decoding: utf8, as: UTF8.self)
        }
    }
}

/// When a controller sent an input message, to measure on the host how evenly they arrive
/// (`LinkMonitor`): a number that goes up by one per message, and the controller's uptime in
/// tenths of a millisecond. Both wrap around.
struct InputStamp: Equatable {
    var sequence: UInt16
    var sent: UInt32

    static func now(sequence: UInt16) -> InputStamp {
        InputStamp(sequence: sequence, sent: UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 100_000))
    }
}

private extension Data {
    mutating func append(_ uuid: UUID) {
        Swift.withUnsafeBytes(of: uuid.uuid) { append(contentsOf: $0) }
    }

    mutating func append(little value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)])
    }

    mutating func append(little value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    /// At most 255 bytes, cut at a character.
    mutating func append(string: String) {
        var utf8 = Array(string.utf8)
        if utf8.count > 255 {
            var cut = String(string.prefix(80))
            while cut.utf8.count > 255 { cut.removeLast() }
            utf8 = Array(cut.utf8)
        }
        append(UInt8(utf8.count))
        append(contentsOf: utf8)
    }
}
