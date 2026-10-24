import Foundation
import Network
import Observation
import Synchronization

/// This iPhone as a controller for a game on another iPhone (`MultiplayerHost`): finds the
/// games nearby, asks to join one, and once let in sends its buttons and sticks.
@MainActor
@Observable
final class MultiplayerClient {
    struct Host: Identifiable, Equatable {
        let id: String
        let endpoint: NWEndpoint
        let title: String
        let system: GameSystem?
    }

    enum Phase: Equatable {
        case searching
        case asking(Host)
        /// On the Wii with the controller the host's game uses.
        case playing(player: Int, system: GameSystem, title: String, controller: WiiController?)
        /// The other iPhone said no, has no place left, stopped the game, or went quiet.
        case turnedAway, full, ended, lost
    }

    private(set) var hosts: [Host] = []
    private(set) var phase = Phase.searching
    /// The buttons on this iPhone's screen (and a controller on it), sent to the host.
    let input = InputState()
    /// A Wii Remote held sideways like a steering wheel now (`WiiMotion.heldSideways`), as with the host's own.
    var holdsSideways = false {
        didSet { motion.withLock { $0 }?.heldSideways = holdsSideways }
    }
    /// The game on the other iPhone makes this player's controller vibrate, 0 to 1; only changes come in.
    @ObservationIgnored var onRumble: (Float) -> Void = { _ in }
    @ObservationIgnored private var rumble: Float = 0

    private nonisolated let id = UUID()
    private nonisolated let queue = DispatchQueue(label: "app.attic.controller", qos: .userInteractive)
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var sender: DispatchSourceTimer?
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var lastHeard = Date.distantPast
    /// Let in by the host: the sender sends buttons instead of asking.
    private nonisolated let admitted = Atomic(false)
    /// This iPhone's movement as its Wii Remote's, while it plays a Wii game with one; read by the sender.
    private nonisolated let motion = Mutex<WiiMotion?>(nil)

    /// How this iPhone is held now counts as its Wii Remote held level (`WiiMotion.level`).
    func levelWiiRemote() {
        motion.withLock { $0 }?.level()
    }

    func search() {
        stopBrowsing()
        hosts = []
        phase = .searching
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: PadLink.serviceType, domain: nil), using: PadLink.parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap(Self.host(from:))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.hosts = found.sorted { $0.title < $1.title }
                }
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func join(_ host: Host) {
        disconnect()
        stopBrowsing()
        phase = .asking(host)
        lastHeard = .now
        let connection = NWConnection(to: host.endpoint, using: PadLink.parameters)
        connection.start(queue: queue)
        receive(on: connection)
        self.connection = connection
        startSending(on: connection)
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.watch()
            }
        }
    }

    /// Leaves the game, if in one, and stops looking for others.
    func stop() {
        if let connection {
            // Sent twice in case one gets lost; the connection closes once they are out.
            let leave = PadMessage.leave(client: id).encoded()
            connection.send(content: leave, completion: .idempotent)
            connection.send(content: leave, completion: .contentProcessed { _ in connection.cancel() })
            self.connection = nil
        }
        disconnect()
        stopBrowsing()
    }

    private func disconnect() {
        if rumble != 0 {
            rumble = 0
            onRumble(0)
        }
        admitted.store(false, ordering: .relaxed)
        motion.withLock { $0 }?.stop()
        motion.withLock { $0 = nil }
        holdsSideways = false
        sender?.cancel()
        sender = nil
        watchdog?.invalidate()
        watchdog = nil
        connection?.cancel()
        connection = nil
        input.clear()
    }

    private func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    private nonisolated static func host(from result: NWBrowser.Result) -> Host? {
        guard case .bonjour(let txt) = result.metadata, txt["v"] == String(PadLink.version) else { return nil }
        return Host(id: "\(result.endpoint)", endpoint: result.endpoint, title: txt["game"] ?? "Een spel",
                    system: txt["system"].flatMap(GameSystem.init(rawValue:)))
    }

    /// Asks to join twice a second until let in; then sends the buttons as they change, the
    /// movement of a Wii Remote 60 times a second, and at least every 50 ms so the host knows the
    /// controller is still there.
    private func startSending(on connection: NWConnection) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        let hello = PadMessage.hello(client: id).encoded()
        let input = input
        let id = id
        let sent = SentState()
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let since = now - sent.time
            guard self.admitted.load(ordering: .relaxed) else {
                if since > 500_000_000 {
                    connection.send(content: hello, completion: .idempotent)
                    sent.time = now
                }
                return
            }
            let mask = input.nextFrameMask()
            let sticks = input.nextFrameSticks()
            let motion = self.motion.withLock { $0 }?.reading.withLock { $0 }
            let state = SentState.Pad(mask: mask, left: sticks.left, right: sticks.right)
            guard state != sent.pad || since > (motion == nil ? 50_000_000 : 16_000_000) else { return }
            let message = PadMessage.input(client: id, mask: mask, left: sticks.left, right: sticks.right, motion: motion ?? .zero)
            connection.send(content: message.encoded(), completion: .idempotent)
            sent.pad = state
            sent.time = now
        }
        timer.resume()
        sender = timer
    }

    private nonisolated func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            switch data.flatMap(PadMessage.init) {
            case .status(let status, let player, let system, let title, let controller)?:
                if status == .accepted {
                    self.admitted.store(true, ordering: .relaxed)
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.heard(status, player: player, system: system, title: title, controller: controller)
                    }
                }
            case .rumble(let strength)?:
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.heard(rumble: Float(strength) / 255)
                    }
                }
            default:
                break
            }
            if error == nil {
                self.receive(on: connection)
            }
        }
    }

    private func heard(_ status: PadMessage.Status, player: Int, system: String, title: String, controller: String) {
        guard connection != nil else { return }
        lastHeard = .now
        switch status {
        case .waiting:
            break
        case .accepted:
            guard let system = GameSystem(rawValue: system) else { return }
            let controller = system == .wii ? WiiController(rawValue: controller) ?? .nunchuk : nil
            let playing = Phase.playing(player: player, system: system, title: title, controller: controller)
            guard phase != playing else { return }
            phase = playing
            // A Wii Remote in the hand moves with this iPhone.
            if let controller, controller.isWiiRemote, motion.withLock({ $0 }) == nil {
                let wiiMotion = WiiMotion(sideways: controller == .sideways)
                wiiMotion.start()
                motion.withLock { $0 = wiiMotion }
            }
        case .rejected:
            disconnect()
            phase = .turnedAway
        case .full:
            disconnect()
            phase = .full
        case .ended:
            disconnect()
            phase = .ended
        }
    }

    private func heard(rumble strength: Float) {
        guard case .playing = phase, strength != rumble else { return }
        rumble = strength
        onRumble(strength)
    }

    /// The host answers at least twice a second; five quiet seconds mean it is gone.
    private func watch() {
        guard Date.now.timeIntervalSince(lastHeard) > 5 else { return }
        disconnect()
        phase = .lost
    }
}

/// What the sender last sent, and when; only touched on the controller's network queue.
private final class SentState: @unchecked Sendable {
    struct Pad: Equatable {
        var mask: UInt32
        var left: SIMD2<Int16>
        var right: SIMD2<Int16>
    }

    var time: UInt64 = 0
    var pad: Pad?
}
