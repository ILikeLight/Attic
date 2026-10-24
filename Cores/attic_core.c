// Exposes one libretro core to the Attic app.
//
// build_cores.py compiles this file once per core with -DATTIC_CORE=<name> and
// links it with the core into a framework that exports only attic_<name>_core().
// Every other symbol of the core stays inside its own framework.

#include "AtticLibretro.h"

#define ATTIC_JOIN2(a, b) a##b
#define ATTIC_JOIN(a, b) ATTIC_JOIN2(a, b)
#define ATTIC_STRING2(x) #x
#define ATTIC_STRING(x) ATTIC_STRING2(x)
#define ATTIC_ENTRY ATTIC_JOIN(ATTIC_JOIN(attic_, ATTIC_CORE), _core)

static const AtticLibretroAPI api = {
    .identifier = ATTIC_STRING(ATTIC_CORE),
    .set_environment = retro_set_environment,
    .set_video_refresh = retro_set_video_refresh,
    .set_audio_sample = retro_set_audio_sample,
    .set_audio_sample_batch = retro_set_audio_sample_batch,
    .set_input_poll = retro_set_input_poll,
    .set_input_state = retro_set_input_state,
    .initialize = retro_init,
    .deinitialize = retro_deinit,
    .api_version = retro_api_version,
    .get_system_info = retro_get_system_info,
    .get_system_av_info = retro_get_system_av_info,
    .set_controller_port_device = retro_set_controller_port_device,
    .reset = retro_reset,
    .run = retro_run,
    .serialize_size = retro_serialize_size,
    .serialize = retro_serialize,
    .unserialize = retro_unserialize,
    .cheat_reset = retro_cheat_reset,
    .cheat_set = retro_cheat_set,
    .load_game = retro_load_game,
    .unload_game = retro_unload_game,
    .get_region = retro_get_region,
    .get_memory_data = retro_get_memory_data,
    .get_memory_size = retro_get_memory_size,
};

__attribute__((visibility("default")))
const AtticLibretroAPI *ATTIC_ENTRY(void) {
    return &api;
}
