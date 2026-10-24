#ifndef ATTIC_LIBRETRO_H
#define ATTIC_LIBRETRO_H

#include "libretro.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Function table for one statically linked libretro core.
///
/// Each core is compiled with its retro_* functions renamed to a core-specific
/// prefix (see Package.swift), so several cores fit in one app binary. The table
/// hides that prefix from the Swift frontend.
typedef struct AtticLibretroAPI {
    const char *identifier;
    void (*set_environment)(retro_environment_t);
    void (*set_video_refresh)(retro_video_refresh_t);
    void (*set_audio_sample)(retro_audio_sample_t);
    void (*set_audio_sample_batch)(retro_audio_sample_batch_t);
    void (*set_input_poll)(retro_input_poll_t);
    void (*set_input_state)(retro_input_state_t);
    void (*initialize)(void);
    void (*deinitialize)(void);
    unsigned (*api_version)(void);
    void (*get_system_info)(struct retro_system_info *info);
    void (*get_system_av_info)(struct retro_system_av_info *info);
    void (*set_controller_port_device)(unsigned port, unsigned device);
    void (*reset)(void);
    void (*run)(void);
    size_t (*serialize_size)(void);
    bool (*serialize)(void *data, size_t size);
    bool (*unserialize)(const void *data, size_t size);
    void (*cheat_reset)(void);
    void (*cheat_set)(unsigned index, bool enabled, const char *code);
    bool (*load_game)(const struct retro_game_info *game);
    void (*unload_game)(void);
    unsigned (*get_region)(void);
    void *(*get_memory_data)(unsigned id);
    size_t (*get_memory_size)(unsigned id);
} AtticLibretroAPI;

/// Entry points of the cores that live in their own frameworks (see Cores/build_cores.py).
const AtticLibretroAPI *attic_nestopia_core(void);
const AtticLibretroAPI *attic_bsnes_core(void);
const AtticLibretroAPI *attic_melonds_core(void);
const AtticLibretroAPI *attic_pcsx_core(void);
const AtticLibretroAPI *attic_mupen64plus_core(void);
const AtticLibretroAPI *attic_dolphin_core(void);
const AtticLibretroAPI *attic_flycast_core(void);
const AtticLibretroAPI *attic_azahar_core(void);
const AtticLibretroAPI *attic_ppsspp_core(void);

/// Vulkan for cores that draw with it (RETRO_HW_CONTEXT_VULKAN), on MoltenVK (see AtticVulkan.c).
typedef struct AtticVulkan AtticVulkan;

/// A frame copied out of the core's image: rows of `pitch` bytes, four bytes per pixel.
typedef struct AtticVulkanFrame {
    const void *pixels;
    unsigned width;
    unsigned height;
    size_t pitch;
    /// The pixels are RGBA instead of BGRA.
    bool red_first;
} AtticVulkanFrame;

/// Makes the Vulkan instance and device. `negotiation` is what the core gave with
/// RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE, or NULL.
/// Returns NULL when there is no usable Vulkan device.
AtticVulkan *attic_vulkan_create(const void *negotiation);

/// Waits for the GPU, then frees the device and the instance.
void attic_vulkan_destroy(AtticVulkan *vulkan);

/// The struct retro_hw_render_interface_vulkan for RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE.
const void *attic_vulkan_interface(AtticVulkan *vulkan);

/// For a frame the core hands over (RETRO_HW_FRAME_BUFFER_VALID): starts copying the image
/// it set into memory, and returns the frame before it, whose copy is done by then.
/// Returns false while there is no earlier frame.
bool attic_vulkan_finish_frame(AtticVulkan *vulkan, unsigned width, unsigned height, AtticVulkanFrame *frame);

/// Receives every log line a core writes through RETRO_ENVIRONMENT_GET_LOG_INTERFACE.
typedef void (*attic_libretro_log_sink)(enum retro_log_level level, const char *message);

/// Sets where core log lines go. Swift cannot implement the variadic libretro log
/// callback itself, so this C shim formats the message and forwards it.
void attic_libretro_set_log_sink(attic_libretro_log_sink sink);

/// The variadic log callback to hand to cores.
void attic_libretro_log(enum retro_log_level level, const char *fmt, ...);

/// Answers RETRO_ENVIRONMENT_GET_LOG_INTERFACE: points the struct retro_log_callback
/// at `data` to attic_libretro_log.
bool attic_libretro_fill_log_interface(void *data);

#ifdef __cplusplus
}
#endif

#endif
