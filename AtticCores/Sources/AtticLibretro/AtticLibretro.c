#include "AtticLibretro.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static attic_libretro_log_sink logSink;

void attic_libretro_set_log_sink(attic_libretro_log_sink sink) {
    logSink = sink;
}

void attic_libretro_log(enum retro_log_level level, const char *fmt, ...) {
    if (!logSink) {
        return;
    }
    char message[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(message, sizeof(message), fmt, args);
    va_end(args);

    size_t length = strlen(message);
    while (length > 0 && (message[length - 1] == '\n' || message[length - 1] == '\r')) {
        message[--length] = '\0';
    }
    logSink(level, message);
}

bool attic_libretro_fill_log_interface(void *data) {
    if (!data) {
        return false;
    }
    ((struct retro_log_callback *)data)->log = attic_libretro_log;
    return true;
}
