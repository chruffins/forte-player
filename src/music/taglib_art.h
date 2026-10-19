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

// Extract the ALBUMARTIST property. The returned UTF-8 string is malloc'd and
// must be released with forte_free_string().
char *forte_extract_album_artist(const char *path);
unsigned int forte_extract_disc_number(const char *path);
// ReplayGain values in dB / linear amplitude; each presence flag is set only
// when the corresponding standard tag parses to a finite value.
int forte_extract_replaygain(const char *path, double *track_gain, int *has_track_gain,
                             double *track_peak, int *has_track_peak,
                             double *album_gain, int *has_album_gain,
                             double *album_peak, int *has_album_peak);
void forte_free_string(char *value);

// Write common audio tags in-place. Empty strings clear the corresponding tag.
// Returns 1 on success, 0 on failure; when provided, `error` receives a short
// human-readable diagnostic (including the terminating NUL).
int forte_write_metadata(const char *path,
                         const char *title, const char *artist,
                         const char *album, const char *genre,
                         const char *comment, unsigned int year,
                         unsigned int track, unsigned int disc,
                         char *error, size_t error_size);

#ifdef __cplusplus
}
#endif
