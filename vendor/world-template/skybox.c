#include "skybox.h"
#include <allegro5/allegro_image.h>
#include <allegro5/allegro_opengl.h>
#include <allegro5/allegro_primitives.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef GL_TEXTURE_CUBE_MAP
#define GL_TEXTURE_CUBE_MAP 0x8513
#define GL_TEXTURE_BINDING_CUBE_MAP 0x8514
#define GL_TEXTURE_CUBE_MAP_POSITIVE_X 0x8515
#define GL_MAX_CUBE_MAP_TEXTURE_SIZE 0x851C
#define GL_TEXTURE_WRAP_R 0x8072
#endif
#ifndef GL_CLAMP_TO_EDGE
#define GL_CLAMP_TO_EDGE 0x812F
#endif
#ifndef GL_SRGB8_ALPHA8
#define GL_SRGB8_ALPHA8 0x8C43
#endif
#ifndef GL_TEXTURE0
#define GL_TEXTURE0 0x84C0
#define GL_ACTIVE_TEXTURE 0x84E0
#endif
#ifndef GL_CURRENT_PROGRAM
#define GL_CURRENT_PROGRAM 0x8B8D
#endif
#ifndef GL_TEXTURE_CUBE_MAP_SEAMLESS
#define GL_TEXTURE_CUBE_MAP_SEAMLESS 0x884F
#endif
#ifndef APIENTRY
#define APIENTRY
#endif
typedef void (APIENTRY *ActiveTextureFn)(GLenum);
static ActiveTextureFn active_texture;
typedef void (APIENTRY *UseProgramFn)(GLuint);
static UseProgramFn use_program;

static const char *vertex_source =
    "#version 120\n"
    "attribute vec3 al_pos;\n"
    "uniform vec3 u_right, u_up, u_forward; uniform float u_aspect, u_tan_half_fov;\n"
    "varying vec3 direction;\n"
    "void main() {\n"
    "  direction = u_forward + u_tan_half_fov * (al_pos.x * u_aspect * u_right + al_pos.y * u_up);\n"
    "  gl_Position = vec4(al_pos.xy, 1.0, 1.0);\n"
    "}\n";
static const char *fragment_source =
    "#version 120\n"
    "uniform samplerCube u_sky; uniform float u_intensity; uniform int u_linear_output;\n"
    "varying vec3 direction;\n"
    "vec3 to_srgb(vec3 c) {\n"
    "  return mix(12.92 * c, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));\n"
    "}\n"
    "void main() {\n"
    "  vec3 radiance = textureCube(u_sky, direction).rgb * u_intensity;\n"
    "  gl_FragColor = vec4(u_linear_output != 0 ? radiance : to_srgb(radiance), 1.0);\n"
    "}\n";

bool skybox_init(Skybox *skybox)
{
    memset(skybox,0,sizeof(*skybox));
    skybox->intensity = 1;
    void *address = al_get_opengl_proc_address("glActiveTexture");
    if (!address) return false;
    _Static_assert(sizeof(active_texture)==sizeof(address),"GL pointer size mismatch");
    memcpy(&active_texture,&address,sizeof(address));
    address = al_get_opengl_proc_address("glUseProgram");
    if (!address) return false;
    _Static_assert(sizeof(use_program)==sizeof(address),"GL pointer size mismatch");
    memcpy(&use_program,&address,sizeof(address));
    skybox->seamless = al_have_opengl_extension("GL_ARB_seamless_cube_map");
    skybox->shader = al_create_shader(ALLEGRO_SHADER_GLSL);
    if (!skybox->shader) return false;
    if (!al_attach_shader_source(skybox->shader,ALLEGRO_VERTEX_SHADER,vertex_source) ||
        !al_attach_shader_source(skybox->shader,ALLEGRO_PIXEL_SHADER,fragment_source) ||
        !al_build_shader(skybox->shader)) {
        fprintf(stderr,"Skybox shader failed: %s\n",al_get_shader_log(skybox->shader));
        skybox_destroy(skybox); return false;
    }
    return true;
}

bool skybox_load_faces(Skybox *skybox, const char *const paths[SKYBOX_FACE_COUNT])
{
    if (!skybox->shader || !paths || !al_init_image_addon()) return false;
    GLint max_size=0;
    glGetIntegerv(GL_MAX_CUBE_MAP_TEXTURE_SIZE,&max_size);
    if (max_size<=0) return false;
    ALLEGRO_BITMAP *faces[SKYBOX_FACE_COUNT] = {0};
    int flags = al_get_new_bitmap_flags();
    al_set_new_bitmap_flags(ALLEGRO_MEMORY_BITMAP);
    bool ok = true;
    int size = 0;
    for (int i=0;i<SKYBOX_FACE_COUNT;++i) {
        if (!paths[i] || !(faces[i]=al_load_bitmap(paths[i]))) { ok=false; break; }
        int width=al_get_bitmap_width(faces[i]), height=al_get_bitmap_height(faces[i]);
        if (!size) size=width;
        if (width<=0 || width>max_size || width != size || height != size) { ok=false; break; }
    }
    al_set_new_bitmap_flags(flags);
    GLuint texture = 0;
    GLint old_unit=0, old_cube=0, old_alignment=0;
    GLint old_row_length=0, old_skip_rows=0, old_skip_pixels=0;
    if (ok) ok = (size_t)size <= SIZE_MAX / (size_t)size / 4;
    if (ok) {
        unsigned char *pixels=malloc((size_t)size*size*4);
        if (!pixels) ok=false;
        else {
            glGetIntegerv(GL_ACTIVE_TEXTURE,&old_unit);
            active_texture(GL_TEXTURE0);
            glGetIntegerv(GL_TEXTURE_BINDING_CUBE_MAP,&old_cube);
            glGetIntegerv(GL_UNPACK_ALIGNMENT,&old_alignment);
            glGetIntegerv(GL_UNPACK_ROW_LENGTH,&old_row_length);
            glGetIntegerv(GL_UNPACK_SKIP_ROWS,&old_skip_rows);
            glGetIntegerv(GL_UNPACK_SKIP_PIXELS,&old_skip_pixels);
            glPixelStorei(GL_UNPACK_ALIGNMENT,1);
            glPixelStorei(GL_UNPACK_ROW_LENGTH,0);
            glPixelStorei(GL_UNPACK_SKIP_ROWS,0);
            glPixelStorei(GL_UNPACK_SKIP_PIXELS,0);
            glGenTextures(1,&texture);
            glBindTexture(GL_TEXTURE_CUBE_MAP,texture);
            for (int i=0;i<SKYBOX_FACE_COUNT;++i) {
                ALLEGRO_LOCKED_REGION *lock=al_lock_bitmap(faces[i],ALLEGRO_PIXEL_FORMAT_ABGR_8888_LE,ALLEGRO_LOCK_READONLY);
                if (!lock) { ok=false; break; }
                for (int y=0;y<size;++y) memcpy(pixels+(size_t)y*size*4,(const unsigned char *)lock->data+(ptrdiff_t)y*lock->pitch,(size_t)size*4);
                al_unlock_bitmap(faces[i]);
                glTexImage2D(GL_TEXTURE_CUBE_MAP_POSITIVE_X+i,0,GL_SRGB8_ALPHA8,size,size,0,GL_RGBA,GL_UNSIGNED_BYTE,pixels);
            }
            glTexParameteri(GL_TEXTURE_CUBE_MAP,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
            glTexParameteri(GL_TEXTURE_CUBE_MAP,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
            glTexParameteri(GL_TEXTURE_CUBE_MAP,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_CUBE_MAP,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_CUBE_MAP,GL_TEXTURE_WRAP_R,GL_CLAMP_TO_EDGE);
            if (glGetError()!=GL_NO_ERROR) ok=false;
            glBindTexture(GL_TEXTURE_CUBE_MAP,(GLuint)old_cube);
            glPixelStorei(GL_UNPACK_ALIGNMENT,old_alignment);
            glPixelStorei(GL_UNPACK_ROW_LENGTH,old_row_length);
            glPixelStorei(GL_UNPACK_SKIP_ROWS,old_skip_rows);
            glPixelStorei(GL_UNPACK_SKIP_PIXELS,old_skip_pixels);
            active_texture((GLenum)old_unit);
            free(pixels);
        }
    }
    for (int i=0;i<SKYBOX_FACE_COUNT;++i) if (faces[i]) al_destroy_bitmap(faces[i]);
    if (!ok) {
        if (texture) glDeleteTextures(1,&texture);
        fprintf(stderr,"Skybox load failed: need six readable, equally sized square faces.\n");
        return false;
    }
    if (skybox->texture) glDeleteTextures(1,&skybox->texture);
    skybox->texture=texture;
    return true;
}

void skybox_draw(const Skybox *skybox, const Camera *camera, float aspect, bool linear_output)
{
    if (!skybox->shader || !skybox->texture || !camera || !isfinite(aspect) || aspect<=0 ||
        !isfinite(camera->yaw) || !isfinite(camera->pitch) || !isfinite(skybox->yaw) ||
        !isfinite(skybox->intensity) || skybox->intensity<0) return;
    float yaw=camera->yaw+skybox->yaw, cp=cosf(camera->pitch), sp=sinf(camera->pitch), cy=cosf(yaw), sy=sinf(yaw);
    float right[3]={cy,0,sy}, up[3]={-sp*sy,cp,sp*cy}, forward[3]={cp*sy,sp,-cp*cy};
    ALLEGRO_SHADER *previous_shader=al_get_current_shader();
    int old_depth=al_get_render_state(ALLEGRO_DEPTH_TEST);
    int old_function=al_get_render_state(ALLEGRO_DEPTH_FUNCTION);
    int old_mask=al_get_render_state(ALLEGRO_WRITE_MASK);
    int old_alpha=al_get_render_state(ALLEGRO_ALPHA_TEST);
    int blend_op,blend_source,blend_dest;
    al_get_blender(&blend_op,&blend_source,&blend_dest);
    GLint old_unit=0,old_cube=0,old_program=0;
    glGetIntegerv(GL_CURRENT_PROGRAM,&old_program);
    glGetIntegerv(GL_ACTIVE_TEXTURE,&old_unit);
    active_texture(GL_TEXTURE0);
    glGetIntegerv(GL_TEXTURE_BINDING_CUBE_MAP,&old_cube);
    glPushAttrib(GL_ENABLE_BIT|GL_COLOR_BUFFER_BIT|GL_DEPTH_BUFFER_BIT|GL_STENCIL_BUFFER_BIT);
    al_use_shader(skybox->shader);
    al_set_blender(ALLEGRO_ADD,ALLEGRO_ONE,ALLEGRO_ZERO);
    al_set_render_state(ALLEGRO_DEPTH_TEST,true);
    al_set_render_state(ALLEGRO_DEPTH_FUNCTION,ALLEGRO_RENDER_LESS_EQUAL);
    al_set_render_state(ALLEGRO_WRITE_MASK,ALLEGRO_MASK_RGBA);
    al_set_render_state(ALLEGRO_ALPHA_TEST,false);
    glDisable(GL_STENCIL_TEST);
    glDisable(GL_CULL_FACE);
    glDisable(GL_SCISSOR_TEST);
    /* Programmable Allegro alpha state does not disable a raw legacy test. */
    glDisable(GL_ALPHA_TEST);
    if (skybox->seamless) glEnable(GL_TEXTURE_CUBE_MAP_SEAMLESS);
    active_texture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_CUBE_MAP,skybox->texture);
    al_set_shader_int("u_sky",0);
    al_set_shader_int("u_linear_output",linear_output);
    al_set_shader_float("u_intensity",skybox->intensity);
    al_set_shader_float("u_aspect",aspect);
    al_set_shader_float("u_tan_half_fov",camera_tan_half_fov());
    al_set_shader_float_vector("u_right",3,right,1);
    al_set_shader_float_vector("u_up",3,up,1);
    al_set_shader_float_vector("u_forward",3,forward,1);
    const ALLEGRO_VERTEX quad[6]={
        {.x=-1,.y=-1}, {.x=1,.y=-1}, {.x=1,.y=1},
        {.x=-1,.y=-1}, {.x=1,.y=1}, {.x=-1,.y=1},
    };
    al_draw_prim(quad,NULL,NULL,0,6,ALLEGRO_PRIM_TRIANGLE_LIST);
    al_use_shader(previous_shader);
    al_set_render_state(ALLEGRO_DEPTH_TEST,old_depth);
    al_set_render_state(ALLEGRO_DEPTH_FUNCTION,old_function);
    al_set_render_state(ALLEGRO_WRITE_MASK,old_mask);
    al_set_render_state(ALLEGRO_ALPHA_TEST,old_alpha);
    /* Also preserve raw compatibility state if the caller bypassed Allegro. */
    use_program((GLuint)old_program);
    al_set_blender(blend_op,blend_source,blend_dest);
    glPopAttrib();
    active_texture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_CUBE_MAP,(GLuint)old_cube);
    active_texture((GLenum)old_unit);
}

void skybox_destroy(Skybox *skybox)
{
    if (skybox->texture) glDeleteTextures(1,&skybox->texture);
    if (skybox->shader) al_destroy_shader(skybox->shader);
    memset(skybox,0,sizeof(*skybox));
}
