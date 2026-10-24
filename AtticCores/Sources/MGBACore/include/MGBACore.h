#ifndef ATTIC_MGBA_CORE_H
#define ATTIC_MGBA_CORE_H

#include <AtticLibretro.h>

#ifdef __cplusplus
extern "C" {
#endif

/// mGBA (Game Boy, Game Boy Color and Game Boy Advance) as a libretro core.
const AtticLibretroAPI *attic_mgba_core(void);

#ifdef __cplusplus
}
#endif

#endif
