import AtticLibretro
import Foundation
import Observation
import Photos
import UIKit

/// One playing session: loads the game into its core, runs it, and handles
/// pausing, fast-forward, save states and the battery save.
@MainActor
@Observable
final class EmulatorSession {
    enum State: Equatable {
        case starting
        case running
        case paused
        /// There is no emulator for this system in this build.
        case unsupported
        case failed(String)
        case stopped
    }

    let game: Game
    let frameBuffer = FrameBuffer()
    let input = InputState()
    private(set) var state: State = .starting
    private(set) var isFastForward = false
    /// Rewinding is on for this game: the setting is on and the core can make save states.
    private(set) var canRewind = false
    private(set) var isRewinding = false
    /// Width / height of the (top) screen, as in the design for each system.
    let aspectRatio: CGFloat

    /// Observed, so a view that shows `isActive` (the TV picture) updates when the game starts and stops.
    private var core: LibretroCore?
    @ObservationIgnored private var runner: EmulationRunner?
    @ObservationIgnored private let audio = AudioOutput()
    @ObservationIgnored private var runningSince: Date?
    @ObservationIgnored private var playedSeconds: TimeInterval = 0
    @ObservationIgnored private let paths: LibraryPaths
    @ObservationIgnored private let saveStates: SaveStateStore
    @ObservationIgnored private var monitor: PerformanceMonitor?
    /// The iPhone's movement as the Wii Remote's, in a Wii game that uses it (`Game.usesMotion`).
    @ObservationIgnored private var motion: WiiMotion?
    /// Players 2 to 4 from other iPhones (`MultiplayerHost`), in a game of a system with more ports.
    @ObservationIgnored let remotePlayers = RemotePlayers()
    /// The Wii Remote is held sideways like a steering wheel now, as some minigames ask (Mario Party 8's
    /// races); its movement then turns with it. Chosen while playing, so not kept with the game.
    var holdsWiiRemoteSideways = false {
        didSet { motion?.heldSideways = holdsWiiRemoteSideways }
    }
    /// Vibration the game asks for, by port and from 0 to 1, for the player screen to hand to a
    /// controller or an iPhone (`RumbleOutput`). Only changes come in.
    @ObservationIgnored var onRumble: (_ port: Int, _ strength: Float) -> Void = { _, _ in }
    @ObservationIgnored private var rumble: RumbleLevels?

    init(game: Game, saveStates: SaveStateStore, paths: LibraryPaths = .shared) {
        self.game = game
        self.saveStates = saveStates
        self.paths = paths
        aspectRatio = game.system.screen.aspectRatio
    }

    var isActive: Bool { core != nil }

    private var batteryURL: URL { paths.saveFolder(game.id).appendingPathComponent("battery.sav") }
    private var clockURL: URL { paths.saveFolder(game.id).appendingPathComponent("battery.rtc") }

    func start(from saveState: SaveState?, rewind: Bool = false, options: [String: String] = [:]) async {
        guard let profile = CoreProfile.forSystem(game.system), let api = profile.api() else {
            state = .unsupported
            return
        }
        try? FileManager.default.createDirectory(at: paths.saveFolder(game.id), withIntermediateDirectories: true)
        profile.linkSystemFiles(into: paths.system)
        let motion = game.usesMotion ? WiiMotion(sideways: game.wiiSettings.controller == .sideways) : nil
        self.motion = motion
        let rumble = RumbleLevels { [weak self] port, strength in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.onRumble(port, strength)
                }
            }
        }
        self.rumble = rumble
        let core = LibretroCore(api: api, options: profile.options.merging(options) { $1 }, rightStickButtons: profile.rightStickButtons,
                                portDevice: game.portDevice ?? profile.portDevice, ports: profile.ports, preferredRenderer: profile.renderer,
                                motion: motion, remotePlayers: game.system.maxPlayers > 1 ? remotePlayers : nil,
                                remoteMotion: (game.system == .wii && game.wiiSettings.controller.isWiiRemote,
                                               game.wiiSettings.controller == .sideways),
                                rumble: rumble, frameBuffer: frameBuffer, input: input, audio: audio,
                                systemDirectory: paths.system, saveDirectory: paths.saveFolder(game.id))
        let runner = EmulationRunner(core: core, pacesByAudio: profile.pacesByAudio)
        runner.start()

        let gameURL = paths.gameFile(game)
        let battery = try? Data(contentsOf: batteryURL)
        let clock = try? Data(contentsOf: clockURL)
        let stateData = saveState.flatMap { saveStates.data(for: $0, gameID: game.id) }
        let coreRewinds = rewind && profile.rewinds

        let (error, rewinds): (String?, Bool) = await runner.performAndWait {
            do {
                try core.load(gameAt: gameURL)
            } catch {
                return (error.localizedDescription, false)
            }
            // Load the cartridge memory before the first frame, as RetroArch does.
            if let battery, let memory = core.memory(UInt32(RETRO_MEMORY_SAVE_RAM)) {
                battery.prefix(memory.count).copyBytes(to: memory)
            }
            if let clock, let memory = core.memory(UInt32(RETRO_MEMORY_RTC)) {
                clock.prefix(memory.count).copyBytes(to: memory)
            }
            if let stateData, !core.unserialize(stateData) {
                // Mupen64Plus only takes a state once it has run a frame.
                core.audioEnabled = false
                core.runFrame()
                core.audioEnabled = true
                _ = core.unserialize(stateData)
            }
            // GameCube and Wii states are tens of megabytes: too big to take several times a second.
            if coreRewinds, (1...(32 << 20)).contains(core.serializeSize) {
                runner.rewind = RewindBuffer(stateSize: core.serializeSize, framesPerSecond: core.framesPerSecond)
            }
            return (nil, runner.rewind != nil)
        }
        canRewind = rewinds
        if let error {
            runner.stop()
            state = .failed(error)
            return
        }

        self.core = core
        self.runner = runner
        // Controllers that took a place before the game was loaded are plugged in now.
        for port in takenPorts {
            setPlayer(port: port, connected: true)
        }
        audio.configure(sampleRate: core.sampleRate)
        resume()
    }

    /// Ports 1 to 3 given to players 2 to 4, who play from another iPhone or a Bluetooth controller.
    private var takenPorts: Set<Int> = []

    /// The port the next player gets, if the game has one left.
    var freePort: Int? {
        (1..<game.system.maxPlayers).first { !takenPorts.contains($0) }
    }

    /// Gives the next player a port and plugs in its controller.
    func claimPort() -> Int? {
        guard let port = freePort else { return nil }
        takenPorts.insert(port)
        setPlayer(port: port, connected: true)
        return port
    }

    func releasePort(_ port: Int) {
        guard takenPorts.remove(port) != nil else { return }
        setPlayer(port: port, connected: false)
    }

    /// Plugs player `port + 1`'s controller in or out (port 1 is player 2), on the emulation thread.
    private func setPlayer(port: Int, connected: Bool) {
        if !connected {
            remotePlayers.clear(port: port)
        }
        guard let runner, let core else { return }
        runner.perform {
            core.setPlayer(port: port, connected: connected)
        }
    }

    /// How the iPhone is held now counts as the Wii Remote held level (`WiiMotion.level`).
    func levelWiiRemote() {
        motion?.level()
    }

    func resume() {
        guard let runner, state != .running else { return }
        audio.start()
        // Starting again also takes the way the iPhone is held now as the Wii Remote held level.
        motion?.start()
        runner.setPaused(false)
        runningSince = .now
        state = .running
    }

    func pause() {
        setRewinding(false)
        guard let runner, state == .running else { return }
        runner.setPaused(true)
        audio.pause()
        motion?.stop()
        // A motor that was running stops with the game; the game starts it again when it plays on.
        rumble?.stopAll()
        input.clear()
        if let runningSince {
            playedSeconds += Date.now.timeIntervalSince(runningSince)
        }
        runningSince = nil
        state = .paused
        monitor = nil
        Task { await saveBattery() }
    }

    /// How the game keeps up since the previous call; nil while it is not running and the first time.
    func performance() -> PerformanceMonitor.Figures? {
        guard let core, state == .running else { return nil }
        if monitor == nil {
            monitor = PerformanceMonitor(statistics: core.statistics, sampleRate: audio.sampleRate)
        }
        let figures = monitor?.sample()
        if let figures {
            PerformanceLog.write(figures, game: game.title, coreFramesPerSecond: core.framesPerSecond, sampleRate: core.sampleRate)
        }
        return figures
    }

    func setFastForward(_ on: Bool) {
        isFastForward = on
        runner?.setSpeed(on ? 2 : 1)
    }

    func reset() {
        guard let core, let runner else { return }
        runner.perform {
            core.reset()
            runner.rewind?.clear()
        }
    }

    /// While on, the game runs backwards; off, it plays on from where it is.
    func setRewinding(_ on: Bool) {
        guard canRewind, on != isRewinding, !on || state == .running else { return }
        isRewinding = on
        runner?.setRewinding(on)
    }

    // MARK: Saving

    func saveState(slot: Int?) async -> SaveState? {
        guard let core, let runner else { return nil }
        guard let data = await runner.performAndWait({ core.serialize() }) else { return nil }
        return saveStates.write(data, thumbnail: frameBuffer.image(region: thumbnailRegion), slot: slot, gameID: game.id)
    }

    func loadState(_ saveState: SaveState) async -> Bool {
        guard let core, let runner, let data = saveStates.data(for: saveState, gameID: game.id) else { return false }
        return await runner.performAndWait {
            let loaded = core.unserialize(data)
            // Winding back from here should not jump into the game as it was before loading.
            runner.rewind?.clear()
            return loaded
        }
    }

    /// Writes the cartridge's save memory, so in-game saves survive.
    func saveBattery() async {
        guard let core, let runner else { return }
        let batteryURL = batteryURL
        let clockURL = clockURL
        await runner.performAndWait {
            if let memory = core.memory(UInt32(RETRO_MEMORY_SAVE_RAM)) {
                let data = Data(memory)
                // An untouched GBA cartridge is all 0xFF; don't create a file for that.
                if FileManager.default.fileExists(atPath: batteryURL.path) || data.contains(where: { $0 != 0xFF }) {
                    try? data.write(to: batteryURL, options: .atomic)
                }
            }
            if let memory = core.memory(UInt32(RETRO_MEMORY_RTC)) {
                try? Data(memory).write(to: clockURL, options: .atomic)
            }
        }
    }

    /// The part of the picture that represents the game: for the DS, its top screen.
    private var thumbnailRegion: CGRect {
        game.system.screen.isDual ? CGRect(x: 0, y: 0, width: 1, height: 0.5) : CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    func screenshot() async -> Bool {
        guard let image = frameBuffer.image(scale: 4) else { return false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            return true
        } catch {
            return false
        }
    }

    /// Stops the game. Returns the time played in seconds and the auto-save, if one was made.
    func stop(autosave: Bool) async -> (played: TimeInterval, autosave: SaveState?) {
        pause()
        var made: SaveState?
        if autosave {
            made = await saveState(slot: nil)
        }
        await saveBattery()
        runner?.stop()
        audio.stop()
        runner = nil
        core = nil
        state = .stopped
        return (playedSeconds, made)
    }
}

extension EmulatorSession: PlayerSeats {}
