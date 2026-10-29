import Foundation
import Network
import os
import Observation
import Synchronization

/// Lets other iPhones with Attic join the game being played as players 2 to 4, each only after
/// the player allows it. While open, the game is advertised with Bonjour (`PadLink`).
@MainActor
@Observable
final class MultiplayerHost {
    struct Player: Identifiable, Equatable {
        let id: UUID
        /// The controller port: 1 is player 2.
        let port: Int
        var number: Int { port + 1 }
    }

    private(set) var players: [Player] = []
    /// Controllers that asked to join and wait for an answer, the oldest first.
    private(set) var requests: [UUID] = []
    private(set) var isOpen = false
    /// Called when a player joins or leaves, with a short message for the player of this iPhone.
    @ObservationIgnored var onChange: (String) -> Void = { _ in }

    @ObservationIgnored private let session: EmulatorSession
    private nonisolated let remote: RemotePlayers
    /// How evenly each player's messages come in, for Prestaties tonen.
    private nonisolated let link = LinkMonitor()
    private nonisolated let queue = DispatchQueue(label: "app.attic.multiplayer", qos: .userInteractive)
    @ObservationIgnored private var listener: NWListener?
    /// The latest flow each controller wrote from, to answer it.
    @ObservationIgnored private var connections: [UUID: NWConnection] = [:]
    /// Controllers that were turned away, so their repeated questions get the same answer.
    @ObservationIgnored private var rejected: Set<UUID> = []
    /// The port of each player let in, read on the network queue for every input message.
    private nonisolated let admitted = Mutex<[UUID: Int]>([:])
    private nonisolated let lastHeard = Mutex<[UUID: TimeInterval]>([:])
    /// Each player's buttons as last received, to log only changes.
    private nonisolated let lastButtons = Mutex<[UUID: UInt32]>([:])
    @ObservationIgnored private var heartbeat: Timer?
    /// How hard each player's controller vibrates now, by port.
    @ObservationIgnored private var rumbles: [Int: UInt8] = [:]

    init(session: EmulatorSession) {
        self.session = session
        remote = session.remotePlayers
    }

    var maxPlayers: Int { session.game.system.maxPlayers }

    /// The player number the next one to join gets, if there is a place left.
    var nextPlayer: Int? { session.freePort.map { $0 + 1 } }

    /// The Wii controller the players get, the same as this iPhone's, so their iPhones show its buttons.
    private var controller: String {
        session.game.system == .wii ? session.game.wiiSettings.controller.rawValue : ""
    }

    /// `direct`: controllers may also reach this iPhone straight, without a Wi-Fi network (`PadLink.parameters`).
    func open(direct: Bool) {
        guard !isOpen, maxPlayers > 1, let listener = try? NWListener(using: PadLink.parameters(direct: direct)) else { return }
        listener.service = NWListener.Service(type: PadLink.serviceType,
                                              txtRecord: PadLink.txtRecord(title: session.game.title, system: session.game.system))
        listener.newConnectionHandler = { [weak self] connection in
            self?.start(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
        isOpen = true
        heartbeat = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.beat()
            }
        }
    }

    /// Stops advertising, tells the controllers the game is over and unplugs their players.
    func close() {
        guard isOpen else { return }
        for player in players {
            session.releasePort(player.port)
        }
        // Everyone who is in or asked hears that the game is over before their connection closes.
        for id in connections.keys {
            sendLast(.status(.ended, player: 0, system: "", title: "", controller: ""), to: id)
        }
        heartbeat?.invalidate()
        heartbeat = nil
        listener?.cancel()
        listener = nil
        connections = [:]
        admitted.withLock { $0 = [:] }
        rumbles = [:]
        for player in players {
            link.remove(port: player.port)
        }
        players = []
        requests = []
        rejected = []
        isOpen = false
    }

    func allow(_ id: UUID) {
        guard let index = requests.firstIndex(of: id) else { return }
        requests.remove(at: index)
        guard let port = session.claimPort() else {
            send(.status(.full, player: 0, system: "", title: "", controller: ""), to: id)
            return
        }
        let player = Player(id: id, port: port)
        rumbles[port] = nil
        link.remove(port: port)
        link.setRoute(PadLink.route(of: connections[id]?.currentPath), port: port)
        players.append(player)
        admitted.withLock { $0[id] = port }
        lastHeard.withLock { $0[id] = Date.timeIntervalSinceReferenceDate }
        sendAccepted(player)
        onChange("Speler \(player.number) doet mee")
    }

    func turnAway(_ id: UUID) {
        requests.removeAll { $0 == id }
        rejected.insert(id)
        send(.status(.rejected, player: 0, system: "", title: "", controller: ""), to: id)
    }

    /// Makes a player's controller on the other iPhone vibrate, 0 to 1 (`RumbleOutput`).
    func rumble(port: Int, strength: Float) {
        let value = UInt8(min(max(strength, 0), 1) * 255)
        guard rumbles[port, default: 0] != value else { return }
        rumbles[port] = value
        if let player = players.first(where: { $0.port == port }) {
            send(.rumble(strength: value), to: player.id)
        }
    }

    /// How evenly each player's messages came in lately, by player; once a second under Prestaties tonen.
    func linkFigures() -> [LinkMonitor.Figures] {
        link.figures(ports: players.map(\.port), frames: remote.frameCounts())
    }

    func remove(_ player: Player, message: String? = nil) {
        rumbles[player.port] = nil
        link.remove(port: player.port)
        players.removeAll { $0.id == player.id }
        admitted.withLock { $0[player.id] = nil }
        session.releasePort(player.port)
        sendLast(.status(.ended, player: player.number, system: "", title: "", controller: ""), to: player.id)
        onChange(message ?? "Speler \(player.number) is weg")
    }

    // MARK: Network queue

    private nonisolated func start(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection)
    }

    private nonisolated func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let message = PadMessage(data) {
                self.handle(message, from: connection)
            }
            if error == nil {
                self.receive(on: connection)
            }
        }
    }

    private nonisolated func handle(_ message: PadMessage, from connection: NWConnection) {
        switch message {
        case .input(let client, let mask, let left, let right, let motion, let stamp):
            // The fast path: straight to the emulation, without the main thread.
            guard let port = admitted.withLock({ $0[client] }) else { return }
            lastHeard.withLock { $0[client] = Date.timeIntervalSinceReferenceDate }
            link.arrived(port: port, stamp: stamp)
            remote.set(port: port, mask: mask, left: left, right: right, motion: motion)
            if lastButtons.withLock({ $0.updateValue(mask, forKey: client) }) != mask {
                Logger.multiplayer.debug("Speler \(port + 1): knoppen \(String(mask, radix: 2), privacy: .public)")
            }
        case .hello(let client):
            lastHeard.withLock { $0[client] = Date.timeIntervalSinceReferenceDate }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.hello(from: client, connection: connection)
                }
            }
        case .leave(let client):
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.left(client)
                }
            }
        case .status, .rumble:
            break
        }
    }

    // MARK: Main thread

    private func hello(from client: UUID, connection: NWConnection) {
        guard isOpen else { return }
        connections[client] = connection
        if let player = players.first(where: { $0.id == client }) {
            sendAccepted(player)
        } else if rejected.contains(client) {
            send(.status(.rejected, player: 0, system: "", title: "", controller: ""), to: client)
        } else if session.freePort == nil {
            send(.status(.full, player: 0, system: "", title: "", controller: ""), to: client)
        } else {
            if !requests.contains(client) {
                requests.append(client)
            }
            send(.status(.waiting, player: 0, system: session.game.system.rawValue, title: session.game.title, controller: controller), to: client)
        }
    }

    private func left(_ client: UUID) {
        requests.removeAll { $0 == client }
        if let player = players.first(where: { $0.id == client }) {
            remove(player)
        }
    }

    /// Twice a second: tells each player it is still in, and lets go of controllers gone quiet.
    private func beat() {
        let now = Date.timeIntervalSinceReferenceDate
        let heard = lastHeard.withLock { $0 }
        for player in players {
            if now - (heard[player.id] ?? 0) > 5 {
                remove(player, message: "Verbinding met speler \(player.number) verbroken")
            } else {
                sendAccepted(player)
                link.setRoute(PadLink.route(of: connections[player.id]?.currentPath), port: player.port)
            }
        }
        requests.removeAll { now - (heard[$0] ?? 0) > 5 }
    }

    private func sendAccepted(_ player: Player) {
        send(.status(.accepted, player: player.number, system: session.game.system.rawValue, title: session.game.title, controller: controller), to: player.id)
        if let rumble = rumbles[player.port] {
            send(.rumble(strength: rumble), to: player.id)
        }
    }

    private func send(_ message: PadMessage, to client: UUID) {
        connections[client]?.send(content: message.encoded(), completion: .idempotent)
    }

    /// Sends a last message, and closes the connection once it is out.
    private func sendLast(_ message: PadMessage, to client: UUID) {
        guard let connection = connections.removeValue(forKey: client) else { return }
        connection.send(content: message.encoded(), completion: .contentProcessed { _ in connection.cancel() })
    }
}
