import AtticLibretro
import Foundation
import MGBACore

/// One emulator core and the options Attic runs it with.
struct CoreProfile {
    let identifier: String
    let api: () -> UnsafePointer<AtticLibretroAPI>?
    /// Core options chosen instead of the core's own defaults.
    let options: [String: String]
    /// Buttons that push the right stick all the way (up, down, left, right), for a core that
    /// reads buttons from that stick: the N64's C buttons.
    var rightStickButtons: [PadButton]? = nil
    /// The controller the core is told is plugged in.
    var portDevice = UInt32(RETRO_DEVICE_JOYPAD)
    /// The controller ports the core is told about: the first gets `portDevice`, the others nothing.
    var ports = 1
    /// The GPU interface offered to a core that draws with the GPU: OpenGL ES 3, or Vulkan (on MoltenVK).
    var renderer = RETRO_HW_CONTEXT_OPENGLES3
    /// Rewinding is offered; off for a core whose save states take too long to make several times a second.
    var rewinds = true
    /// A folder in the app (`<name>.bundle`) whose contents the core expects in its system folder.
    var systemFiles: (bundle: String, folder: String)? = nil
    /// The game is paced by the game time its sound covers rather than by frames: in a core that
    /// emulates in its own thread and returns each of the game's frames, a frame of a game that
    /// runs at 30 frames per second lasts two screen refreshes. Flycast, and Dolphin, whose frame
    /// step runs to the next new picture and which sends exactly one video field's sound per field
    /// (its default "Sync - Per Frame" audio): Wii menus at 30 frames per second ran at 200% otherwise.
    var pacesByAudio = false

    static func forSystem(_ system: GameSystem) -> CoreProfile? {
        switch system {
        case .gba, .gb: .mgba
        case .nes: .nestopia
        case .snes: .bsnes
        case .ds: .melonDS
        case .ps1: .pcsx
        case .n64: .mupen64plus
        case .gc: .dolphinGameCube
        case .wii: .dolphinWii
        case .dc: .flycast
        case .n3ds: .azahar
        case .psp: .ppsspp
        default: nil
        }
    }

    static let mgba = CoreProfile(identifier: "mgba", api: { attic_mgba_core() }, options: [
        "mgba_sgb_borders": "OFF",
        "mgba_frameskip": "disabled",
        "mgba_skip_bios": "ON",
    ])

    static let nestopia = CoreProfile(identifier: "nestopia", api: { attic_nestopia_core() }, options: [
        // Sharp pixels instead of the default composite-TV colour fringes.
        "nestopia_blargg_ntsc_filter": "disabled",
    ])

    static let bsnes = CoreProfile(identifier: "bsnes", api: { attic_bsnes_core() }, options: [
        // Built-in versions of the DSP and other chips, so games such as Super Mario Kart need no firmware files.
        "bsnes_coprocessor_prefer_hle": "ON",
    ])

    static let melonDS = CoreProfile(identifier: "melonds", api: { attic_melonds_core() }, options: [
        // Both screens stacked in one 256×384 picture; Attic shows them as two screens.
        "melonds_screen_layout": "Top/Bottom",
        "melonds_screen_gap": "0",
        "melonds_touch_mode": "Touch",
        // Start the game directly, with melonDS's built-in replacement BIOS.
        "melonds_boot_directly": "enabled",
        "melonds_console_mode": "DS",
        "melonds_threaded_renderer": "enabled",
    ])

    static let pcsx = CoreProfile(identifier: "pcsx", api: { attic_pcsx_core() }, options: [
        // iOS allows no recompiler; the interpreter is built in instead.
        "pcsx_rearmed_drc": "disabled",
        "pcsx_rearmed_show_bios_bootlogo": "disabled",
    ])

    static let mupen64plus = CoreProfile(identifier: "mupen64plus", api: { attic_mupen64plus_core() }, options: [
        // iOS allows no recompiler; the cached interpreter is the fastest without one.
        "mupen64plus-cpucore": "cached_interpreter",
        // GLideN64 draws with the GPU (OpenGL ES 3), at twice the N64's resolution.
        "mupen64plus-rdp-plugin": "gliden64",
        "mupen64plus-rsp-plugin": "hle",
        "mupen64plus-43screensize": "640x480",
        "mupen64plus-aspect": "4:3",
    ], rightStickButtons: [.x, .a, .l3, .r3])

    private static let dolphinOptions = [
        // iOS allows no JIT: the cached interpreter is the fastest way to run the PowerPC without one.
        "dolphin_cpu_core": "5",
        // Fastmem goes with the JIT, and its arena reserves 12 GB of address space.
        "dolphin_fastmem": "disabled",
        "dolphin_fastmem_arena": "disabled",
        "dolphin_efb_scale": "1",
        "dolphin_fast_disc_speed": "enabled",
        // Dolphin's own on-screen messages, such as a warning that iOS lacks EXT_buffer_storage.
        "dolphin_osd_enabled": "disabled",
        // Hybrid ubershaders, as iCube does on iOS: something new is drawn with a generic shader while its
        // own compiles in the background, so play never stalls on a compile. Settings › Prestaties can
        // change it (PerformanceSetting.dolphinShaders).
        "dolphin_shader_compilation_mode": "2",
        // Compiles the ubershaders and every shader the game used before (kept in its save folder,
        // User/Cache/Shaders) before the game starts: a longer start instead of hitches while playing.
        "dolphin_wait_for_shaders": "enabled",
    ]

    static let dolphinGameCube = CoreProfile(identifier: "dolphin", api: { attic_dolphin_core() }, options: dolphinOptions,
                                             renderer: dolphinRenderer, systemFiles: ("Dolphin", "dolphin-emu"), pacesByAudio: true)

    // RETRO_DEVICE_WIIMOTE_NC in Dolphin's Input.cpp: a Wii Remote with a Nunchuk.
    static let dolphinWii = CoreProfile(identifier: "dolphin", api: { attic_dolphin_core() }, options: dolphinOptions,
                                        portDevice: 3 << 8 | UInt32(RETRO_DEVICE_JOYPAD), renderer: dolphinRenderer,
                                        systemFiles: ("Dolphin", "dolphin-emu"), pacesByAudio: true)

    /// Vulkan (MoltenVK) on the iPhone: iOS's OpenGL ES lacks what Dolphin streams its vertices with,
    /// so there Dolphin waited for the GPU all the time (about 10% speed in Melee on an iPhone 14 Pro).
    /// The Simulator's Metal cannot run Dolphin's Vulkan renderer reliably, so it keeps OpenGL ES.
    private static var dolphinRenderer: retro_hw_context_type {
        #if targetEnvironment(simulator)
        RETRO_HW_CONTEXT_OPENGLES3
        #else
        RETRO_HW_CONTEXT_VULKAN
        #endif
    }

    static let flycast = CoreProfile(identifier: "flycast", api: { attic_flycast_core() }, options: [
        // The Dreamcast BIOS is replaced by Flycast's own, so games start without BIOS files.
        "reicast_hle_bios": "enabled",
        "reicast_internal_resolution": "640x480",
        // The emulation in its own thread, the drawing in the emulation thread of the app.
        "reicast_threaded_rendering": "enabled",
        // Without a JIT the sound chip's effects processor costs a lot; games lose some reverb.
        "reicast_enable_dsp": "disabled",
        // Draws fewer frames when the interpreter falls behind, so the game keeps its speed.
        "reicast_auto_skip_frame": "some",
        "reicast_gdrom_fast_loading": "enabled",
        // Each game gets its own memory card (VMU) in its own save folder, so one game cannot fill it for another.
        "reicast_per_content_vmus": "VMU A1",
        // The SH4 at a quarter of its 200 MHz, twice what Flycast's interpreter gives it
        // (Cores/patches/flycast/interpreter-clock.diff); Settings › Prestaties can change it (PerformanceSetting.dreamcastClock).
        "reicast_sh4clock": "50",
    ], ports: 4,  // Flycast only plugs a memory card into the controller once it has heard about all four ports.
       pacesByAudio: true)

    static let azahar = CoreProfile(identifier: "azahar", api: { attic_azahar_core() }, options: [
        // iOS allows no JIT: the 3DS processor and its vertex shaders run on interpreters.
        "citra_use_cpu_jit": "disabled",
        "citra_use_shader_jit": "disabled",
        "citra_use_hw_shader": "enabled",
        "citra_graphics_api": azaharGraphics,
        // The original 3DS: its slower processor gives the interpreter less to do per frame.
        // Games made only for the New 3DS do not start.
        "citra_is_new_3ds": "Old 3DS",
        "citra_resolution_factor": "1",
        // Both screens in one picture, the top one above the bottom one (see GameSystem.bottomRegion).
        "citra_layout_option": "default",
    ], renderer: RETRO_HW_CONTEXT_VULKAN, rewinds: false)  // A save state packs all of the 3DS's memory.

    static let ppsspp = CoreProfile(identifier: "ppsspp", api: { attic_ppsspp_core() }, options: [
        // iOS allows no JIT: PPSSPP's IR interpreter is its fastest processor without one.
        "ppsspp_cpu_core": "IR JIT",
        "ppsspp_backend": "opengl",
        // Twice the PSP's resolution: sharper on an iPhone screen, and little work for its GPU.
        "ppsspp_internal_resolution": "960x544",
    ], systemFiles: ("PPSSPP", "PPSSPP"))  // Game fixes, the PSP's fonts and VFPU tables (Cores/build_cores.py)

    /// Vulkan on the iPhone. The Simulator's Metal cannot make the texel buffers Azahar's Vulkan
    /// renderer uses, so there Azahar draws in software, which is slow but shows the game.
    private static var azaharGraphics: String {
        #if targetEnvironment(simulator)
        "Software"
        #else
        "Vulkan"
        #endif
    }

    /// Links the core's files from the app into its system folder; a link keeps them current after an update.
    func linkSystemFiles(into system: URL) {
        guard let (name, folder) = systemFiles,
              let source = Bundle.main.url(forResource: name, withExtension: "bundle") else { return }
        let fileManager = FileManager.default
        let target = system.appendingPathComponent(folder, isDirectory: true)
        try? fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        for item in (try? fileManager.contentsOfDirectory(atPath: source.path)) ?? [] {
            let link = target.appendingPathComponent(item)
            try? fileManager.removeItem(at: link)
            try? fileManager.createSymbolicLink(at: link, withDestinationURL: source.appendingPathComponent(item))
        }
    }
}
