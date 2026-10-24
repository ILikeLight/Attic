import AtticLibretro
import Foundation
import OpenGLES
import os
import Synchronization

/// A libretro core: mGBA is linked into the app, the others live in their own frameworks.
///
/// libretro calls back into the frontend through plain C function pointers, so
/// only one core can be active at a time; `LibretroCore.active` routes the callbacks.
/// Every method must be called on the emulation thread (see `EmulationRunner`).
final class LibretroCore {
    enum LoadError: LocalizedError {
        case noCore
        case unreadable
        case rejected
        case graphics

        var errorDescription: String? {
            switch self {
            case .noCore: "Er is nog geen emulator voor dit systeem"
            case .unreadable: "Het spelbestand kon niet worden gelezen"
            case .rejected: "De emulator kon dit spel niet starten"
            case .graphics: "De grafische chip kon niet worden klaargezet"
            }
        }
    }

    nonisolated(unsafe) fileprivate static var active: LibretroCore?

    let frameBuffer: FrameBuffer
    let input: InputState
    let audio: AudioOutput
    /// Set to false to drop the sound of a frame, e.g. the extra frames of fast-forward.
    var audioEnabled = true
    private(set) var avInfo = retro_system_av_info()
    /// Frames and sound the core delivered, for the performance figures (`PerformanceMonitor`).
    let statistics = CoreStatistics()
    /// Stereo samples the core sent since the last call, so how much game time that covered.
    /// Dolphin and Flycast send their sound from their own thread, so a frame's sound can come in
    /// just after `runFrame` returns; it then counts with the next call instead of getting lost.
    func takeAudioFrames() -> Int {
        audioFramesPending.exchange(0, ordering: .relaxed)
    }
    private let audioFramesPending = Atomic(0)

    private let api: AtticLibretroAPI
    /// Core options chosen instead of the core's defaults.
    private let overrides: [String: String]
    private var pixelFormat = RETRO_PIXEL_FORMAT_0RGB1555
    private let systemDirectory: UnsafeMutablePointer<CChar>
    private let saveDirectory: UnsafeMutablePointer<CChar>
    private var variables: [String: UnsafeMutablePointer<CChar>] = [:]
    private var gamePath: UnsafeMutablePointer<CChar>?
    private var gameData: UnsafeMutableRawPointer?
    private var loaded = false
    /// Buttons, touch and sticks for the frame being emulated, read once before `retro_run`.
    private var frameMask: UInt32 = 0
    private var framePointer = InputState.Pointer()
    private var frameSticks = (left: SIMD2<Int16>.zero, right: SIMD2<Int16>.zero)
    /// Buttons that push the right stick all the way: up, down, left, right (see `CoreProfile`).
    private let rightStickButtons: [PadButton]?
    /// The controller the core is told is plugged in, and on how many ports (see `CoreProfile`).
    private let portDevice: UInt32
    private let ports: Int
    /// What a core that draws with the GPU asked for, and the context it got: OpenGL ES
    /// (`renderer`) or Vulkan (`vulkan`, made once the game is loaded).
    private var hardwareRequest: retro_hw_render_callback?
    private var renderer: GLRenderer?
    private let preferredRenderer: retro_hw_context_type
    private var wantsVulkan = false
    private var vulkanNegotiation: UnsafeRawPointer?
    private var vulkan: OpaquePointer?
    /// The iPhone's accelerometer, offered to the core as player 1's (the Wii Remote's movement).
    private let motion: WiiMotion?
    /// Players 2 to 4 on other iPhones, and their buttons and sticks for the frame being emulated.
    private let remotePlayers: RemotePlayers?
    private var remoteFrame: [RemotePlayers.Pad] = []
    /// Players 2 to 4 hold Wii Remotes whose accelerometers come from their iPhones; held sideways
    /// in Dolphin, their level reading is along the screen's up instead of out of the buttons.
    private let remoteMotion: (enabled: Bool, sideways: Bool)
    /// The vibration the game asks for, per port (a Rumble Pak, a Wii Remote's motor).
    private let rumble: RumbleLevels?

    init(api: UnsafePointer<AtticLibretroAPI>, options: [String: String], rightStickButtons: [PadButton]? = nil,
         portDevice: UInt32 = UInt32(RETRO_DEVICE_JOYPAD), ports: Int = 1,
         preferredRenderer: retro_hw_context_type = RETRO_HW_CONTEXT_OPENGLES3, motion: WiiMotion? = nil,
         remotePlayers: RemotePlayers? = nil, remoteMotion: (enabled: Bool, sideways: Bool) = (false, false),
         rumble: RumbleLevels? = nil, frameBuffer: FrameBuffer, input: InputState, audio: AudioOutput, systemDirectory: URL, saveDirectory: URL) {
        self.api = api.pointee
        overrides = options
        self.rightStickButtons = rightStickButtons
        self.portDevice = portDevice
        self.ports = ports
        self.motion = motion
        self.remotePlayers = remotePlayers
        self.remoteMotion = remoteMotion
        self.rumble = rumble
        self.preferredRenderer = preferredRenderer
        self.frameBuffer = frameBuffer
        self.input = input
        self.audio = audio
        self.systemDirectory = strdup(systemDirectory.path)
        self.saveDirectory = strdup(saveDirectory.path)
    }

    deinit {
        free(systemDirectory)
        free(saveDirectory)
        free(gamePath)
        gameData?.deallocate()
        variables.values.forEach { free($0) }
    }

    func load(gameAt url: URL) throws {
        Self.active = self
        attic_libretro_set_log_sink { level, message in
            guard let message, level.rawValue >= RETRO_LOG_WARN.rawValue else { return }
            Logger.core.notice("\(String(cString: message), privacy: .public)")
        }
        api.set_environment(environmentCallback)
        api.initialize()
        api.set_video_refresh(videoCallback)
        api.set_audio_sample(audioSampleCallback)
        api.set_audio_sample_batch(audioBatchCallback)
        api.set_input_poll(inputPollCallback)
        api.set_input_state(inputStateCallback)

        gamePath = strdup(url.path)
        var info = retro_game_info(path: UnsafePointer(gamePath), data: nil, size: 0, meta: nil)

        // Disc-based cores read the file themselves (a PS1 disc can be 700 MB);
        // the others get the whole game in memory.
        var system = retro_system_info()
        api.get_system_info(&system)
        if !system.need_fullpath {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                api.deinitialize()
                Self.active = nil
                throw LoadError.unreadable
            }
            // The core may keep pointers to the game data, so it lives as long as the core.
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(data.count, 1), alignment: 16)
            data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
            gameData = buffer
            info.data = UnsafeRawPointer(buffer)
            info.size = data.count
        }

        guard api.load_game(&info) else {
            api.deinitialize()
            renderer = nil
            hardwareRequest = nil
            wantsVulkan = false
            Self.active = nil
            throw LoadError.rejected
        }
        loaded = true
        api.get_system_av_info(&avInfo)
        api.set_controller_port_device(0, portDevice)
        for port in 1..<max(ports, 1) {
            api.set_controller_port_device(UInt32(port), UInt32(RETRO_DEVICE_NONE))
        }

        if let request = hardwareRequest, wantsVulkan {
            // As in RetroArch, the Vulkan device is made after the game is loaded; the core may make it itself.
            guard let vulkan = attic_vulkan_create(vulkanNegotiation) else {
                unload()
                throw LoadError.graphics
            }
            self.vulkan = vulkan
            request.context_reset?()
        } else if let request = hardwareRequest, let renderer {
            // The framebuffers are made after the game is loaded, at the largest size the core can draw.
            let geometry = avInfo.geometry
            guard renderer.makeTargets(width: Int(max(geometry.max_width, geometry.base_width)),
                                       height: Int(max(geometry.max_height, geometry.base_height)),
                                       depth: request.depth, stencil: request.stencil) else {
                unload()
                throw LoadError.graphics
            }
            request.context_reset?()
        }
    }

    func unload() {
        guard loaded else { return }
        if renderer != nil {
            renderer?.makeCurrent()
            hardwareRequest?.context_destroy?()
        } else if vulkan != nil {
            hardwareRequest?.context_destroy?()
        }
        api.unload_game()
        api.deinitialize()
        renderer = nil
        attic_vulkan_destroy(vulkan)
        vulkan = nil
        loaded = false
        if Self.active === self {
            Self.active = nil
        }
    }

    func runFrame() {
        frameMask = input.nextFrameMask()
        framePointer = input.nextFramePointer()
        frameSticks = input.nextFrameSticks()
        remoteFrame = remotePlayers?.nextFrame() ?? []
        renderer?.makeCurrent()
        statistics.runs.add(1, ordering: .relaxed)
        api.run()
    }

    func reset() {
        api.reset()
    }

    var framesPerSecond: Double {
        avInfo.timing.fps > 0 ? avInfo.timing.fps : 60
    }

    var sampleRate: Double {
        avInfo.timing.sample_rate > 0 ? avInfo.timing.sample_rate : 48_000
    }

    // MARK: Save data

    /// Bytes of a save state; 0 when the core cannot save.
    var serializeSize: Int { api.serialize_size() }

    func serialize() -> Data? {
        let size = api.serialize_size()
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let ok = data.withUnsafeMutableBytes { api.serialize($0.baseAddress, size) }
        return ok ? data : nil
    }

    func unserialize(_ data: Data) -> Bool {
        data.withUnsafeBytes { api.unserialize($0.baseAddress, data.count) }
    }

    /// Battery-backed cartridge memory (RETRO_MEMORY_SAVE_RAM) or the real-time clock.
    func memory(_ id: UInt32) -> UnsafeMutableRawBufferPointer? {
        let size = api.get_memory_size(id)
        guard size > 0, let pointer = api.get_memory_data(id) else { return nil }
        return UnsafeMutableRawBufferPointer(start: pointer, count: size)
    }

    // MARK: Callbacks

    fileprivate func environment(_ command: UInt32, _ data: UnsafeMutableRawPointer?) -> Bool {
        switch command {
        case UInt32(RETRO_ENVIRONMENT_GET_CAN_DUPE):
            data?.storeBytes(of: true, as: Bool.self)
            return true
        case UInt32(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT):
            guard let format = data?.load(as: retro_pixel_format.self),
                  format == RETRO_PIXEL_FORMAT_RGB565 || format == RETRO_PIXEL_FORMAT_XRGB8888 || format == RETRO_PIXEL_FORMAT_0RGB1555
            else { return false }
            pixelFormat = format
            return true
        case UInt32(RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY):
            data?.storeBytes(of: UnsafePointer(systemDirectory), as: UnsafePointer<CChar>?.self)
            return true
        case UInt32(RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY):
            data?.storeBytes(of: UnsafePointer(saveDirectory), as: UnsafePointer<CChar>?.self)
            return true
        case UInt32(RETRO_ENVIRONMENT_GET_LOG_INTERFACE):
            return attic_libretro_fill_log_interface(data)
        case UInt32(RETRO_ENVIRONMENT_SET_VARIABLES):
            guard var pointer = data?.assumingMemoryBound(to: retro_variable.self) else { return false }
            while let key = pointer.pointee.key {
                let name = String(cString: key)
                if let value = pointer.pointee.value {
                    // "Description; default|other|..."
                    let description = String(cString: value)
                    let options = description.split(separator: ";", maxSplits: 1).last ?? ""
                    let first = options.split(separator: "|").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    setVariable(name, overrides[name] ?? first)
                }
                pointer += 1
            }
            return true
        case UInt32(RETRO_ENVIRONMENT_GET_VARIABLE):
            guard let variable = data?.assumingMemoryBound(to: retro_variable.self), let key = variable.pointee.key else { return false }
            let name = String(cString: key)
            if variables[name] == nil, let value = overrides[name] {
                setVariable(name, value)
            }
            guard let value = variables[name] else { return false }
            variable.pointee.value = UnsafePointer(value)
            return true
        case UInt32(RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE):
            data?.storeBytes(of: false, as: Bool.self)
            return true
        case Environment.getInputBitmasks:
            return true
        case Environment.getAudioVideoEnable:
            // Bit 0: render video, bit 1: render audio.
            data?.storeBytes(of: Int32(3), as: Int32.self)
            return true
        case UInt32(RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO):
            if let info = data?.load(as: retro_system_av_info.self) {
                avInfo = info
            }
            return true
        case UInt32(RETRO_ENVIRONMENT_SET_GEOMETRY):
            if let geometry = data?.load(as: retro_game_geometry.self) {
                avInfo.geometry = geometry
            }
            return true
        case UInt32(RETRO_ENVIRONMENT_SET_HW_RENDER):
            // Cores that draw with the GPU get OpenGL ES 3 (see GLRenderer), or Vulkan if their
            // profile prefers it (see AtticVulkan.c).
            guard let request = data?.assumingMemoryBound(to: retro_hw_render_callback.self) else { return false }
            switch request.pointee.context_type {
            case RETRO_HW_CONTEXT_VULKAN where preferredRenderer == RETRO_HW_CONTEXT_VULKAN:
                hardwareRequest = request.pointee
                wantsVulkan = true
                return true
            case RETRO_HW_CONTEXT_OPENGLES2, RETRO_HW_CONTEXT_OPENGLES3: break
            case RETRO_HW_CONTEXT_OPENGLES_VERSION where request.pointee.version_major <= 3: break
            default: return false
            }
            // The context is made now, so without one the core still refuses the game cleanly:
            // Mupen64Plus cannot be unloaded safely once it has loaded a game without a context.
            guard let renderer = renderer ?? GLRenderer() else { return false }
            self.renderer = renderer
            request.pointee.get_current_framebuffer = currentFramebufferCallback
            request.pointee.get_proc_address = procAddressCallback
            hardwareRequest = request.pointee
            return true
        // RETRO_ENVIRONMENT_GET_JIT_CAPABLE stays unanswered, which the cores read as "no JIT": Flycast
        // built without a JIT refuses to load if told outright that there is none.
        case UInt32(RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER):
            data?.storeBytes(of: preferredRenderer.rawValue, as: UInt32.self)
            return true
        case Environment.setHWRenderContextNegotiationInterface:
            vulkanNegotiation = UnsafeRawPointer(data)
            return true
        case Environment.getHWRenderInterface:
            guard let vulkan else { return false }
            data?.storeBytes(of: attic_vulkan_interface(vulkan), as: UnsafeRawPointer?.self)
            return true
        case UInt32(RETRO_ENVIRONMENT_GET_SENSOR_INTERFACE):
            guard motion != nil || remoteMotion.enabled else { return false }
            data?.storeBytes(of: retro_sensor_interface(set_sensor_state: sensorStateCallback, get_sensor_input: sensorInputCallback),
                             as: retro_sensor_interface.self)
            return true
        case UInt32(RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE):
            guard rumble != nil else { return false }
            data?.storeBytes(of: retro_rumble_interface(set_rumble_state: rumbleCallback), as: retro_rumble_interface.self)
            return true
        case UInt32(RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS), UInt32(RETRO_ENVIRONMENT_SET_CONTROLLER_INFO),
             Environment.setMemoryMaps, Environment.setSupportAchievements, UInt32(RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS),
             UInt32(RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL), UInt32(RETRO_ENVIRONMENT_SET_SUBSYSTEM_INFO),
             UInt32(RETRO_ENVIRONMENT_SET_MESSAGE), UInt32(RETRO_ENVIRONMENT_SET_MINIMUM_AUDIO_LATENCY),
             UInt32(RETRO_ENVIRONMENT_SET_CONTENT_INFO_OVERRIDE), UInt32(RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME),
             UInt32(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY), UInt32(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK),
             UInt32(RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE):
            return true
        default:
            return false
        }
    }

    private func setVariable(_ name: String, _ value: String) {
        if let old = variables[name] { free(old) }
        variables[name] = strdup(value)
    }

    fileprivate func video(_ data: UnsafeRawPointer, width: Int, height: Int, pitch: Int) {
        statistics.frames.add(1, ordering: .relaxed)
        frameBuffer.write(data, width: width, height: height, pitch: pitch, format: pixelFormat)
    }

    /// The core drew a frame into `currentFramebuffer`.
    fileprivate func hardwareFrame(width: Int, height: Int) {
        statistics.frames.add(1, ordering: .relaxed)
        if let vulkan {
            // A frame behind: the copy of the frame before this one is done by now.
            var frame = AtticVulkanFrame()
            if attic_vulkan_finish_frame(vulkan, UInt32(width), UInt32(height), &frame), let pixels = frame.pixels {
                frameBuffer.write(pixels, width: Int(frame.width), height: Int(frame.height), pitch: frame.pitch,
                                  format: RETRO_PIXEL_FORMAT_XRGB8888, redFirst: frame.red_first)
            }
            return
        }
        renderer?.finishFrame(width: width, height: height, flipped: hardwareRequest?.bottom_left_origin ?? true, into: frameBuffer)
    }

    fileprivate var currentFramebuffer: GLuint {
        renderer?.framebuffer ?? 0
    }

    fileprivate func audioBatch(_ samples: UnsafePointer<Int16>, frames: Int) {
        audioFramesPending.add(frames, ordering: .relaxed)
        statistics.audioFrames.add(frames, ordering: .relaxed)
        guard audioEnabled else { return }
        audio.push(samples, frames: frames)
    }

    /// Accelerometers only: player 1's from this iPhone, players 2 to 4's from theirs. The core asks once,
    /// when the game starts, so the other players' are offered before they join. The gyroscope stays
    /// off (see `WiiMotion`).
    fileprivate func sensorState(port: UInt32, action: retro_sensor_action) -> Bool {
        let available = port == 0 ? motion?.isAvailable ?? false : port <= 3 && remoteMotion.enabled
        switch action {
        case RETRO_SENSOR_ACCELEROMETER_ENABLE: return available
        case RETRO_SENSOR_ACCELEROMETER_DISABLE: return true
        default: return false
        }
    }

    fileprivate func sensorInput(port: UInt32, id: UInt32) -> Float {
        guard id <= UInt32(RETRO_SENSOR_ACCELEROMETER_Z) else { return 0 }
        if port == 0 {
            return motion?.reading.withLock { $0[Int(id)] } ?? 0
        }
        guard Int(port) <= remoteFrame.count else { return 0 }
        var reading = remoteFrame[Int(port) - 1].motion
        if reading == .zero {
            // Not joined yet, or an iPhone without movement: held level.
            reading = remoteMotion.sideways ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1)
        }
        return reading[Int(id)]
    }

    fileprivate func setRumble(port: UInt32, effect: retro_rumble_effect, strength: UInt16) -> Bool {
        guard let rumble else { return false }
        rumble.set(port: Int(port), strong: effect == RETRO_RUMBLE_STRONG, strength: strength)
        return true
    }

    /// Plugs a controller into a port while the game runs, or unplugs it: a player joining from
    /// another iPhone or leaving. Port 0 is player 1's.
    func setPlayer(port: Int, connected: Bool) {
        guard loaded, port > 0 else { return }
        api.set_controller_port_device(UInt32(port), connected ? portDevice : UInt32(RETRO_DEVICE_NONE))
    }

    fileprivate func inputState(port: UInt32, device: UInt32, index: UInt32, id: UInt32) -> Int16 {
        // Player 1 is this iPhone; players 2 to 4 are on other iPhones.
        let mask: UInt32
        let sticks: (left: SIMD2<Int16>, right: SIMD2<Int16>)
        if port == 0 {
            mask = frameMask
            sticks = (frameSticks.left, rightStick(mask: frameMask, stick: frameSticks.right))
        } else if Int(port) <= remoteFrame.count {
            let pad = remoteFrame[Int(port) - 1]
            mask = pad.held
            sticks = (pad.left, rightStick(mask: pad.held, stick: pad.right))
        } else {
            return 0
        }
        // Subclassed devices, such as Dolphin's Wii Remote with Nunchuk, ask with their base type.
        switch device & 0xFF {  // RETRO_DEVICE_MASK
        case UInt32(RETRO_DEVICE_ANALOG):
            let stick: SIMD2<Int16>
            switch index {
            case UInt32(RETRO_DEVICE_INDEX_ANALOG_LEFT): stick = sticks.left
            case UInt32(RETRO_DEVICE_INDEX_ANALOG_RIGHT): stick = sticks.right
            default: return 0
            }
            switch id {
            case UInt32(RETRO_DEVICE_ID_ANALOG_X): return stick.x
            case UInt32(RETRO_DEVICE_ID_ANALOG_Y): return stick.y
            default: return 0
            }
        case UInt32(RETRO_DEVICE_JOYPAD):
            if id == UInt32(RETRO_DEVICE_ID_JOYPAD_MASK) {
                return Int16(truncatingIfNeeded: mask)
            }
            return (mask >> id) & 1 == 1 ? 1 : 0
        case UInt32(RETRO_DEVICE_POINTER) where port == 0:
            // Positions run from -0x8000 (left/top) to 0x7FFF (right/bottom) of the whole picture.
            let pointer = framePointer
            switch id {
            case UInt32(RETRO_DEVICE_ID_POINTER_X): return Int16(truncatingIfNeeded: Int(pointer.x) - 0x8000)
            case UInt32(RETRO_DEVICE_ID_POINTER_Y): return Int16(truncatingIfNeeded: Int(pointer.y) - 0x8000)
            case UInt32(RETRO_DEVICE_ID_POINTER_PRESSED), UInt32(RETRO_DEVICE_ID_POINTER_COUNT): return pointer.pressed ? 1 : 0
            default: return 0
            }
        default:
            return 0
        }
    }

    /// The right stick of a controller, or else the buttons that stand in for it.
    private func rightStick(mask: UInt32, stick: SIMD2<Int16>) -> SIMD2<Int16> {
        guard stick == .zero, let buttons = rightStickButtons, buttons.count == 4 else { return stick }
        func held(_ button: PadButton) -> Bool { mask & button.mask != 0 }
        let x: Int16 = held(buttons[3]) ? 0x7FFF : held(buttons[2]) ? -0x7FFF : 0
        let y: Int16 = held(buttons[1]) ? 0x7FFF : held(buttons[0]) ? -0x7FFF : 0
        return SIMD2(x, y)
    }
}

/// Counters the emulation thread raises and the performance figures read on the main thread.
final class CoreStatistics: Sendable {
    /// Frames the core delivered; a frame it repeats (a NULL frame) does not count.
    let frames = Atomic<Int>(0)
    /// Stereo samples the core delivered, also those that are not played (fast-forward).
    let audioFrames = Atomic<Int>(0)
    /// Times the core was run (`retro_run`).
    let runs = Atomic<Int>(0)
}

/// Environment commands that are defined as expressions in libretro.h.
private enum Environment {
    static let experimental: UInt32 = 0x10000
    static let getInputBitmasks: UInt32 = 51 | experimental
    static let setMemoryMaps: UInt32 = 36 | experimental
    static let setSupportAchievements: UInt32 = 42 | experimental
    static let getAudioVideoEnable: UInt32 = 47 | experimental
    static let getHWRenderInterface: UInt32 = 41 | experimental
    static let setHWRenderContextNegotiationInterface: UInt32 = 43 | experimental
}

private let environmentCallback: retro_environment_t = { command, data in
    LibretroCore.active?.environment(command, data) ?? false
}

private let videoCallback: retro_video_refresh_t = { data, width, height, pitch in
    // A NULL frame means "show the previous frame again".
    guard let data else { return }
    // RETRO_HW_FRAME_BUFFER_VALID, (void *)-1: the core drew into the framebuffer it was given.
    if UInt(bitPattern: data) == UInt.max {
        LibretroCore.active?.hardwareFrame(width: Int(width), height: Int(height))
        return
    }
    LibretroCore.active?.video(data, width: Int(width), height: Int(height), pitch: pitch)
}

private let currentFramebufferCallback: retro_hw_get_current_framebuffer_t = {
    UInt(LibretroCore.active?.currentFramebuffer ?? 0)
}

/// OpenGL ES functions are plain exports of the system framework.
private let procAddressCallback: retro_hw_get_proc_address_t = { name in
    guard let name, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }  // RTLD_DEFAULT
    return unsafeBitCast(symbol, to: retro_proc_address_t.self)
}

private let audioSampleCallback: retro_audio_sample_t = { left, right in
    var pair = [left, right]
    pair.withUnsafeBufferPointer { LibretroCore.active?.audioBatch($0.baseAddress!, frames: 1) }
}

private let audioBatchCallback: retro_audio_sample_batch_t = { samples, frames in
    if let samples {
        LibretroCore.active?.audioBatch(samples, frames: frames)
    }
    return frames
}

private let inputPollCallback: retro_input_poll_t = {}

private let inputStateCallback: retro_input_state_t = { port, device, index, id in
    LibretroCore.active?.inputState(port: port, device: device, index: index, id: id) ?? 0
}

private let sensorStateCallback: retro_set_sensor_state_t = { port, action, _ in
    LibretroCore.active?.sensorState(port: port, action: action) ?? false
}

private let sensorInputCallback: retro_sensor_get_input_t = { port, id in
    LibretroCore.active?.sensorInput(port: port, id: id) ?? 0
}

private let rumbleCallback: retro_set_rumble_state_t = { port, effect, strength in
    LibretroCore.active?.setRumble(port: port, effect: effect, strength: strength) ?? false
}

extension Logger {
    static let core = Logger(subsystem: "app.attic", category: "core")
    static let emulation = Logger(subsystem: "app.attic", category: "emulation")
    static let multiplayer = Logger(subsystem: "app.attic", category: "multiplayer")
}
