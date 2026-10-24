#include "SevenZip.h"

#include "7z.h"
#include "7zAlloc.h"
#include "7zCrc.h"
#include "7zFile.h"
#include "Lzma2Dec.h"
#include "LzmaDec.h"

#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define METHOD_COPY 0
#define METHOD_LZMA2 0x21
#define METHOD_LZMA 0x30101

#define INPUT_BUFFER_SIZE ((size_t)1 << 18)
#define OUTPUT_CHUNK_SIZE ((size_t)1 << 20)
#define IN_MEMORY_LIMIT ((UInt64)512 << 20)

struct AtticSevenZip {
    CFileInStream file;
    CLookToRead2 look;
    CSzArEx db;
    ISzAlloc alloc;
    ISzAlloc allocTemp;
    bool fileOpen;
    bool dbOpen;
};

static pthread_once_t crcOnce = PTHREAD_ONCE_INIT;

static void generateCrcTable(void) {
    CrcGenerateTable();
}

static int statusFromResult(SRes res) {
    switch (res) {
    case SZ_OK:
        return ATTIC_7Z_OK;
    case SZ_ERROR_MEM:
        return ATTIC_7Z_ERROR_MEMORY;
    case SZ_ERROR_UNSUPPORTED:
        return ATTIC_7Z_ERROR_UNSUPPORTED;
    case SZ_ERROR_CRC:
    case SZ_ERROR_DATA:
    case SZ_ERROR_INPUT_EOF:
        return ATTIC_7Z_ERROR_DATA;
    case SZ_ERROR_WRITE:
        return ATTIC_7Z_ERROR_WRITE;
    case SZ_ERROR_READ:
        return ATTIC_7Z_ERROR_OPEN;
    default:
        return ATTIC_7Z_ERROR_FORMAT;
    }
}

AtticSevenZip *attic_7z_open(const char *path, int *status) {
    pthread_once(&crcOnce, generateCrcTable);

    AtticSevenZip *archive = calloc(1, sizeof(*archive));
    if (!archive) {
        *status = ATTIC_7Z_ERROR_MEMORY;
        return NULL;
    }
    archive->alloc = (ISzAlloc){ SzAlloc, SzFree };
    archive->allocTemp = (ISzAlloc){ SzAllocTemp, SzFreeTemp };

    if (InFile_Open(&archive->file.file, path) != 0) {
        free(archive);
        *status = ATTIC_7Z_ERROR_OPEN;
        return NULL;
    }
    archive->fileOpen = true;
    FileInStream_CreateVTable(&archive->file);
    archive->file.wres = 0;

    LookToRead2_CreateVTable(&archive->look, False);
    archive->look.buf = ISzAlloc_Alloc(&archive->alloc, INPUT_BUFFER_SIZE);
    if (!archive->look.buf) {
        attic_7z_close(archive);
        *status = ATTIC_7Z_ERROR_MEMORY;
        return NULL;
    }
    archive->look.bufSize = INPUT_BUFFER_SIZE;
    archive->look.realStream = &archive->file.vt;
    LookToRead2_INIT(&archive->look)

    SzArEx_Init(&archive->db);
    SRes res = SzArEx_Open(&archive->db, &archive->look.vt, &archive->alloc, &archive->allocTemp);
    if (res != SZ_OK) {
        attic_7z_close(archive);
        *status = statusFromResult(res);
        return NULL;
    }
    archive->dbOpen = true;
    *status = ATTIC_7Z_OK;
    return archive;
}

void attic_7z_close(AtticSevenZip *archive) {
    if (!archive) {
        return;
    }
    if (archive->dbOpen) {
        SzArEx_Free(&archive->db, &archive->alloc);
    }
    if (archive->look.buf) {
        ISzAlloc_Free(&archive->alloc, archive->look.buf);
    }
    if (archive->fileOpen) {
        File_Close(&archive->file.file);
    }
    free(archive);
}

uint32_t attic_7z_count(const AtticSevenZip *archive) {
    return archive->db.NumFiles;
}

bool attic_7z_is_directory(const AtticSevenZip *archive, uint32_t index) {
    return SzArEx_IsDir(&archive->db, index);
}

uint64_t attic_7z_size(const AtticSevenZip *archive, uint32_t index) {
    return SzArEx_GetFileSize(&archive->db, index);
}

uint64_t attic_7z_total_size(const AtticSevenZip *archive) {
    uint64_t total = 0;
    for (uint32_t i = 0; i < archive->db.NumFiles; i++) {
        if (!SzArEx_IsDir(&archive->db, i)) {
            total += SzArEx_GetFileSize(&archive->db, i);
        }
    }
    return total;
}

static void appendUtf8(char *buffer, size_t capacity, size_t *length, uint32_t c) {
    char bytes[4];
    size_t count;
    if (c < 0x80) {
        bytes[0] = (char)c;
        count = 1;
    } else if (c < 0x800) {
        bytes[0] = (char)(0xC0 | (c >> 6));
        bytes[1] = (char)(0x80 | (c & 0x3F));
        count = 2;
    } else if (c < 0x10000) {
        bytes[0] = (char)(0xE0 | (c >> 12));
        bytes[1] = (char)(0x80 | ((c >> 6) & 0x3F));
        bytes[2] = (char)(0x80 | (c & 0x3F));
        count = 3;
    } else {
        bytes[0] = (char)(0xF0 | (c >> 18));
        bytes[1] = (char)(0x80 | ((c >> 12) & 0x3F));
        bytes[2] = (char)(0x80 | ((c >> 6) & 0x3F));
        bytes[3] = (char)(0x80 | (c & 0x3F));
        count = 4;
    }
    for (size_t i = 0; i < count; i++) {
        if (buffer && *length + 1 < capacity) {
            buffer[*length] = bytes[i];
        }
        (*length)++;
    }
}

size_t attic_7z_name(const AtticSevenZip *archive, uint32_t index, char *buffer, size_t capacity) {
    size_t units = SzArEx_GetFileNameUtf16(&archive->db, index, NULL);
    UInt16 *name = malloc(units * sizeof(UInt16) + sizeof(UInt16));
    if (!name) {
        if (buffer && capacity) {
            buffer[0] = '\0';
        }
        return 0;
    }
    SzArEx_GetFileNameUtf16(&archive->db, index, name);
    name[units] = 0;

    size_t length = 0;
    for (size_t i = 0; i < units && name[i]; i++) {
        uint32_t c = name[i];
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < units && name[i + 1] >= 0xDC00 && name[i + 1] <= 0xDFFF) {
            c = 0x10000 + ((c - 0xD800) << 10) + (name[i + 1] - 0xDC00);
            i++;
        }
        appendUtf8(buffer, capacity, &length, c);
    }
    if (buffer && capacity) {
        buffer[length < capacity ? length : capacity - 1] = '\0';
    }
    free(name);
    return length;
}

/// Builds `directory/relative` from an archive path, dropping empty, "." and ".."
/// components so nothing can be written outside `directory`.
static char *safeOutputPath(const AtticSevenZip *archive, uint32_t index, const char *directory) {
    size_t length = attic_7z_name(archive, index, NULL, 0);
    char *name = malloc(length + 1);
    if (!name) {
        return NULL;
    }
    attic_7z_name(archive, index, name, length + 1);

    size_t directoryLength = strlen(directory);
    char *path = malloc(directoryLength + length + 2);
    if (!path) {
        free(name);
        return NULL;
    }
    memcpy(path, directory, directoryLength);
    size_t position = directoryLength;

    char *cursor = name;
    while (*cursor) {
        char *end = cursor;
        while (*end && *end != '/' && *end != '\\') {
            end++;
        }
        size_t componentLength = (size_t)(end - cursor);
        bool skip = componentLength == 0
            || (componentLength == 1 && cursor[0] == '.')
            || (componentLength == 2 && cursor[0] == '.' && cursor[1] == '.');
        if (!skip) {
            path[position++] = '/';
            memcpy(path + position, cursor, componentLength);
            position += componentLength;
        }
        cursor = *end ? end + 1 : end;
    }
    path[position] = '\0';
    free(name);

    if (position == directoryLength) {
        free(path);
        return NULL;
    }
    return path;
}

static bool makeDirectories(char *path, bool includeLast) {
    size_t length = strlen(path);
    for (size_t i = 1; i <= length; i++) {
        if (path[i] == '/' || (includeLast && path[i] == '\0')) {
            char saved = path[i];
            path[i] = '\0';
            if (mkdir(path, 0755) != 0 && errno != EEXIST) {
                path[i] = saved;
                return false;
            }
            path[i] = saved;
        }
    }
    return true;
}

/// Writes the unpacked stream of one folder (solid block) to its files, in order.
typedef struct FolderWriter {
    const AtticSevenZip *archive;
    const char *directory;
    UInt32 folderIndex;
    UInt32 nextFile;
    UInt32 endFile;
    FILE *output;
    UInt32 currentFile;
    UInt64 remaining;
    UInt32 crc;
    uint64_t *written;
    uint64_t lastReported;
    attic_7z_progress progress;
    void *context;
} FolderWriter;

static int finishCurrentFile(FolderWriter *writer) {
    if (!writer->output) {
        return ATTIC_7Z_OK;
    }
    bool failed = fclose(writer->output) != 0;
    writer->output = NULL;
    if (failed) {
        return ATTIC_7Z_ERROR_WRITE;
    }
    const CSzArEx *db = &writer->archive->db;
    if (SzBitWithVals_Check(&db->CRCs, writer->currentFile)
        && CRC_GET_DIGEST(writer->crc) != db->CRCs.Vals[writer->currentFile]) {
        return ATTIC_7Z_ERROR_DATA;
    }
    return ATTIC_7Z_OK;
}

/// Opens the next file of the folder that has data. Files of size zero are created right away.
static int openNextFile(FolderWriter *writer) {
    const CSzArEx *db = &writer->archive->db;
    while (writer->nextFile < writer->endFile) {
        UInt32 index = writer->nextFile++;
        if (db->FileToFolder[index] != writer->folderIndex) {
            continue;
        }
        char *path = safeOutputPath(writer->archive, index, writer->directory);
        if (!path) {
            return ATTIC_7Z_ERROR_MEMORY;
        }
        if (!makeDirectories(path, false)) {
            free(path);
            return ATTIC_7Z_ERROR_WRITE;
        }
        FILE *output = fopen(path, "wb");
        free(path);
        if (!output) {
            return ATTIC_7Z_ERROR_WRITE;
        }
        writer->output = output;
        writer->currentFile = index;
        writer->remaining = SzArEx_GetFileSize(db, index);
        writer->crc = CRC_INIT_VAL;
        if (writer->remaining > 0) {
            return ATTIC_7Z_OK;
        }
        int status = finishCurrentFile(writer);
        if (status != ATTIC_7Z_OK) {
            return status;
        }
    }
    return ATTIC_7Z_OK;
}

static int writeData(FolderWriter *writer, const Byte *data, size_t size) {
    while (size > 0) {
        if (!writer->output) {
            int status = openNextFile(writer);
            if (status != ATTIC_7Z_OK) {
                return status;
            }
            if (!writer->output) {
                // More data than the files of this folder need.
                return ATTIC_7Z_ERROR_DATA;
            }
        }
        size_t chunk = size;
        if (chunk > writer->remaining) {
            chunk = (size_t)writer->remaining;
        }
        if (fwrite(data, 1, chunk, writer->output) != chunk) {
            return ATTIC_7Z_ERROR_WRITE;
        }
        writer->crc = CrcUpdate(writer->crc, data, chunk);
        writer->remaining -= chunk;
        *writer->written += chunk;
        data += chunk;
        size -= chunk;
        if (writer->remaining == 0) {
            int status = finishCurrentFile(writer);
            if (status != ATTIC_7Z_OK) {
                return status;
            }
        }
    }
    if (writer->progress && *writer->written - writer->lastReported >= OUTPUT_CHUNK_SIZE) {
        writer->lastReported = *writer->written;
        if (!writer->progress(writer->context, *writer->written)) {
            return ATTIC_7Z_ERROR_CANCELLED;
        }
    }
    return ATTIC_7Z_OK;
}

static UInt32 lzma2DictionarySize(Byte prop) {
    if (prop >= 40) {
        return 0xFFFFFFFF;
    }
    return ((UInt32)2 | (prop & 1)) << (prop / 2 + 11);
}

static SizeT dictionaryBufferSize(UInt32 dictionarySize, UInt64 unpackSize) {
    UInt64 size = dictionarySize;
    if (size > unpackSize) {
        size = unpackSize;
    }
    if (size < ((UInt64)1 << 12)) {
        size = (UInt64)1 << 12;
    }
    return (SizeT)size;
}

/// Streams one LZMA or LZMA2 coder from the archive into the folder writer.
static int decodeLzmaStream(AtticSevenZip *archive, const CSzCoderInfo *coder, const Byte *coderData,
                            UInt64 packSize, UInt64 unpackSize, FolderWriter *writer) {
    const Byte *props = coderData + coder->PropsOffset;
    bool isLzma2 = coder->MethodID == METHOD_LZMA2;
    CLzmaDec lzma;
    CLzma2Dec lzma2;
    Byte *dictionary = NULL;
    Byte *output = malloc(OUTPUT_CHUNK_SIZE);
    if (!output) {
        return ATTIC_7Z_ERROR_MEMORY;
    }

    SRes res;
    if (isLzma2) {
        if (coder->PropsSize != 1) {
            free(output);
            return ATTIC_7Z_ERROR_DATA;
        }
        Lzma2Dec_CONSTRUCT(&lzma2)
        res = Lzma2Dec_AllocateProbs(&lzma2, props[0], &archive->alloc);
        if (res == SZ_OK) {
            SizeT size = dictionaryBufferSize(lzma2DictionarySize(props[0]), unpackSize);
            dictionary = malloc(size);
            lzma2.decoder.dic = dictionary;
            lzma2.decoder.dicBufSize = size;
            Lzma2Dec_Init(&lzma2);
        }
    } else {
        LzmaDec_CONSTRUCT(&lzma)
        res = LzmaDec_AllocateProbs(&lzma, props, coder->PropsSize, &archive->alloc);
        if (res == SZ_OK) {
            SizeT size = dictionaryBufferSize(lzma.prop.dicSize, unpackSize);
            dictionary = malloc(size);
            lzma.dic = dictionary;
            lzma.dicBufSize = size;
            LzmaDec_Init(&lzma);
        }
    }
    if (res == SZ_OK && !dictionary) {
        res = SZ_ERROR_MEM;
    }

    int status = statusFromResult(res);
    while (status == ATTIC_7Z_OK && unpackSize > 0) {
        const void *input = NULL;
        size_t lookahead = INPUT_BUFFER_SIZE;
        if (lookahead > packSize) {
            lookahead = (size_t)packSize;
        }
        res = ILookInStream_Look(&archive->look.vt, &input, &lookahead);
        if (res != SZ_OK) {
            status = statusFromResult(res);
            break;
        }

        SizeT inProcessed = lookahead;
        SizeT outProcessed = OUTPUT_CHUNK_SIZE;
        ELzmaFinishMode finishMode = LZMA_FINISH_ANY;
        if (outProcessed >= unpackSize) {
            outProcessed = (SizeT)unpackSize;
            finishMode = LZMA_FINISH_END;
        }
        ELzmaStatus lzmaStatus;
        if (isLzma2) {
            res = Lzma2Dec_DecodeToBuf(&lzma2, output, &outProcessed, input, &inProcessed, finishMode, &lzmaStatus);
        } else {
            res = LzmaDec_DecodeToBuf(&lzma, output, &outProcessed, input, &inProcessed, finishMode, &lzmaStatus);
        }
        packSize -= inProcessed;
        unpackSize -= outProcessed;
        SRes skip = ILookInStream_Skip(&archive->look.vt, inProcessed);

        if (outProcessed > 0) {
            status = writeData(writer, output, outProcessed);
        }
        if (status != ATTIC_7Z_OK) {
            break;
        }
        if (res != SZ_OK || skip != SZ_OK) {
            status = statusFromResult(res != SZ_OK ? res : skip);
            break;
        }
        if (unpackSize > 0 && inProcessed == 0 && outProcessed == 0) {
            status = ATTIC_7Z_ERROR_DATA;
        }
    }

    if (isLzma2) {
        Lzma2Dec_FreeProbs(&lzma2, &archive->alloc);
    } else {
        LzmaDec_FreeProbs(&lzma, &archive->alloc);
    }
    free(dictionary);
    free(output);
    return status;
}

static int copyStream(AtticSevenZip *archive, UInt64 size, FolderWriter *writer) {
    while (size > 0) {
        const void *input = NULL;
        size_t chunk = INPUT_BUFFER_SIZE;
        if (chunk > size) {
            chunk = (size_t)size;
        }
        SRes res = ILookInStream_Look(&archive->look.vt, &input, &chunk);
        if (res != SZ_OK) {
            return statusFromResult(res);
        }
        if (chunk == 0) {
            return ATTIC_7Z_ERROR_DATA;
        }
        int status = writeData(writer, input, chunk);
        if (status != ATTIC_7Z_OK) {
            return status;
        }
        size -= chunk;
        res = ILookInStream_Skip(&archive->look.vt, chunk);
        if (res != SZ_OK) {
            return statusFromResult(res);
        }
    }
    return ATTIC_7Z_OK;
}

static int extractFolder(AtticSevenZip *archive, UInt32 folderIndex, const char *directory, uint64_t *written,
                         attic_7z_progress progress, void *context) {
    const CSzArEx *db = &archive->db;
    const CSzAr *ar = &db->db;

    FolderWriter writer = {
        .archive = archive,
        .directory = directory,
        .folderIndex = folderIndex,
        .nextFile = db->FolderToFile[folderIndex],
        .endFile = db->FolderToFile[folderIndex + 1],
        .written = written,
        .lastReported = *written,
        .progress = progress,
        .context = context,
    };
    if (writer.endFile > db->NumFiles || writer.endFile < writer.nextFile) {
        writer.endFile = db->NumFiles;
    }

    const Byte *coderData = ar->CodersData + ar->FoCodersOffsets[folderIndex];
    CSzData sd = { coderData, ar->FoCodersOffsets[folderIndex + 1] - ar->FoCodersOffsets[folderIndex] };
    CSzFolder folder;
    if (SzGetNextFolderItem(&folder, &sd) != SZ_OK) {
        return ATTIC_7Z_ERROR_FORMAT;
    }
    UInt64 unpackSize = SzAr_GetFolderUnpackSize(ar, folderIndex);

    int status;
    const CSzCoderInfo *coder = &folder.Coders[0];
    bool streamable = folder.NumCoders == 1 && folder.NumPackStreams == 1
        && (coder->MethodID == METHOD_COPY || coder->MethodID == METHOD_LZMA || coder->MethodID == METHOD_LZMA2);

    if (streamable) {
        UInt32 packIndex = ar->FoStartPackStreamIndex[folderIndex];
        UInt64 packStart = db->dataPos + ar->PackPositions[packIndex];
        UInt64 packSize = ar->PackPositions[packIndex + 1] - ar->PackPositions[packIndex];
        SRes res = LookInStream_SeekTo(&archive->look.vt, packStart);
        if (res != SZ_OK) {
            return statusFromResult(res);
        }
        if (coder->MethodID == METHOD_COPY) {
            status = copyStream(archive, packSize < unpackSize ? packSize : unpackSize, &writer);
        } else {
            status = decodeLzmaStream(archive, coder, coderData, packSize, unpackSize, &writer);
        }
    } else {
        if (unpackSize > IN_MEMORY_LIMIT) {
            return ATTIC_7Z_ERROR_UNSUPPORTED;
        }
        Byte *buffer = malloc(unpackSize ? (size_t)unpackSize : 1);
        if (!buffer) {
            return ATTIC_7Z_ERROR_MEMORY;
        }
        SRes res = SzAr_DecodeFolder(ar, folderIndex, &archive->look.vt, db->dataPos, buffer, (size_t)unpackSize,
                                     &archive->alloc);
        status = statusFromResult(res);
        if (status == ATTIC_7Z_OK) {
            status = writeData(&writer, buffer, (size_t)unpackSize);
        }
        free(buffer);
    }

    if (status == ATTIC_7Z_OK && writer.output) {
        // The stream ended before the last file was complete.
        status = ATTIC_7Z_ERROR_DATA;
    }
    if (writer.output) {
        fclose(writer.output);
        writer.output = NULL;
    }
    if (status == ATTIC_7Z_OK) {
        // Create any zero-length files that come after the last data.
        status = openNextFile(&writer);
        if (writer.output) {
            fclose(writer.output);
            status = ATTIC_7Z_ERROR_DATA;
        }
    }
    return status;
}

int attic_7z_extract_all(AtticSevenZip *archive, const char *directory,
                         attic_7z_progress progress, void *context) {
    const CSzArEx *db = &archive->db;

    for (UInt32 i = 0; i < db->NumFiles; i++) {
        bool isDirectory = SzArEx_IsDir(db, i);
        if (!isDirectory && db->FileToFolder[i] != (UInt32)-1) {
            continue;
        }
        char *path = safeOutputPath(archive, i, directory);
        if (!path) {
            continue;
        }
        bool ok = makeDirectories(path, isDirectory);
        if (ok && !isDirectory) {
            FILE *empty = fopen(path, "wb");
            ok = empty && fclose(empty) == 0;
        }
        free(path);
        if (!ok) {
            return ATTIC_7Z_ERROR_WRITE;
        }
    }

    uint64_t written = 0;
    for (UInt32 folderIndex = 0; folderIndex < db->db.NumFolders; folderIndex++) {
        int status = extractFolder(archive, folderIndex, directory, &written, progress, context);
        if (status != ATTIC_7Z_OK) {
            return status;
        }
    }
    if (progress && !progress(context, written)) {
        return ATTIC_7Z_ERROR_CANCELLED;
    }
    return ATTIC_7Z_OK;
}

uint32_t attic_crc32(uint32_t crc, const void *data, size_t size) {
    pthread_once(&crcOnce, generateCrcTable);
    return CRC_GET_DIGEST(CrcUpdate(crc ^ CRC_INIT_VAL, data, size));
}
