#ifndef FORTE_WORLD_BRIDGE_H
#define FORTE_WORLD_BRIDGE_H
#include <stdbool.h>
typedef struct ForteWorld ForteWorld;
/* Current compatibility OpenGL display required. Ownership is local to it. */
ForteWorld *forte_world_create(const char *const sky_faces[6], const char *const shader_files[4]);
void forte_world_destroy(ForteWorld *world);
bool forte_world_draw(ForteWorld *world, float x, float y, float z,
                      float yaw, float pitch, const float bands[48], float vocal,
                      double seconds, int width, int height);
/* Lighting switch also permits independent GPU verification of illumination. */
void forte_world_set_point_lights(ForteWorld *world, bool enabled);
bool forte_world_has_sky(const ForteWorld *world);
unsigned int forte_world_gl_error(void);
#endif
