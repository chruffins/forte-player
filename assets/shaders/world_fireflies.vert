#version 120
attribute vec3 al_pos;
attribute vec2 al_texcoord;
attribute vec4 al_color;
uniform mat4 al_projview_matrix;
uniform vec4 u_bands[12];
uniform vec3 u_right, u_up, u_eye;
uniform float u_time;
uniform float u_vocal;
uniform bool u_ground_pass;
varying vec3 light_delta, surface_position;
varying vec2 local;
varying vec3 glow;
varying float intensity;
float band(int i) {
    vec4 v = u_bands[i / 4];
    int c = i - (i / 4) * 4;
    if (c == 0) return v.x;
    if (c == 1) return v.y;
    if (c == 2) return v.z;
    return v.w;
}
void main() {
    int i = int(floor(al_color.r * 47.0 + 0.5));
    float power = clamp(band(i), 0.0, 1.0);
    float vocal_response = u_vocal * al_color.a;
    float phase = al_color.g * 6.2831853;
    // Flight is continuous and independent of FFT updates. Audio only changes
    // glow and radius; changing its amplitude here teleported flies at 20 Hz.
    vec3 center = al_pos + vec3(sin(u_time * 0.47 + phase) * 0.85,
        sin(u_time * 0.73 + phase * 2.0) * 0.38,
        cos(u_time * 0.39 + phase) * 0.85);
    float distance_to_eye = length(center - u_eye);
    // Keep near-camera fireflies as small lights, not giant screen-filling orbs.
    float radius = min(0.055 + power * 0.17 + vocal_response * 0.045, max(distance_to_eye, 0.1) * 0.018);
    // Both passes share this exact center, color, FFT power and flicker.
    // A bounded floor quad integrates the point light, rather than evaluating
    // all 288 lights for every floor pixel or moving particles on the CPU.
    vec3 position = u_ground_pass
        ? vec3(center.x + al_texcoord.x * 6.0, 0.002, center.z + al_texcoord.y * 6.0)
        : center + (u_right * al_texcoord.x + u_up * al_texcoord.y) * radius;
    light_delta = center - position;
    surface_position = position;
    gl_Position = al_projview_matrix * vec4(position, 1.0);
    local = al_texcoord;
    vec3 spectrum_color = mix(vec3(0.43, 1.0, 0.69), vec3(1.0, 0.74, 0.32), al_color.b);
    // A deterministic subset carries the separate vocal response; other flies
    // retain their FFT-driven mint/amber palette at every vocal score.
    glow = mix(spectrum_color, vec3(0.64, 0.28, 1.0), vocal_response * 0.86);
    float flicker = 0.70 + 0.30 * sin(u_time * 2.4 + phase);
    intensity = (0.018 + power * 1.85) * flicker * (1.0 + vocal_response * 0.55);
    if (!u_ground_pass) intensity *= exp(-distance_to_eye * 0.013)
        * smoothstep(0.35, 1.2, distance_to_eye);
}
