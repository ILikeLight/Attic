// swift-tools-version: 5.9
// Native code for Attic: the libretro API, the emulation cores and the 7z decoder.
import PackageDescription

/// Every core exports the libretro API under its own prefix, so several cores can
/// live in one app binary (iOS does not allow loading cores as separate libraries).
let libretroFunctions = [
    "retro_set_environment", "retro_set_video_refresh", "retro_set_audio_sample",
    "retro_set_audio_sample_batch", "retro_set_input_poll", "retro_set_input_state",
    "retro_init", "retro_deinit", "retro_api_version", "retro_get_system_info",
    "retro_get_system_av_info", "retro_set_controller_port_device", "retro_reset", "retro_run",
    "retro_serialize_size", "retro_serialize", "retro_unserialize", "retro_cheat_reset",
    "retro_cheat_set", "retro_load_game", "retro_load_game_special", "retro_unload_game",
    "retro_get_region", "retro_get_memory_data", "retro_get_memory_size",
]

func prefixed(_ prefix: String) -> [CSetting] {
    libretroFunctions.map { .define($0, to: "\(prefix)_\($0)") }
}

/// The source list of mGBA's own CMake libretro target (BUILD_LIBRETRO) for Apple platforms.
let mgbaSources = """
    src/arm/arm.c src/arm/decoder-arm.c src/arm/decoder.c src/arm/decoder-thumb.c src/arm/isa-arm.c src/arm/isa-thumb.c
    src/core/bitmap-cache.c src/core/cache-set.c src/core/cheats.c src/core/config.c src/core/core.c src/core/directories.c
    src/core/interface.c src/core/lockstep.c src/core/log.c src/core/map-cache.c src/core/serialize.c src/core/sync.c
    src/core/thread.c src/core/tile-cache.c src/core/timing.c
    src/gb/audio.c src/gb/cheats.c src/gb/core.c src/gb/gb.c src/gb/input.c src/gb/io.c src/gb/mbc.c src/gb/mbc/huc-3.c
    src/gb/mbc/licensed.c src/gb/mbc/mbc.c src/gb/mbc/pocket-cam.c src/gb/mbc/tama5.c src/gb/mbc/unlicensed.c src/gb/memory.c
    src/gb/overrides.c src/gb/serialize.c src/gb/renderers/cache-set.c src/gb/renderers/software.c src/gb/sio.c src/gb/timer.c
    src/gb/video.c
    src/gba/audio.c src/gba/bios.c src/gba/cart/ereader.c src/gba/cart/gpio.c src/gba/cart/matrix.c src/gba/cart/unlicensed.c
    src/gba/cart/vfame.c src/gba/cheats.c src/gba/cheats/codebreaker.c src/gba/cheats/gameshark.c src/gba/cheats/parv3.c
    src/gba/core.c src/gba/dma.c src/gba/gba.c src/gba/hle-bios.c src/gba/input.c src/gba/io.c src/gba/memory.c
    src/gba/overrides.c src/gba/renderers/cache-set.c src/gba/renderers/common.c src/gba/renderers/gl.c
    src/gba/renderers/software-bg.c src/gba/renderers/software-mode0.c src/gba/renderers/software-obj.c
    src/gba/renderers/video-software.c src/gba/savedata.c src/gba/serialize.c src/gba/sharkport.c src/gba/sio.c
    src/gba/sio/gbp.c src/gba/timer.c src/gba/video.c
    src/sm83/decoder.c src/sm83/isa-sm83.c src/sm83/sm83.c
    src/util/circle-buffer.c src/util/configuration.c src/util/crc32.c src/util/formatting.c src/util/gbk-table.c
    src/util/hash.c src/util/md5.c src/util/sha1.c src/util/string.c src/util/table.c src/util/vector.c src/util/vfs.c
    src/util/audio-buffer.c src/util/convolve.c src/util/elf-read.c src/util/geometry.c src/util/image.c
    src/util/image/export.c src/util/image/font.c src/util/image/png-io.c src/util/patch.c src/util/patch-fast.c
    src/util/patch-ips.c src/util/patch-ups.c src/util/ring-fifo.c src/util/sfo.c src/util/text-codec.c
    src/util/vfs/vfs-mem.c src/util/vfs/vfs-fifo.c src/util/vfs/vfs-fd.c src/util/vfs/vfs-dirent.c
    src/platform/posix/memory.c src/third-party/inih/ini.c
    src/platform/libretro/libretro.c src/platform/libretro/libretro-audio.c src/platform/libretro/libretro-vfs.c
    """.split(whereSeparator: \.isWhitespace).map { "mgba/" + $0 }

let sevenZipSources = """
    7zAlloc.c 7zArcIn.c 7zBuf.c 7zCrc.c 7zCrcOpt.c 7zDec.c 7zFile.c 7zStream.c Bcj2.c Bra.c Bra86.c BraIA64.c
    CpuArch.c Delta.c Lzma2Dec.c LzmaDec.c Ppmd7.c Ppmd7Dec.c
    """.split(whereSeparator: \.isWhitespace).map { "lzma/" + $0 }

let package = Package(
    name: "AtticCores",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "AtticCores", targets: [
            "AtticLibretro", "MGBACore", "SevenZip", "NestopiaCore", "BsnesCore", "MelonDSCore", "PCSXCore", "Mupen64PlusCore",
            "DolphinCore", "FlycastCore", "AzaharCore", "PPSSPPCore",
        ]),
    ],
    targets: [
        // The libretro API, plus Vulkan for cores that draw with it, on MoltenVK (Metal).
        .target(
            name: "AtticLibretro",
            dependencies: ["MoltenVK"],
            cSettings: [.headerSearchPath("vulkan-headers")],
            linkerSettings: [
                .linkedFramework("Metal"), .linkedFramework("QuartzCore"), .linkedFramework("IOSurface"),
                .linkedFramework("UIKit"), .linkedFramework("Foundation"), .linkedLibrary("c++"),
            ]
        ),
        // MoltenVK 1.4.1 (Khronos), the iOS and Simulator slices of its static library.
        .binaryTarget(name: "MoltenVK", path: "Frameworks/MoltenVK.xcframework"),
        // The other cores, built with their own Makefiles by Cores/build_cores.py. Each is a
        // separate dynamic framework, so their internal symbols cannot clash.
        .binaryTarget(name: "NestopiaCore", path: "Frameworks/NestopiaCore.xcframework"),
        .binaryTarget(name: "BsnesCore", path: "Frameworks/BsnesCore.xcframework"),
        .binaryTarget(name: "MelonDSCore", path: "Frameworks/MelonDSCore.xcframework"),
        .binaryTarget(name: "PCSXCore", path: "Frameworks/PCSXCore.xcframework"),
        .binaryTarget(name: "Mupen64PlusCore", path: "Frameworks/Mupen64PlusCore.xcframework"),
        .binaryTarget(name: "DolphinCore", path: "Frameworks/DolphinCore.xcframework"),
        .binaryTarget(name: "FlycastCore", path: "Frameworks/FlycastCore.xcframework"),
        .binaryTarget(name: "AzaharCore", path: "Frameworks/AzaharCore.xcframework"),
        .binaryTarget(name: "PPSSPPCore", path: "Frameworks/PPSSPPCore.xcframework"),
        .target(
            name: "MGBACore",
            dependencies: ["AtticLibretro"],
            exclude: ["mgba/LICENSE", "mgba/src/third-party/inih/LICENSE.txt"],
            sources: mgbaSources + ["generated/version.c", "attic_mgba_core.c"],
            cSettings: [
                .headerSearchPath("mgba/include"),
                .headerSearchPath("mgba/src"),
                .define("__LIBRETRO__"),
                .define("_GNU_SOURCE"),
                .define("COLOR_16_BIT"),
                .define("COLOR_5_6_5"),
                .define("DISABLE_THREADING"),
                .define("MGBA_STANDALONE"),
                .define("MINIMAL_CORE", to: "2"),
                .define("M_CORE_GB"),
                .define("M_CORE_GBA"),
                .define("ENABLE_VFS"),
                .define("ENABLE_VFS_FD"),
                .define("ENABLE_DIRECTORIES"),
                .define("HAVE_STRDUP"),
                .define("HAVE_STRLCPY"),
                .define("HAVE_STRNDUP"),
                .define("HAVE_VASPRINTF"),
                .define("HAVE_LOCALE"),
                .define("HAVE_XLOCALE"),
                .define("HAVE_SNPRINTF_L"),
                .define("HAVE_USELOCALE"),
                .define("HAVE_NEWLOCALE"),
                .define("HAVE_FREELOCALE"),
                .define("HAVE_SETLOCALE"),
                .define("HAVE_STRTOF_L"),
                .define("HAVE_LOCALTIME_R"),
                .define("HAVE_FUTIMENS"),
                .define("HAVE_FUTIMES"),
                .define("HAVE_REALPATH"),
            ] + prefixed("mgba")
        ),
        .target(
            name: "SevenZip",
            exclude: ["lzma/README-7zip.md"],
            sources: sevenZipSources + ["attic_7z.c"],
            cSettings: [
                .headerSearchPath("lzma"),
                .define("Z7_PPMD_SUPPORT"),
            ]
        ),
    ]
)
