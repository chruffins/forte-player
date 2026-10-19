#include "camera.h"

#include <math.h>

#define PI 3.14159265358979323846f
#define PITCH_LIMIT (PI * 0.42f)

void camera_init(Camera *camera)
{
    camera->yaw = 0.0f;
    camera->pitch = 0.18f;
    camera->distance = 7.0f;
    camera->sensitivity = 0.004f;
}

void camera_turn(Camera *camera, float yaw_delta, float pitch_delta)
{
    camera->yaw += yaw_delta;
    camera->pitch += pitch_delta;
    if (camera->pitch > PITCH_LIMIT) camera->pitch = PITCH_LIMIT;
    if (camera->pitch < -PITCH_LIMIT) camera->pitch = -PITCH_LIMIT;
}

void camera_look(Camera *camera, int mouse_dx, int mouse_dy)
{
    camera_turn(camera, (float)mouse_dx * camera->sensitivity,
                (float)-mouse_dy * camera->sensitivity);
}

void camera_build_view(const Camera *camera, TemplateVec3 target, ALLEGRO_TRANSFORM *view)
{
    const float cp = cosf(camera->pitch);
    const float sp = sinf(camera->pitch);
    const float sy = sinf(camera->yaw);
    const float cy = cosf(camera->yaw);
    const float distance = camera->distance;
    const float camera_x = target.x - cp * sy * distance;
    const float camera_y = target.y - sp * distance;
    const float camera_z = target.z + cp * cy * distance;

    /* Allegro composes onto the left, so translate then yaw then pitch gives
       the same Rx(-pitch) * Ry(yaw) * T(-eye) convention as the old GL view. */
    al_identity_transform(view);
    al_translate_transform_3d(view, -camera_x, -camera_y, -camera_z);
    al_rotate_transform_3d(view, 0, 1, 0, camera->yaw);
    al_rotate_transform_3d(view, 1, 0, 0, -camera->pitch);
}

float camera_tan_half_fov(void)
{
    return (float)tan(CAMERA_FOV_Y_DEGREES * 3.14159265358979323846 / 360.0);
}

void camera_build_projection(float aspect, bool infinite, ALLEGRO_TRANSFORM *projection)
{
    al_identity_transform(projection);
    if (infinite) {
        float f = 1.0f / camera_tan_half_fov();
        projection->m[0][0] = f / aspect;
        projection->m[1][1] = f;
        projection->m[2][2] = -1;
        projection->m[2][3] = -1;
        projection->m[3][2] = -2 * CAMERA_NEAR_PLANE;
        projection->m[3][3] = 0;
    } else {
        float top = CAMERA_NEAR_PLANE * camera_tan_half_fov();
        al_perspective_transform(projection, -top * aspect, top, CAMERA_NEAR_PLANE,
                                 top * aspect, -top, CAMERA_FAR_PLANE);
    }
}

void camera_apply(const Camera *camera, TemplateVec3 target)
{
    ALLEGRO_TRANSFORM view;
    camera_build_view(camera, target, &view);
    al_use_transform(&view);
}

float camera_yaw(const Camera *camera)
{
    return camera->yaw;
}
