#version 120
// Rectangle-local coordinates avoid top-left/bottom-left gl_FragCoord mismatches.
attribute vec4 al_pos;
uniform mat4 al_projview_matrix;
uniform vec4 vis_rect;
varying vec2 vis_uv;
void main() {
    vis_uv = (al_pos.xy - vis_rect.xy) / vis_rect.zw;
    gl_Position = al_projview_matrix * al_pos;
}
