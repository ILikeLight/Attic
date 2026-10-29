import CommonCrypto
import Foundation
import Network

/// Sends encoded frames to a Chromecast's mirroring receiver: Cast Streaming, the RTP and RTCP
/// over UDP that Chrome casts a tab with (openscreen's cast/streaming describes it). Each frame
/// is encrypted with AES-128-CTR under a key from the offer, cut into packets with a small Cast
/// header, and kept a while so that packets the receiver reports lost go out again. The
/// receiver plays every frame a fixed delay after it was made (the offer's `targetDelay`), so a
/// resent packet still makes it in time. Everything on `queue`.
final class CastStreamer: @unchecked Sendable {
    /// One stream of the offer.
    struct Stream {
        let index: Int
        let ssrc: UInt32
        /// openscreen's "Android RTP hack" values, which every receiver takes: 96 for video, 127 for audio.
        let payloadType: UInt8
        /// RTP ticks per second.
        let timebase: Int
        let key: [UInt8]
        let ivMask: [UInt8]

        static func video(index: Int = 0) -> Stream {
            Stream(index: index, ssrc: UInt32.random(in: 1..<0x7FFF_FFFF), payloadType: 96, timebase: 90_000,
                   key: randomBytes(16), ivMask: randomBytes(16))
        }

        private static func randomBytes(_ count: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: count)
            _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
            return bytes
        }
    }

    /// One frame from an encoder.
    struct Frame {
        let data: Data
        let keyFrame: Bool
        /// When it was made, in nanoseconds of uptime (`DispatchTime.now().uptimeNanoseconds`).
        let time: UInt64
    }

    enum Status: Equatable {
        /// Frames go out, but the receiver hasn't confirmed one yet.
        case starting
        /// The receiver confirms frames.
        case playing
        /// Nothing heard for a while; the picture on the TV stopped.
        case silent
    }

    /// How it goes, for Prestaties tonen.
    struct Figures: Equatable {
        var framesSent = 0
        var framesConfirmed = 0
        var packetsResent = 0
        var keyFrames = 0
        /// Frames dropped because the receiver fell too far behind.
        var framesDropped = 0
        /// The receiver's playout delay, from its feedback (ms).
        var playoutDelay = 0
    }

    /// The video stream's part of the offer: H.264 in `width` × `height`, played `targetDelay` ms
    /// after it was made. The field names and value forms are those Chrome sends.
    static func offer(video: Stream, width: Int, height: Int, frameRate: Int, maxBitRate: Int, targetDelay: Int) -> [String: Any] {
        [
            "castMode": "mirroring",
            "receiverGetStatus": true,
            "supportedStreams": [[
                "index": video.index,
                "type": "video_source",
                "codecName": "h264",
                "rtpProfile": "cast",
                "rtpPayloadType": Int(video.payloadType),
                "ssrc": Int(video.ssrc),
                "targetDelay": targetDelay,
                "storeTime": targetDelay,
                "aesKey": hex(video.key),
                "aesIvMask": hex(video.ivMask),
                "timeBase": "1/\(video.timebase)",
                "receiverRtcpEventLog": false,
                "maxFrameRate": "\(frameRate * 1000)/1000",
                "maxBitRate": maxBitRate,
                "resolutions": [["width": width, "height": height]],
                "channels": 1,
            ]],
        ]
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// RTP and RTCP share the receiver's port; at most this many bytes a packet, safe over Wi-Fi.
    private static let maxPacket = 1_400
    private static let headerSize = 19
    /// The receiver keeps track of at most 120 unconfirmed frames (openscreen's kMaxUnackedFrames).
    private static let maxUnconfirmed = 100

    private final class Track {
        let stream: Stream
        /// The receiver's SSRC for this stream, from the answer.
        let receiverSSRC: UInt32
        var nextFrame = 0
        /// All frames up to here are in.
        var checkpoint = -1
        var packets: [Int: [Data]] = [:]
        /// When each packet of a frame last went out again.
        var resent: [Int: [UInt16: UInt64]] = [:]
        var sequence = UInt16.random(in: 0...UInt16.max)
        let rtpStart = UInt32.random(in: 0...UInt32.max)
        var packetCount: UInt32 = 0
        var octetCount: UInt32 = 0
        /// Frames were dropped: the next one must be a key frame.
        var needsKeyFrame = false
        var lastKeyFrame: UInt64 = 0
        var lastKeyRequest: UInt64 = 0

        init(stream: Stream, receiverSSRC: UInt32) {
            self.stream = stream
            self.receiverSSRC = receiverSSRC
        }

        func rtpTime(_ time: UInt64, since start: UInt64) -> UInt32 {
            let ticks = (time &- start) / 1_000 * UInt64(stream.timebase) / 1_000_000
            return rtpStart &+ UInt32(truncatingIfNeeded: ticks)
        }

        /// The full frame ID whose last eight bits are `low`, at or before the newest frame.
        func expand(_ low: UInt8) -> Int {
            let newest = nextFrame - 1
            return newest - Int(UInt8(truncatingIfNeeded: newest) &- low)
        }
    }

    let queue: DispatchQueue
    private let connection: NWConnection
    private var tracks: [Track]
    /// Shared by the streams, so their RTP times line up.
    private let origin = DispatchTime.now().uptimeNanoseconds
    /// Seconds between the NTP epoch (1900) and uptime zero.
    private let ntpOffset: Double
    private var reports: DispatchSourceTimer?
    private var lastFeedback: UInt64 = 0
    private var firstFrame: UInt64 = 0
    private(set) var figures = Figures()
    private(set) var status = Status.starting { didSet { if status != oldValue { onStatus?(status) } } }
    /// The encoder should make a key frame next (the receiver lost the picture, or frames were dropped).
    var onKeyFrameWanted: (() -> Void)?
    var onStatus: ((Status) -> Void)?

    /// Nil when the answer accepts none of `streams`.
    init?(answer: [String: Any], host: NWEndpoint.Host, streams: [Stream], queue: DispatchQueue) {
        guard let port = (answer["udpPort"] as? Int).flatMap({ NWEndpoint.Port(rawValue: UInt16(clamping: $0)) }) else { return nil }
        let indexes = answer["sendIndexes"] as? [Int] ?? []
        let ssrcs = (answer["ssrcs"] as? [NSNumber] ?? []).map(\.uint32Value)
        tracks = zip(indexes, ssrcs).compactMap { index, ssrc in
            streams.first { $0.index == index }.map { Track(stream: $0, receiverSSRC: ssrc) }
        }
        guard !tracks.isEmpty else { return nil }
        let parameters = NWParameters.udp
        parameters.serviceClass = .interactiveVideo
        connection = NWConnection(host: host, port: port, using: parameters)
        self.queue = queue
        ntpOffset = Date.now.timeIntervalSince1970 + 2_208_988_800 - Double(DispatchTime.now().uptimeNanoseconds) / 1e9
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.receive() }
        }
        connection.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        reports = timer
    }

    func stop() {
        reports?.cancel()
        connection.cancel()
    }

    /// Sends a frame of the stream with `index` (0 is the video).
    func send(_ frame: Frame, stream index: Int = 0) {
        guard let track = tracks.first(where: { $0.stream.index == index }) else { return }
        // Too far ahead of the receiver: drop frames until it catches up, then start over from a key frame.
        if track.nextFrame - 1 - track.checkpoint >= Self.maxUnconfirmed || (track.needsKeyFrame && !frame.keyFrame) {
            if !track.needsKeyFrame {
                track.needsKeyFrame = true
            }
            figures.framesDropped += 1
            requestKeyFrame(track, force: true)
            return
        }
        track.needsKeyFrame = false
        let frameID = track.nextFrame
        track.nextFrame += 1
        let rtpTime = track.rtpTime(frame.time, since: origin)
        let encrypted = Self.crypt(frame.data, frameID: frameID, key: track.stream.key, ivMask: track.stream.ivMask)
        let payloadSize = Self.maxPacket - Self.headerSize
        let count = max(1, (encrypted.count + payloadSize - 1) / payloadSize)
        guard count < 0xFFFF else { return }
        var packets: [Data] = []
        packets.reserveCapacity(count)
        encrypted.withUnsafeBytes { bytes in
            for packetID in 0..<count {
                let chunk = bytes[(packetID * payloadSize)..<min(encrypted.count, (packetID + 1) * payloadSize)]
                var packet = Data(capacity: Self.headerSize + chunk.count)
                packet.append(0x80)
                packet.append((packetID == count - 1 ? 0x80 : 0) | track.stream.payloadType)
                packet.appendBig(track.sequence)
                track.sequence &+= 1
                packet.appendBig(rtpTime)
                packet.appendBig(track.stream.ssrc)
                // Cast header: key frame, "reference frame ID follows", no extensions.
                packet.append((frame.keyFrame ? 0x80 : 0) | 0x40)
                packet.append(UInt8(truncatingIfNeeded: frameID))
                packet.appendBig(UInt16(packetID))
                packet.appendBig(UInt16(count - 1))
                // A key frame stands alone; every other frame builds on the one before.
                packet.append(UInt8(truncatingIfNeeded: frame.keyFrame ? frameID : frameID - 1))
                packet.append(contentsOf: chunk)
                packets.append(packet)
                track.packetCount &+= 1
                track.octetCount &+= UInt32(chunk.count)
            }
        }
        track.packets[frameID] = packets
        track.packets[frameID - Self.maxUnconfirmed - 20] = nil
        track.resent[frameID - Self.maxUnconfirmed - 20] = nil
        connection.batch {
            for packet in packets { connection.send(content: packet, completion: .idempotent) }
        }
        figures.framesSent += 1
        if frame.keyFrame {
            figures.keyFrames += 1
            track.lastKeyFrame = DispatchTime.now().uptimeNanoseconds
        }
        if firstFrame == 0 {
            firstFrame = DispatchTime.now().uptimeNanoseconds
            // The receiver times frames by the sender reports, so the first one goes out at once.
            sendReport(track)
        }
    }

    private func requestKeyFrame(_ track: Track, force: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        // A key frame just went out, or one was just asked for: it is on its way.
        guard force || now &- track.lastKeyFrame > 300_000_000 else { return }
        guard now &- track.lastKeyRequest > 100_000_000 else { return }
        track.lastKeyRequest = now
        onKeyFrameWanted?()
    }

    private func tick() {
        for track in tracks where track.nextFrame > 0 {
            sendReport(track)
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if firstFrame != 0, now &- max(lastFeedback, firstFrame) > 4_000_000_000 {
            status = .silent
        }
    }

    // MARK: RTCP

    /// A sender report: which RTP time goes with which wall-clock time, so the receiver can time the frames.
    private func sendReport(_ track: Track) {
        let now = DispatchTime.now().uptimeNanoseconds
        let ntp = ntpOffset + Double(now) / 1e9
        let seconds = UInt32(truncatingIfNeeded: UInt64(ntp))
        let fraction = UInt32(truncatingIfNeeded: UInt64((ntp - floor(ntp)) * 4_294_967_296))
        var packet = Data(capacity: 28)
        packet.append(0x80)
        packet.append(200)
        packet.appendBig(UInt16(6))
        packet.appendBig(track.stream.ssrc)
        packet.appendBig(seconds)
        packet.appendBig(fraction)
        packet.appendBig(track.rtpTime(now, since: origin))
        packet.appendBig(track.packetCount)
        packet.appendBig(track.octetCount)
        connection.send(content: packet, completion: .idempotent)
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data { readRTCP([UInt8](data)) }
            if error == nil { receive() }
        }
    }

    /// A compound RTCP packet from the receiver: feedback (which frames are in, which packets
    /// are missing), picture loss, and reports Attic doesn't need.
    private func readRTCP(_ bytes: [UInt8]) {
        var offset = 0
        while offset + 4 <= bytes.count {
            let subtype = bytes[offset] & 0x1F
            let type = bytes[offset + 1]
            let length = ((Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])) + 1) * 4
            guard bytes[offset] >> 6 == 2, offset + length <= bytes.count else { return }
            let body = Array(bytes[(offset + 4)..<(offset + length)])
            if type == 206, body.count >= 8 {
                let sender = UInt32(bigEndian: body, at: 4)
                if let track = tracks.first(where: { $0.stream.ssrc == sender }) {
                    if subtype == 15 {
                        feedback(Array(body[8...]), track: track)
                    } else if subtype == 1 {
                        requestKeyFrame(track)
                    }
                }
            }
            offset += length
        }
    }

    private func feedback(_ body: [UInt8], track: Track) {
        guard body.count >= 8, UInt32(bigEndian: body, at: 0) == 0x4341_5354, track.nextFrame > 0 else { return }
        lastFeedback = DispatchTime.now().uptimeNanoseconds
        let checkpoint = track.expand(body[4])
        let losses = Int(body[5])
        figures.playoutDelay = Int(body[6]) << 8 | Int(body[7])
        if checkpoint > track.checkpoint {
            figures.framesConfirmed += checkpoint - track.checkpoint
            for frame in track.checkpoint + 1...checkpoint {
                track.packets[frame] = nil
                track.resent[frame] = nil
            }
            track.checkpoint = checkpoint
            status = .playing
        }
        let now = DispatchTime.now().uptimeNanoseconds
        var resend: [Data] = []
        for loss in 0..<losses {
            let at = 8 + loss * 4
            guard at + 4 <= body.count else { break }
            let frame = track.expand(body[at])
            guard frame > track.checkpoint, let packets = track.packets[frame] else { continue }
            let first = UInt16(body[at + 1]) << 8 | UInt16(body[at + 2])
            var wanted: [UInt16] = []
            if first == 0xFFFF {
                wanted = (0..<UInt16(packets.count)).map { $0 }
            } else {
                wanted = [first] + (0..<8).compactMap { bit in body[at + 3] & (1 << bit) != 0 ? first &+ UInt16(bit + 1) : nil }
            }
            for packetID in wanted where Int(packetID) < packets.count {
                // Asked again in the next feedback before the first copy could arrive: wait a bit.
                if let last = track.resent[frame]?[packetID], now &- last < 20_000_000 { continue }
                track.resent[frame, default: [:]][packetID] = now
                resend.append(packets[Int(packetID)])
            }
        }
        guard !resend.isEmpty else { return }
        figures.packetsResent += resend.count
        connection.batch {
            for packet in resend { connection.send(content: packet, completion: .idempotent) }
        }
    }

    // MARK: Encryption

    /// AES-128 in counter mode, as openscreen's FrameCrypto: the counter starts at the IV mask
    /// with the frame ID in bytes 8 to 11 and counts up over all 128 bits.
    static func crypt(_ data: Data, frameID: Int, key: [UInt8], ivMask: [UInt8]) -> Data {
        var nonce = ivMask
        let id = UInt32(truncatingIfNeeded: frameID)
        nonce[8] ^= UInt8(id >> 24)
        nonce[9] ^= UInt8((id >> 16) & 0xFF)
        nonce[10] ^= UInt8((id >> 8) & 0xFF)
        nonce[11] ^= UInt8(id & 0xFF)
        let high = nonce[0..<8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let low = nonce[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let blocks = (data.count + 15) / 16
        var counters = [UInt8](repeating: 0, count: blocks * 16)
        for block in 0..<blocks {
            let blockLow = low &+ UInt64(block)
            let blockHigh = blockLow < low ? high &+ 1 : high
            for byte in 0..<8 {
                counters[block * 16 + byte] = UInt8(truncatingIfNeeded: blockHigh >> (56 - 8 * UInt64(byte)))
                counters[block * 16 + 8 + byte] = UInt8(truncatingIfNeeded: blockLow >> (56 - 8 * UInt64(byte)))
            }
        }
        var stream = [UInt8](repeating: 0, count: counters.count)
        var moved = 0
        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), key, key.count, nil,
                counters, counters.count, &stream, stream.count, &moved)
        var output = Data(count: data.count)
        output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                for index in 0..<data.count {
                    out[index] = input[index] ^ stream[index]
                }
            }
        }
        return output
    }
}

private extension Data {
    mutating func appendBig(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBig(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
}

private extension UInt32 {
    init(bigEndian bytes: [UInt8], at offset: Int) {
        self = UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}
