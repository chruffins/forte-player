#pragma once
// C shim over TagLib's C++ API for extracting embedded album art.
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Extract embedded cover art (or a folder cover fallback) for an audio file.
// Returns 1 on success and fills *out_data (malloc'd bytes), *out_size and
// *out_mime (malloc'd C string). The caller must free both with
// forte_free_cover().
int forte_extract_cover(const char *path,
                        unsigned char **out_data, size_t *out_size,
                        char **out_mime);

void forte_free_cover(unsigned char *data, char *mime);

#ifdef __cplusplus
}
#endif
