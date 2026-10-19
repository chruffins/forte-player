/* Native rendering bridge: owns scene GPU resources, not audio, input or HUD. */
#include "bridge.h"
#include "camera.h"
#include "skybox.h"

#include <allegro5/allegro.h>
#include <allegro5/allegro_opengl.h>
#include <allegro5/allegro_primitives.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#define FIREFLY_COUNT 288
#define VOCAL_FIREFLY_PERIOD 6
#define FFT_BAND_COUNT 48
#define SKY_INTENSITY 0.035f
#define WORLD_TIME_PERIOD 628.3185307179586
#define FLOOR_EXTENT 80.0f
#define FIREFLY_EXTENT_X 18.0f
#define FIREFLY_EXTENT_Y 4.8f
#define FIREFLY_EXTENT_Z 20.0f
#define FIREFLY_MIN_HEIGHT 0.65f

struct ForteWorld {
    Camera camera;
    Skybox sky;
    ALLEGRO_SHADER *floor_shader;
    ALLEGRO_SHADER *fly_shader;
    ALLEGRO_VERTEX_BUFFER *floor_buffer;
    ALLEGRO_VERTEX_BUFFER *fly_buffer;
    bool point_lights;
};

typedef struct SavedRenderState {
    ALLEGRO_STATE allegro;
    ALLEGRO_SHADER *shader;
    int depth_test;
    int depth_function;
    int write_mask;
    int alpha_test;
} SavedRenderState;

static ALLEGRO_SHADER *load_shader(const char *vertex, const char *pixel)
{
    ALLEGRO_SHADER *shader = al_create_shader(ALLEGRO_SHADER_GLSL);
    if (!shader)
        return NULL;

    const bool valid_sources = vertex && pixel &&
        al_attach_shader_source_file(shader, ALLEGRO_VERTEX_SHADER, vertex) &&
        al_attach_shader_source_file(shader, ALLEGRO_PIXEL_SHADER, pixel);
    if (!valid_sources || !al_build_shader(shader)) {
        fprintf(stderr, "[world] Shader failed: %s\n", al_get_shader_log(shader));
        al_destroy_shader(shader);
        return NULL;
    }
    return shader;
}

static float noise(unsigned int value)
{
    value ^= value >> 16;
    value *= 0x7feb352du;
    value ^= value >> 15;
    value *= 0x846ca68bu;
    value ^= value >> 16;
    return (value & 0x00ffffffu) / 16777215.0f;
}

static void create_floor_buffer(ForteWorld *world)
{
    const float e = FLOOR_EXTENT;
    const ALLEGRO_VERTEX vertices[6] = {
        {.x=-e, .y=0, .z=-e}, {.x=e, .y=0, .z=-e}, {.x=e, .y=0, .z=e},
        {.x=-e, .y=0, .z=-e}, {.x=e, .y=0, .z=e}, {.x=-e, .y=0, .z=e},
    };
    world->floor_buffer = al_create_vertex_buffer(NULL, vertices, 6, ALLEGRO_PRIM_BUFFER_STATIC);
}

static void create_firefly_buffer(ForteWorld *world)
{
    const float corners[6][2] = {
        {-1, -1}, {1, -1}, {1, 1}, {-1, -1}, {1, 1}, {-1, 1},
    };
    ALLEGRO_VERTEX vertices[FIREFLY_COUNT * 6];

    for (unsigned int i = 0; i < FIREFLY_COUNT; ++i) {
        const float x = (noise(i * 5 + 1) * 2 - 1) * FIREFLY_EXTENT_X;
        const float y = FIREFLY_MIN_HEIGHT + noise(i * 5 + 2) * FIREFLY_EXTENT_Y;
        const float z = (noise(i * 5 + 3) * 2 - 1) * FIREFLY_EXTENT_Z;
        const ALLEGRO_COLOR seed = {
            (i % FFT_BAND_COUNT) / (float)(FFT_BAND_COUNT - 1),
            noise(i * 5 + 4), noise(i * 5 + 5), (i % VOCAL_FIREFLY_PERIOD == 0) ? 1 : 0,
        };

        for (int corner = 0; corner < 6; ++corner) {
            vertices[i * 6 + corner] = (ALLEGRO_VERTEX){
                .x=x, .y=y, .z=z,
                .u=corners[corner][0], .v=corners[corner][1], .color=seed,
            };
        }
    }
    world->fly_buffer = al_create_vertex_buffer(NULL, vertices, FIREFLY_COUNT * 6, ALLEGRO_PRIM_BUFFER_STATIC);
}

static void load_skybox(ForteWorld *world, const char *const faces[6])
{
    if (!skybox_init(&world->sky)) {
        fprintf(stderr, "[world] Sky shader unavailable; dark background retained.\n");
        return;
    }
    world->sky.intensity = SKY_INTENSITY;
    if (!skybox_load_faces(&world->sky, faces))
        fprintf(stderr, "[world] Sky unavailable; dark background retained.\n");
}

ForteWorld *forte_world_create(const char *const faces[6], const char *const files[4])
{
    ALLEGRO_DISPLAY *display = al_get_current_display();
    if (!display || !(al_get_display_flags(display) & ALLEGRO_OPENGL) || !files)
        return NULL;

    ALLEGRO_SHADER *previous_shader = al_get_current_shader();
    ForteWorld *world = calloc(1, sizeof(*world));
    if (!world)
        return NULL;

    camera_init(&world->camera);
    world->camera.distance = 0; /* Eye-level walk; retain template projection/rotation. */
    world->point_lights = true;
    world->floor_shader = load_shader(files[0], files[1]);
    world->fly_shader = load_shader(files[2], files[3]);
    if (!world->floor_shader || !world->fly_shader)
        goto failed;

    create_floor_buffer(world);
    create_firefly_buffer(world);
    if (!world->floor_buffer || !world->fly_buffer)
        goto failed;

    load_skybox(world, faces);
    al_use_shader(previous_shader);
    return world;

failed:
    forte_world_destroy(world);
    al_use_shader(previous_shader);
    return NULL;
}

void forte_world_destroy(ForteWorld *world)
{
    if (!world)
        return;
    al_use_shader(NULL);
    if (world->floor_buffer)
        al_destroy_vertex_buffer(world->floor_buffer);
    if (world->fly_buffer)
        al_destroy_vertex_buffer(world->fly_buffer);
    if (world->floor_shader)
        al_destroy_shader(world->floor_shader);
    if (world->fly_shader)
        al_destroy_shader(world->fly_shader);
    skybox_destroy(&world->sky);
    free(world);
}

static SavedRenderState save_render_state(void)
{
    SavedRenderState state = {0};
    al_store_state(&state.allegro,
        ALLEGRO_STATE_TRANSFORM | ALLEGRO_STATE_PROJECTION_TRANSFORM | ALLEGRO_STATE_BLENDER);
    state.shader = al_get_current_shader();
    state.depth_test = al_get_render_state(ALLEGRO_DEPTH_TEST);
    state.depth_function = al_get_render_state(ALLEGRO_DEPTH_FUNCTION);
    state.write_mask = al_get_render_state(ALLEGRO_WRITE_MASK);
    state.alpha_test = al_get_render_state(ALLEGRO_ALPHA_TEST);
    glPushAttrib(GL_ENABLE_BIT | GL_DEPTH_BUFFER_BIT | GL_COLOR_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
    return state;
}

static void restore_render_state(const SavedRenderState *state)
{
    al_use_shader(state->shader);
    al_restore_state(&state->allegro);
    al_set_render_state(ALLEGRO_DEPTH_TEST, state->depth_test);
    al_set_render_state(ALLEGRO_DEPTH_FUNCTION, state->depth_function);
    al_set_render_state(ALLEGRO_WRITE_MASK, state->write_mask);
    al_set_render_state(ALLEGRO_ALPHA_TEST, state->alpha_test);
    glPopAttrib();
}

static void sanitize_bands(const float input[FFT_BAND_COUNT], float output[FFT_BAND_COUNT])
{
    for (int i = 0; i < FFT_BAND_COUNT; ++i)
        output[i] = isfinite(input[i]) ? fminf(1, fmaxf(0, input[i])) : 0;
}

static bool draw_floor(ForteWorld *world, const float eye[3], float aspect)
{
    bool ok = al_use_shader(world->floor_shader);
    al_set_render_state(ALLEGRO_DEPTH_TEST, true);
    al_set_render_state(ALLEGRO_DEPTH_FUNCTION, ALLEGRO_RENDER_LESS_EQUAL);
    al_set_blender(ALLEGRO_ADD, ALLEGRO_ONE, ALLEGRO_ZERO);
    ok = al_set_shader_float_vector("u_eye", 3, eye, 1) && ok;
    al_draw_vertex_buffer(world->floor_buffer, NULL, 0, 6, ALLEGRO_PRIM_TRIANGLE_LIST);
    skybox_draw(&world->sky, &world->camera, aspect, false);
    return ok;
}

static bool setup_fireflies(ForteWorld *world, const float bands[FFT_BAND_COUNT],
    const float eye[3], float yaw, float pitch, float vocal, float seconds)
{
    const float cp = cosf(pitch), sp = sinf(pitch), cy = cosf(yaw), sy = sinf(yaw);
    const float right[3] = {cy, 0, sy};
    const float up[3] = {-sp * sy, cp, sp * cy};
    bool ok = al_use_shader(world->fly_shader);

    al_set_render_state(ALLEGRO_DEPTH_TEST, true);
    al_set_render_state(ALLEGRO_DEPTH_FUNCTION, ALLEGRO_RENDER_LESS_EQUAL);
    /* Light footprints are additive overlays: never modify floor depth. */
    al_set_render_state(ALLEGRO_WRITE_MASK, ALLEGRO_MASK_RGBA);
    al_set_blender(ALLEGRO_ADD, ALLEGRO_ONE, ALLEGRO_ONE);
    ok = al_set_shader_float_vector("u_bands", 4, bands, FFT_BAND_COUNT / 4) && ok;
    ok = al_set_shader_float_vector("u_eye", 3, eye, 1) && ok;
    ok = al_set_shader_float_vector("u_right", 3, right, 1) && ok;
    ok = al_set_shader_float_vector("u_up", 3, up, 1) && ok;
    ok = al_set_shader_float("u_time", seconds) && ok;
    ok = al_set_shader_float("u_vocal", vocal) && ok;
    return ok;
}

static bool draw_firefly_pass(ForteWorld *world, bool ground_pass)
{
    const bool ok = al_set_shader_bool("u_ground_pass", ground_pass);
    al_draw_vertex_buffer(world->fly_buffer, NULL, 0, FIREFLY_COUNT * 6, ALLEGRO_PRIM_TRIANGLE_LIST);
    return ok;
}

bool forte_world_draw(ForteWorld *world, float x, float y, float z, float yaw, float pitch,
    const float bands[FFT_BAND_COUNT], float vocal, double seconds, int width, int height)
{
    if (!world || !bands || width <= 0 || height <= 0 || !isfinite(seconds) ||
        !isfinite(x) || !isfinite(y) || !isfinite(z) || !isfinite(yaw) || !isfinite(pitch) || !isfinite(vocal))
        return false;

    float values[FFT_BAND_COUNT];
    sanitize_bands(bands, values);
    const float eye[3] = {x, y, z};
    const float aspect = (float)width / height;
    const float phase = (float)fmod(seconds, WORLD_TIME_PERIOD);
    const float voice_level = fminf(1, fmaxf(0, vocal));
    SavedRenderState state = save_render_state();

    world->camera.yaw = yaw;
    world->camera.pitch = pitch;
    ALLEGRO_TRANSFORM projection, view;
    camera_build_projection(aspect, false, &projection);
    camera_build_view(&world->camera, (TemplateVec3){x, y, z}, &view);
    al_use_projection_transform(&projection);
    al_use_transform(&view);

    glDisable(GL_CULL_FACE);
    glDisable(GL_STENCIL_TEST);
    glDisable(GL_ALPHA_TEST);
    al_set_render_state(ALLEGRO_ALPHA_TEST, false);
    al_set_render_state(ALLEGRO_WRITE_MASK, ALLEGRO_MASK_RGBA | ALLEGRO_MASK_DEPTH);
    al_clear_depth_buffer(1);

    bool ok = draw_floor(world, eye, aspect);
    ok = setup_fireflies(world, values, eye, yaw, pitch, voice_level, phase) && ok;
    if (world->point_lights)
        ok = draw_firefly_pass(world, true) && ok;
    ok = draw_firefly_pass(world, false) && ok;
    restore_render_state(&state);
    return ok;
}

void forte_world_set_point_lights(ForteWorld *world, bool enabled)
{
    if (world)
        world->point_lights = enabled;
}

bool forte_world_has_sky(const ForteWorld *world)
{
    return world && world->sky.texture != 0;
}

unsigned int forte_world_gl_error(void)
{
    return glGetError();
}
