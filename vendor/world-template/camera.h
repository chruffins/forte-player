#ifndef CAMERA_H
#define CAMERA_H

/* Physics-free adapter: the upstream camera only needs a three-float
   position, not the Box3D runtime or its public headers. */
typedef struct TemplateVec3 { float x, y, z; } TemplateVec3;

#include <stdbool.h>
#include <allegro5/allegro.h>

#define CAMERA_FOV_Y_DEGREES 60.0
#define CAMERA_NEAR_PLANE 0.1f
#define CAMERA_FAR_PLANE 150.0f

typedef struct Camera {
    float yaw;
    float pitch;
    float distance;
    float sensitivity;
} Camera;

void camera_init(Camera *camera);
void camera_look(Camera *camera, int mouse_dx, int mouse_dy);
void camera_turn(Camera *camera, float yaw_delta, float pitch_delta);
/* Pure transform builders; useful without a display. Infinite projection keeps
   homogeneous w=0 stencil endpoints from being clipped by a finite far plane. */
void camera_build_view(const Camera *camera, TemplateVec3 target, ALLEGRO_TRANSFORM *view);
/* Aspect must be finite and positive. */
void camera_build_projection(float aspect, bool infinite, ALLEGRO_TRANSFORM *projection);
float camera_tan_half_fov(void);
void camera_apply(const Camera *camera, TemplateVec3 target);
float camera_yaw(const Camera *camera);

#endif
