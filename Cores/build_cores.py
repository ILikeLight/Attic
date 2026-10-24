#!/usr/bin/env python3
"""Builds Attic's libretro cores as XCFrameworks.

Each core is built with its own libretro Makefile (platform=ios-arm64), or for
Dolphin with its CMake build, once for the iPhone and once for the Simulator. The
core's object files are then linked with attic_core.c into a dynamic framework
that exports only attic_<core>_core(), so the cores' internal symbols (many cores
share names such as filestream_open) never clash. The frameworks end up in
AtticCores/Frameworks/<Name>.xcframework.

The cores are always built optimised, also when the app is built for debugging.

Usage:
    python3 Cores/build_cores.py                  # all cores
    python3 Cores/build_cores.py nestopia bsnes   # some cores
    python3 Cores/build_cores.py --build-dir /tmp/attic-cores
    python3 Cores/build_cores.py dolphin --cmake /path/to/cmake   # CMake 3.25 or newer
"""
import argparse
import os
import plistlib
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
OUTPUT = os.path.join(PROJECT, "AtticCores", "Frameworks")
LIBRETRO_INCLUDE = os.path.join(PROJECT, "AtticCores", "Sources", "AtticLibretro", "include")
MIN_IOS = "18.0"
# The archive of a core's object files, before it is linked into its framework.
LIBRARY = "libattic_core.a"

SLICES = [
    ("iphoneos", f"arm64-apple-ios{MIN_IOS}", "iPhoneOS"),
    ("iphonesimulator", f"arm64-apple-ios{MIN_IOS}-simulator", "iPhoneSimulator"),
]


class Core:
    def __init__(self, name, framework, repo, commit, make_dir=".", makefile="Makefile", objects_var="OBJECTS",
                 make_args=(), patches=(), diffs=(), link_flags=(), submodules=False, skip_submodules=(),
                 cmake_target=None, cmake_args=(), simulator_cmake_args=(), resources=()):
        self.name = name
        self.framework = framework
        self.repo = repo
        self.commit = commit
        # The Makefile variable that lists the object files of the core.
        self.objects_var = objects_var
        self.make_dir = make_dir
        self.makefile = makefile
        self.make_args = list(make_args)
        # (path in the source tree, file in Cores/patches) pairs that replace upstream files.
        self.patches = list(patches)
        # Unified diffs in Cores/patches, applied to the source tree with patch -p1.
        self.diffs = list(diffs)
        self.link_flags = list(link_flags)
        self.submodules = submodules
        # Submodules a core does not need on iOS, left out of the checkout.
        self.skip_submodules = list(skip_submodules)
        # Built with CMake instead of make: the target whose link gives the core's inputs.
        self.cmake_target = cmake_target
        # "{source}" stands for the core's checkout, which keeps prebuilt libraries (the build
        # folder's copy of it leaves out .a files).
        self.cmake_args = list(cmake_args)
        # Added for the Simulator only, such as leaving out a library that has no Simulator build.
        self.simulator_cmake_args = list(simulator_cmake_args)
        # (path in the source tree, path in Attic/Resources) pairs: folders or files the core reads at run time.
        self.resources = list(resources)


CORES = {core.name: core for core in [
    Core("nestopia", "NestopiaCore",
         repo="https://github.com/libretro/nestopia.git",
         commit="06a8949e0b3cf60e3a38a374b1426bf40fccb9a0",
         make_dir="libretro"),
    Core("bsnes", "BsnesCore",
         repo="https://github.com/libretro/bsnes.git",
         commit="63ee22f7af8f5d1ada295c2c98fd7bf261fa62a7",
         # libco would make a data page executable with mprotect, which iOS forbids.
         patches=[("libco/aarch64.c", "bsnes/libco-aarch64.c")]),
    Core("melonds", "MelonDSCore",
         repo="https://github.com/libretro/melonDS.git",
         commit="66b5d2634cd0a79030562811e6e05f5532f800ba",
         make_args=["HAVE_WIFI=0", "HAVE_OPENGL=0", "HAVE_OPENGLES3=0", "JIT_ARCH="]),
    Core("pcsx", "PCSXCore",
         repo="https://github.com/libretro/pcsx_rearmed.git",
         commit="c8816799b50388e61cfe237fe2cdbb7d8175f20a",
         makefile="Makefile.libretro",
         objects_var="OBJS",
         make_args=["DYNAREC=0"],
         # Paths of at most 255 characters are too short for an app container.
         patches=[("include/config.h", "pcsx/config.h")],
         # retro_init traces the app itself (for the dynarec), after which iOS cannot terminate it.
         diffs=["pcsx/no-ptrace.diff"],
         submodules=True),
    Core("mupen64plus", "Mupen64PlusCore",
         repo="https://github.com/libretro/mupen64plus-libretro-nx.git",
         commit="12edd2c74a517ff86dfa8cfc71ad75e4c10486d5",
         # paraLLEl-RSP and paraLLEl-RDP need a JIT and Vulkan; GLideN64 draws with OpenGL ES 3.
         # Attic uses the HLE RSP, so the angrylion renderer and the cxd4 LLE RSP stay out too.
         # The bundled zlib has the same TARGET_OS_MAC trouble as libpng; iOS has its own.
         make_args=["HAVE_PARALLEL_RSP=0", "HAVE_PARALLEL_RDP=0", "HAVE_THR_AL=0", "LLE=0", "SYSTEM_ZLIB=1"],
         diffs=["mupen64plus/libpng-math.diff"],
         link_flags=["-framework", "OpenGLES", "-framework", "AudioToolbox"]),
    Core("dolphin", "DolphinCore",
         repo="https://github.com/libretro/dolphin.git",
         commit="5466da350f2fd143ee3e7b921e8c33aee64f7065",
         cmake_target="dolphin_libretro",
         # Dolphin draws with Vulkan on MoltenVK, which the app links for Azahar: on iOS's OpenGL ES it
         # could only stream vertices with glBufferSubData, and waited for the GPU all the time.
         # The GameCube's link to a GBA (mGBA) stays out. curl finds pipe2, which is new in iOS 27.
         # ThinLTO lets the interpreter inline across files, such as the memory accesses.
         cmake_args=["-DLIBRETRO=ON", "-DENABLE_VULKAN=ON", "-DUSE_MGBA=OFF", "-DHAVE_PIPE2=OFF",
                     "-DCMAKE_C_FLAGS=-flto=thin", "-DCMAKE_CXX_FLAGS=-flto=thin",
                     "-DCMAKE_SHARED_LINKER_FLAGS=-flto=thin -framework Foundation"],
         # The GBA settings only exist with mGBA, and iOS should run the emulated CPU on a fast core.
         # The Cached Interpreter is iCube's (Provenance-Emu/dolphin-ios-jitless): a much faster one
         # for devices without JIT, on the same upstream Dolphin (2609) as this libretro fork. iOS has no
         # libvulkan to load: the Vulkan functions come from the frontend, and the frontend reads 8-bit
         # pictures. Save states pause the CPU thread for real before they touch its state. The iPhone's
         # accelerometer moves the Wii Remote with a Nunchuk plugged in too.
         diffs=["dolphin/no-mgba.diff", "dolphin/cpu-thread-qos.diff", "dolphin/icube-cached-interpreter.diff",
                "dolphin/libretro-vulkan-apple.diff", "dolphin/libretro-state-pause.diff",
                "dolphin/libretro-nunchuk-motion.diff"],
         submodules=True,
         # Windows, desktop and Android libraries that the libretro build does not use.
         skip_submodules=["Externals/Qt", "Externals/FFmpeg-bin", "Externals/SDL/SDL", "Externals/cubeb/cubeb",
                          "Externals/gtest", "Externals/libadrenotools", "Externals/wil", "Externals/libusb/libusb",
                          "Externals/mGBA/mgba"],
         link_flags=["-flto=thin", "-framework", "Foundation", "-framework", "OpenGLES"],
         # Game fixes, the GameCube's fonts and DSP ROM, and Wii files; the UI themes and
         # title lists in Data/Sys are not needed.
         resources=[(f"Data/Sys/{folder}", f"Dolphin.bundle/Sys/{folder}")
                    for folder in ["GameSettings", "GC", "Wii", "Load", "Shaders"]]),
    Core("flycast", "FlycastCore",
         repo="https://github.com/flyinghead/flycast.git",
         commit="fa9d39a355ed06cbc27ea8d807f1cb6b8d766cf0",
         cmake_target="flycast_libretro",
         # iOS allows no JIT: TARGET_NO_REC builds the interpreters for the SH4, the ARM7 and the
         # sound DSP, as Flycast already does for the Simulator. It draws with OpenGL ES 3.
         cmake_args=["-DLIBRETRO=ON", "-DUSE_OPENMP=OFF", "-DUSE_VULKAN=OFF", "-DUSE_BREAKPAD=OFF", "-DUSE_LUA=OFF",
                     # libretro's own iOS build defines IOS, which picks the OpenGL ES headers.
                     "-DCMAKE_C_FLAGS=-DIOS -DTARGET_NO_REC -flto=thin", "-DCMAKE_CXX_FLAGS=-DIOS -DTARGET_NO_REC -flto=thin",
                     "-DCMAKE_SHARED_LINKER_FLAGS=-flto=thin"],
         # iOS should run the emulation thread on a fast core. The interpreter's SH4 clock follows
         # reicast_sh4clock instead of being fixed at 25 MHz, and frames are skipped from 95% speed.
         diffs=["flycast/emu-thread-qos.diff", "flycast/interpreter-clock.diff"],
         submodules=True,
         # Libraries for the stand-alone app, desktops and Android.
         skip_submodules=["core/deps/SDL", "core/deps/breakpad", "core/deps/oboe", "core/deps/Syphon",
                          "core/deps/Spout", "core/deps/discord-rpc", "core/deps/libadrenotools",
                          "core/deps/googletest"],
         link_flags=["-flto=thin", "-framework", "Foundation", "-framework", "OpenGLES"]),
    Core("azahar", "AzaharCore",
         repo="https://github.com/azahar-emu/azahar.git",
         commit="219d743a1e698101fe1ab8bef43e6563126c3c27",  # 2126.2
         cmake_target="citra_libretro",
         # iOS allows no JIT: the 3DS processor runs on Azahar's interpreter (a core option).
         # Apple has no OpenGL for Azahar, so it draws with Vulkan, which the app provides
         # through MoltenVK. The software renderer is only for the Simulator, whose Metal
         # cannot make the texel buffers the Vulkan renderer uses.
         cmake_args=["-DENABLE_LIBRETRO=ON", "-DENABLE_VULKAN=ON", "-DENABLE_OPENGL=OFF",
                     "-DENABLE_SOFTWARE_RENDERER=ON", "-DENABLE_TESTS=OFF", "-DCITRA_WARNINGS_AS_ERRORS=OFF",
                     "-DCITRA_USE_PRECOMPILED_HEADERS=OFF", "-DENABLE_LTO=OFF",
                     "-DCMAKE_C_FLAGS=-flto=thin", "-DCMAKE_CXX_FLAGS=-flto=thin",
                     "-DCMAKE_SHARED_LINKER_FLAGS=-flto=thin"],
         submodules=True,
         # Libraries for the stand-alone apps, tests, x86 and Android.
         skip_submodules=["externals/catch2", "externals/xbyak", "externals/libusb/libusb", "externals/cubeb",
                          "externals/discord-rpc", "externals/cpp-jwt", "externals/sdl2/SDL", "externals/openal-soft",
                          "externals/libadrenotools", "externals/libyuv", "externals/dllwalker"],
         link_flags=["-flto=thin", "-framework", "Foundation", "-framework", "AVFoundation", "-framework", "IOSurface"]),
    Core("ppsspp", "PPSSPPCore",
         repo="https://github.com/hrydgard/ppsspp.git",
         commit="fa50bb1976065c4f8b1b47af227d367fe9771555",  # v1.20.4
         cmake_target="ppsspp_libretro",
         # iOS allows no JIT: PPSSPP falls back to its IR interpreter there by itself, and the
         # profile asks for it too. It draws with OpenGL ES 3, as Dolphin and Flycast do. The
         # settings below are those of PPSSPP's own iOS toolchain (cmake/Toolchains/ios.cmake).
         cmake_args=["-DLIBRETRO=ON", "-DUSING_GLES2=ON", "-DMOBILE_DEVICE=ON", "-DOPENGL_LIBRARIES=-framework OpenGLES",
                     "-DUSE_DISCORD=OFF", "-DUSE_MINIUPNPC=OFF", "-DHEADLESS=OFF", "-DUNITTEST=OFF", "-DATLAS_TOOL=OFF",
                     "-DUSE_CCACHE=OFF", "-DUSE_SYSTEM_LIBPNG=OFF", "-DUSE_SYSTEM_ZSTD=OFF", "-DUSE_SYSTEM_LIBZIP=OFF",
                     "-DUSE_SYSTEM_FREETYPE=OFF", "-DUSE_SYSTEM_SNAPPY=OFF", "-DUSE_SYSTEM_LIBCHDR=OFF",
                     # PPSSPP names its FFmpeg folder relative to the source, which CMake reads from the build folder.
                     "-DFFMPEG_DIR={source}/ffmpeg/ios/universal",
                     "-DCMAKE_C_FLAGS=-DGL_ETC1_RGB8_OES=0 -U__STRICT_ANSI__ -flto=thin",
                     "-DCMAKE_CXX_FLAGS=-DGL_ETC1_RGB8_OES=0 -U__STRICT_ANSI__ -flto=thin",
                     "-DCMAKE_SHARED_LINKER_FLAGS=-flto=thin"],
         # PPSSPP's FFmpeg for iOS (only for the videos in games) has no build for the Simulator.
         simulator_cmake_args=["-DUSE_FFMPEG=OFF"],
         submodules=True,
         # Tests, desktop and Android libraries, and PPSSPP's own MoltenVK and debugger web pages.
         # (OpenXR and miniupnp stay: their headers are included everywhere.)
         skip_submodules=["pspautotests", "ext/discord-rpc", "SDL/macOS", "ios/MoltenVK",
                          "ext/libadrenotools", "assets/debugger"],
         link_flags=["-flto=thin", "-framework", "Foundation", "-framework", "OpenGLES"],
         # Game fixes, the PSP's fonts and VFPU tables, and what the PSP's own dialogs draw with.
         resources=[(f"assets/{name}", f"PPSSPP.bundle/{name}")
                    for name in ["compat.ini", "knownfuncs.ini", "langregion.ini", "ppge_atlas.zim", "ppge_atlas.meta",
                                 "font_atlas.zim", "font_atlas.meta", "asciifont_atlas.zim", "asciifont_atlas.meta",
                                 "flash0", "vfpu", "lang", "shaders"]]),
]}


def run(command, cwd=None, quiet=False):
    printable = " ".join(command) if isinstance(command, list) else command
    print(f"  $ {printable[:160]}{'…' if len(printable) > 160 else ''}", flush=True)
    result = subprocess.run(command, cwd=cwd, stdout=subprocess.PIPE if quiet else None,
                            stderr=subprocess.STDOUT if quiet else None, text=True)
    if result.returncode != 0:
        if quiet and result.stdout:
            # The error lines, as the warnings around them can be thousands of lines long.
            errors = [line for line in result.stdout.splitlines()
                      if "error:" in line or "*** " in line or "CMake Error" in line]
            print("\n".join(errors[:30]) if errors else result.stdout[-6000:])
        sys.exit(f"command failed with exit code {result.returncode}")
    return result.stdout


def fetch(core, source):
    """Checks out the pinned commit, reusing an existing checkout when it matches."""
    if os.path.isdir(os.path.join(source, ".git")):
        head = subprocess.run(["git", "-C", source, "rev-parse", "HEAD"], stdout=subprocess.PIPE, text=True).stdout.strip()
        if head == core.commit:
            return
        shutil.rmtree(source)
    os.makedirs(source)
    run(["git", "init", "-q"], cwd=source)
    run(["git", "remote", "add", "origin", core.repo], cwd=source)
    run(["git", "fetch", "-q", "--depth", "1", "origin", core.commit], cwd=source)
    run(["git", "checkout", "-q", "FETCH_HEAD"], cwd=source)
    if core.submodules:
        paths = run(["git", "config", "-f", ".gitmodules", "--get-regexp", "path"], cwd=source, quiet=True).split()[1::2]
        wanted = [path for path in paths if path not in core.skip_submodules]
        run(["git", "submodule", "update", "-q", "--init", "--depth", "1", "--recursive", "--", *wanted], cwd=source)


def sdk_path(sdk):
    return subprocess.run(["xcrun", "--sdk", sdk, "--show-sdk-path"], stdout=subprocess.PIPE, text=True).stdout.strip()


def build_cmake(core, source, tree, work, sdk, jobs, cmake):
    """Builds a CMake core and returns the inputs of its final link: objects, archives and flags."""
    build = os.path.join(work, "build")
    # CMake refuses a build folder that was configured somewhere else, as after moving --build-dir;
    # its objects refer to the old place too, so such a folder is built afresh.
    cache = os.path.join(build, "CMakeCache.txt")
    if os.path.exists(cache):
        with open(cache) as file:
            made_in = next((line.split("=", 1)[1].strip() for line in file
                            if line.startswith("CMAKE_CACHEFILE_DIR:")), build)
        if os.path.realpath(made_in) != os.path.realpath(build):
            shutil.rmtree(build)
    run([cmake, "-S", tree, "-B", build, "-G", "Unix Makefiles",
         "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_SYSTEM_NAME=iOS", "-DCMAKE_SYSTEM_PROCESSOR=arm64",
         "-DCMAKE_OSX_ARCHITECTURES=arm64", f"-DCMAKE_OSX_DEPLOYMENT_TARGET={MIN_IOS}", f"-DCMAKE_OSX_SYSROOT={sdk}",
         "-DCMAKE_POSITION_INDEPENDENT_CODE=ON", "-DIOS=ON",
         # Some bundled libraries still ask for CMake versions older than CMake 4 supports.
         "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
         *(arg.replace("{source}", source) for arg in core.cmake_args),
         *(core.simulator_cmake_args if sdk == "iphonesimulator" else [])], quiet=True)
    run([cmake, "--build", build, "--target", core.cmake_target, f"-j{jobs}"], quiet=True)
    # CMake writes the target's link command, run from the target's folder, to link.txt.
    target_dir = os.path.join("CMakeFiles", f"{core.cmake_target}.dir")
    for root, _, files in os.walk(build):
        if root.endswith(target_dir) and "link.txt" in files:
            link_dir = os.path.dirname(os.path.dirname(root))
            with open(os.path.join(root, "link.txt")) as file:
                words = iter(file.read().split())
            break
    else:
        sys.exit(f"no link command for {core.cmake_target}")
    inputs = []
    for word in words:
        word = word.strip('"')   # CMake quotes some paths
        if word.endswith((".o", ".a")):
            inputs.append(os.path.normpath(os.path.join(link_dir, word)))
        elif word == "-framework":
            inputs += [word, next(words)]
        elif word.startswith("-l"):
            inputs.append(word)
    return inputs


def build_slice(core, source, work, sdk, target, platform_name, jobs, cmake):
    tree = os.path.join(work, "src")
    os.makedirs(tree, exist_ok=True)
    # rsync keeps timestamps, so make only rebuilds what changed.
    run(["rsync", "-a", "--delete", "--exclude", ".git", "--exclude", "*.o", "--exclude", "*.a",
         source + "/", tree + "/"], quiet=True)
    for relative, replacement in core.patches:
        shutil.copyfile(os.path.join(HERE, "patches", replacement), os.path.join(tree, relative))
    for diff in core.diffs:
        run(["patch", "-p1", "-s", "-d", tree, "-i", os.path.join(HERE, "patches", diff)])

    sysroot = sdk_path(sdk)
    if core.cmake_target:
        inputs = build_cmake(core, source, tree, work, sdk, jobs, cmake)
    else:
        inputs = build_make(core, tree, sdk, target, sysroot, jobs)
    return link_framework(core, work, sdk, target, sysroot, platform_name, inputs)


def build_make(core, tree, sdk, target, sysroot, jobs):
    """Builds a core with its Makefile and returns the input of the final link: its archive."""
    compiler = f"xcrun --sdk {sdk} clang -target {target} -isysroot {sysroot}"
    # Build the core's normal (shared-library) configuration, but stop at the object
    # files: a small makefile includes the core's own and adds a goal that writes
    # the object list. The archive and the final link are done here.
    # (STATIC_LINKING=1 would leave out the libretro-common files that RetroArch
    # provides itself.)
    make_dir = os.path.join(tree, core.make_dir)
    with open(os.path.join(make_dir, "attic.mk"), "w") as file:
        variable = core.objects_var
        file.write(f"include {core.makefile}\n\nattic-objects: $({variable})\n\t@echo $({variable}) > attic-objects.txt\n")
    make = ["make", "-C", make_dir, "-f", "attic.mk", f"-j{jobs}",
            "platform=ios-arm64", f"IOSSDK={sysroot}",
            f"CC={compiler}", f"CXX={compiler.replace(' clang ', ' clang++ ')}", f"AR=xcrun --sdk {sdk} ar",
            *core.make_args, "attic-objects"]
    run(make, quiet=True)
    with open(os.path.join(make_dir, "attic-objects.txt")) as file:
        objects = file.read().split()
    library = os.path.join(make_dir, LIBRARY)
    if os.path.exists(library):
        os.remove(library)
    run(["xcrun", "--sdk", sdk, "ar", "rcs", library, *objects], cwd=make_dir)
    return [f"-Wl,-force_load,{library}"]


def link_framework(core, work, sdk, target, sysroot, platform_name, inputs):
    wrapper = os.path.join(work, "attic_core.o")
    run(["xcrun", "--sdk", sdk, "clang", "-target", target, "-isysroot", sysroot, "-O2", "-fPIC",
         f"-DATTIC_CORE={core.name}", f"-I{LIBRETRO_INCLUDE}", "-c", os.path.join(HERE, "attic_core.c"), "-o", wrapper])

    framework = os.path.join(work, f"{core.framework}.framework")
    shutil.rmtree(framework, ignore_errors=True)
    os.makedirs(framework)
    run(["xcrun", "--sdk", sdk, "clang++", "-target", target, "-isysroot", sysroot, "-dynamiclib",
         "-o", os.path.join(framework, core.framework), wrapper, *inputs,
         "-install_name", f"@rpath/{core.framework}.framework/{core.framework}",
         f"-Wl,-exported_symbol,_attic_{core.name}_core", "-Wl,-dead_strip",
         "-lz", *core.link_flags])
    write_bundle_files(framework, core.framework, core.name, core.commit[:7], platform_name)
    return framework


# APIs Apple wants a reason for (privacy manifest), by the symbols that use them, with the reason
# that applies to a core: files in the app's own container, free space before writing, timing.
REQUIRED_REASONS = [
    ("NSPrivacyAccessedAPICategoryFileTimestamp",
     {"_stat", "_fstat", "_lstat", "_fstatat", "_getattrlist", "_fgetattrlist", "_getattrlistat", "_getattrlistbulk"}, "C617.1"),
    ("NSPrivacyAccessedAPICategoryDiskSpace", {"_statfs", "_fstatfs", "_statvfs", "_fstatvfs"}, "E174.1"),
    ("NSPrivacyAccessedAPICategorySystemBootTime", {"_mach_absolute_time"}, "35F9.1"),
]


def write_bundle_files(framework, name, core_name, commit, platform_name):
    """The framework's Info.plist and privacy manifest. The App Store wants a CFBundleVersion of
    numbers only, so the core's commit goes in its own key."""
    with open(os.path.join(framework, "Info.plist"), "wb") as file:
        plistlib.dump({
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": name,
            "CFBundleIdentifier": f"app.attic.core.{core_name}",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": name,
            "CFBundlePackageType": "FMWK",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "AtticCoreCommit": commit,
            "CFBundleSupportedPlatforms": [platform_name],
            "MinimumOSVersion": MIN_IOS,
        }, file)
    symbols = set(subprocess.run(["nm", "-u", os.path.join(framework, name)], capture_output=True, text=True,
                                 check=True).stdout.split())
    with open(os.path.join(framework, "PrivacyInfo.xcprivacy"), "wb") as file:
        plistlib.dump({
            "NSPrivacyTracking": False,
            "NSPrivacyTrackingDomains": [],
            "NSPrivacyCollectedDataTypes": [],
            "NSPrivacyAccessedAPITypes": [
                {"NSPrivacyAccessedAPIType": category, "NSPrivacyAccessedAPITypeReasons": [reason]}
                for category, apis, reason in REQUIRED_REASONS if symbols & apis
            ],
        }, file)


def build(core, build_dir, jobs, cmake):
    print(f"== {core.name} ({core.commit[:7]})", flush=True)
    source = os.path.join(build_dir, "src", core.name)
    fetch(core, source)
    frameworks = []
    for sdk, target, platform_name in SLICES:
        work = os.path.join(build_dir, "work", core.name, sdk)
        frameworks.append(build_slice(core, source, work, sdk, target, platform_name, jobs, cmake))

    for relative, destination in core.resources:
        target = os.path.join(PROJECT, "Attic", "Resources", destination)
        if os.path.isdir(os.path.join(source, relative)):
            shutil.rmtree(target, ignore_errors=True)
            shutil.copytree(os.path.join(source, relative), target)
        else:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copy2(os.path.join(source, relative), target)

    output = os.path.join(OUTPUT, f"{core.framework}.xcframework")
    shutil.rmtree(output, ignore_errors=True)
    os.makedirs(OUTPUT, exist_ok=True)
    command = ["xcodebuild", "-create-xcframework"]
    for framework in frameworks:
        command += ["-framework", framework]
    run(command + ["-output", output], quiet=True)
    print(f"   → {os.path.relpath(output, PROJECT)}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("cores", nargs="*", choices=[[]] + list(CORES), help="cores to build (default: all)")
    parser.add_argument("--build-dir", default=os.path.join(HERE, ".build"), help="sources and object files")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    parser.add_argument("--cmake", default=os.environ.get("CMAKE") or shutil.which("cmake"),
                        help="CMake 3.25 or newer, for Dolphin (default: cmake on the PATH)")
    args = parser.parse_args()
    names = args.cores or list(CORES)
    if any(CORES[name].cmake_target for name in names) and not args.cmake:
        sys.exit("Dolphin needs CMake: install it (cmake.org) or pass --cmake /path/to/cmake")
    for name in names:
        build(CORES[name], os.path.abspath(args.build_dir), args.jobs, args.cmake)


if __name__ == "__main__":
    main()
