import Foundation
import Network
import Security

/// The control connection to a Chromecast: TLS on port 8009 with small JSON messages (CASTV2).
/// Google's own sender library is closed and doesn't go with the GPL, so Attic speaks the
/// protocol itself, as VLC does. It starts the Chromecast's built-in mirroring receiver, the one
/// Chrome casts a tab to, and agrees on a stream with it (`CastStreamer` then sends the video).
/// Everything happens on `queue`; so do the events.
final class CastChannel: @unchecked Sendable {
    enum Event {
        /// The mirroring receiver is running and listening: time for the offer.
        case ready
        /// The receiver's answer to the offer, the "answer" object of its ANSWER message.
        case answer([String: Any])
        /// The connection ended; the reason is for the player, nil when Attic closed it.
        case closed(String?)
    }

    /// Chrome's mirroring receiver (openscreen's kMirroringAppId), built into every Chromecast.
    static let mirroringApp = "0F5096E8"

    private enum Namespace {
        static let connection = "urn:x-cast:com.google.cast.tp.connection"
        static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
        static let receiver = "urn:x-cast:com.google.cast.receiver"
        static let webrtc = "urn:x-cast:com.google.cast.webrtc"
    }

    private static let sender = "sender-0"
    private static let platform = "receiver-0"

    let queue: DispatchQueue
    private let connection: NWConnection
    private let onEvent: @Sendable (CastChannel, Event) -> Void
    private var buffer = Data()
    private var requestID = 0
    private var offerNumber = 0
    /// The running receiver's ids, once it has started.
    private var transport: String?
    private var session: String?
    private var lastHeard = Date.now
    private var heartbeat: DispatchSourceTimer?
    private var ended = false

    /// `onEvent` gets the channel itself, so it need not hold on to it.
    init(to endpoint: NWEndpoint, queue: DispatchQueue, onEvent: @escaping @Sendable (CastChannel, Event) -> Void) {
        let tls = NWProtocolTLS.Options()
        // A Chromecast proves itself with a certificate of Google's own, not one the iPhone
        // knows; only Chrome checks it (the device check). The stream itself is encrypted
        // with a key of Attic's, sent over this connection.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 8
        connection = NWConnection(to: endpoint, using: NWParameters(tls: tls, tcp: tcp))
        self.queue = queue
        self.onEvent = onEvent
    }

    /// The Chromecast's own address, for the stream, once connected.
    var remoteHost: NWEndpoint.Host? {
        if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint { return host }
        return nil
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                send(Namespace.connection, to: Self.platform, ["type": "CONNECT", "origin": [String: Any](), "userAgent": "Attic"])
                requestID += 1
                send(Namespace.receiver, to: Self.platform, ["type": "LAUNCH", "requestId": requestID, "appId": Self.mirroringApp])
                lastHeard = .now
                startHeartbeat()
                receive()
            case .failed(let error), .waiting(let error):
                end(Self.describe(error))
            case .cancelled:
                end(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        // A Chromecast that is gone can leave the connection trying without ever failing.
        queue.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, transport == nil else { return }
            end(connection.state == .ready ? "De Chromecast startte de ontvanger niet."
                                           : "De Chromecast reageert niet. Staat hij aan, op hetzelfde wifi?")
        }
    }

    /// Offers a stream (an "offer" object, see `CastStreamer.offer`); the answer comes as an event.
    func sendOffer(_ offer: [String: Any]) {
        guard let transport else { return }
        offerNumber += 1
        send(Namespace.webrtc, to: transport, ["type": "OFFER", "seqNum": offerNumber, "offer": offer])
    }

    /// Stops the receiver, so the TV goes back to what it showed, and closes the connection.
    func close() {
        guard !ended else { return }
        if let session {
            requestID += 1
            send(Namespace.receiver, to: Self.platform, ["type": "STOP", "requestId": requestID, "sessionId": session])
        }
        if let transport {
            send(Namespace.connection, to: transport, ["type": "CLOSE"])
        }
        send(Namespace.connection, to: Self.platform, ["type": "CLOSE"])
        ended = true
        heartbeat?.cancel()
        // Let the messages go out before the connection does.
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
        onEvent(self, .closed(nil))
    }

    private func send(_ namespace: String, to destination: String, _ payload: [String: Any]) {
        guard !ended, let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let message = CastMessage(source: Self.sender, destination: destination, namespace: namespace,
                                  payload: String(decoding: data, as: UTF8.self))
        connection.send(content: message.framed(), completion: .idempotent)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, !ended else { return }
            if let data {
                buffer.append(data)
                lastHeard = .now
                readMessages()
            }
            if let error {
                end(Self.describe(error))
            } else if isComplete {
                end("De Chromecast verbrak de verbinding.")
            } else {
                receive()
            }
        }
    }

    private func readMessages() {
        while buffer.count >= 4 {
            let bytes = [UInt8](buffer.prefix(4))
            let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
            guard length < 1 << 20 else { return end("De Chromecast stuurde iets onleesbaars.") }
            guard buffer.count >= 4 + length else { return }
            let body = buffer.subdata(in: buffer.startIndex + 4..<buffer.startIndex + 4 + length)
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + 4 + length)
            if let message = CastMessage(body: body) {
                handle(message)
            }
        }
    }

    private func handle(_ message: CastMessage) {
        guard let json = message.json, let type = json["type"] as? String else { return }
        switch (message.namespace, type) {
        case (Namespace.heartbeat, "PING"):
            send(Namespace.heartbeat, to: message.source, ["type": "PONG"])
        case (Namespace.connection, "CLOSE"):
            // The receiver closed: someone else cast to the TV, or it was stopped with the remote.
            end(message.source == transport ? "De tv speelt nu iets anders." : "De Chromecast verbrak de verbinding.")
        case (Namespace.receiver, "RECEIVER_STATUS"):
            receiverStatus(json)
        case (Namespace.receiver, "LAUNCH_ERROR"), (Namespace.receiver, "INVALID_REQUEST"):
            end("De Chromecast kon de ontvanger niet starten (\(json["reason"] as? String ?? type)).")
        case (Namespace.webrtc, "ANSWER"):
            if json["result"] as? String == "ok", let answer = json["answer"] as? [String: Any] {
                onEvent(self, .answer(answer))
            } else {
                let error = json["error"] as? [String: Any]
                end("De Chromecast wees het beeld af (\(error?["description"] as? String ?? "geen reden")).")
            }
        default:
            break
        }
    }

    private func receiverStatus(_ json: [String: Any]) {
        let applications = (json["status"] as? [String: Any])?["applications"] as? [[String: Any]] ?? []
        let mirroring = applications.first { $0["appId"] as? String == Self.mirroringApp }
        guard let mirroring, let transportID = mirroring["transportId"] as? String else {
            if transport != nil {
                end("De tv speelt nu iets anders.")
            }
            return
        }
        guard transport == nil else { return }
        transport = transportID
        session = mirroring["sessionId"] as? String
        send(Namespace.connection, to: transportID, ["type": "CONNECT", "origin": [String: Any](), "userAgent": "Attic"])
        onEvent(self, .ready)
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Date.now.timeIntervalSince(lastHeard) > 15 {
                end("De Chromecast reageert niet meer.")
            } else {
                send(Namespace.heartbeat, to: Self.platform, ["type": "PING"])
            }
        }
        timer.resume()
        heartbeat = timer
    }

    private func end(_ reason: String?) {
        guard !ended else { return }
        ended = true
        heartbeat?.cancel()
        connection.cancel()
        onEvent(self, .closed(reason ?? "De verbinding met de Chromecast is verbroken."))
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(.ECONNREFUSED), .posix(.EHOSTUNREACH), .posix(.ETIMEDOUT), .posix(.ENETUNREACH):
            "De Chromecast is niet bereikbaar. Staat hij aan, op hetzelfde wifi?"
        case .dns:
            "De Chromecast is niet te vinden op het netwerk."
        default:
            "De verbinding met de Chromecast mislukte (\(error.localizedDescription))."
        }
    }
}
