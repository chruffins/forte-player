#ifndef SKYBOX_H
#define SKYBOX_H
#include "camera.h"
#include <allegro5/allegro.h>
#include <stdbool.h>

/* OpenGL cube target order, not the order used by every asset exporter. */
typedef enum SkyboxFace {
    SKYBOX_RIGHT = 0, /* +X */
    SKYBOX_LEFT,      /* -X */
    SKYBOX_UP,        /* +Y */
    SKYBOX_DOWN,      /* -Y */
    SKYBOX_BACK,      /* +Z */
    SKYBOX_FRONT,     /* -Z: camera yaw zero */
    SKYBOX_FACE_COUNT
} SkyboxFace;

typedef struct Skybox {
    ALLEGRO_SHADER *shader;
    unsigned int texture;
    bool seamless;
    float intensity, yaw;
} Skybox;

bool skybox_init(Skybox *skybox);
/* Six equally-sized square sRGB PNG/etc files in OpenGL cubemap orientation.
   Top image row is t=0. Failed replacement keeps the previous texture. */
bool skybox_load_faces(Skybox *skybox, const char *const paths[SKYBOX_FACE_COUNT]);
/* Draw after opaque/light passes, before HDR presentation. Rotation only,
   depth=1, no depth writes. linear_output=true when drawing into an HDR target. */
void skybox_draw(const Skybox *skybox, const Camera *camera, float aspect, bool linear_output);
void skybox_destroy(Skybox *skybox);
#endif
