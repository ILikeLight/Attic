#ifndef ATTIC_SEVEN_ZIP_H
#define ATTIC_SEVEN_ZIP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Result codes of the 7z functions.
typedef enum AtticSevenZipStatus {
    ATTIC_7Z_OK = 0,
    ATTIC_7Z_ERROR_OPEN = 1,
    ATTIC_7Z_ERROR_FORMAT = 2,
    ATTIC_7Z_ERROR_UNSUPPORTED = 3,
    ATTIC_7Z_ERROR_DATA = 4,
    ATTIC_7Z_ERROR_MEMORY = 5,
    ATTIC_7Z_ERROR_WRITE = 6,
    ATTIC_7Z_ERROR_CANCELLED = 7,
} AtticSevenZipStatus;

typedef struct AtticSevenZip AtticSevenZip;

/// Opens a .7z archive and reads its file list. Returns NULL and sets `status` on failure.
AtticSevenZip *attic_7z_open(const char *path, int *status);
void attic_7z_close(AtticSevenZip *archive);

uint32_t attic_7z_count(const AtticSevenZip *archive);
bool attic_7z_is_directory(const AtticSevenZip *archive, uint32_t index);
uint64_t attic_7z_size(const AtticSevenZip *archive, uint32_t index);
/// Sum of the unpacked sizes of all files.
uint64_t attic_7z_total_size(const AtticSevenZip *archive);

/// Copies the UTF-8 path of an entry into `buffer` and returns its full length.
size_t attic_7z_name(const AtticSevenZip *archive, uint32_t index, char *buffer, size_t capacity);

/// Called during extraction with the number of bytes written so far. Return false to cancel.
typedef bool (*attic_7z_progress)(void *context, uint64_t written);

/// Extracts every file into `directory`, keeping the relative paths from the archive.
///
/// LZMA, LZMA2 and stored blocks are decoded in a stream, so large files never need
/// to fit in memory. Other methods (BCJ filters, PPMd) are decoded in memory up to 512 MB.
int attic_7z_extract_all(AtticSevenZip *archive, const char *directory,
                         attic_7z_progress progress, void *context);

/// Standard CRC-32 (zip, 7z, No-Intro). Pass 0 for the first block and the
/// previous result for the next ones.
uint32_t attic_crc32(uint32_t crc, const void *data, size_t size);

#ifdef __cplusplus
}
#endif

#endif
