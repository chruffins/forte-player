#version 120
attribute vec3 al_pos;
uniform mat4 al_projview_matrix;
varying vec3 world_position;
void main() {
    world_position = al_pos;
    gl_Position = al_projview_matrix * vec4(al_pos, 1.0);
}
