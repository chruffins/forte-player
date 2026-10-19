#version 120
// All shape generation and antialiasing happen on the GPU. No per-bar draws.
// Twelve vec4s fit older fragment-uniform limits better than 48 scalar slots.
uniform vec4 levels[12];
uniform vec2 vis_size;
uniform int vis_mode;
uniform float vis_time;
varying vec2 vis_uv;
const float TAU = 6.28318530718;

float bandLevel(int index) {
    int group = index / 4;
    int component = index - group * 4;
    vec4 value = levels[group];
    if (component == 0) return value.x;
    if (component == 1) return value.y;
    if (component == 2) return value.z;
    return value.w;
}
float boxDistance(vec2 p, vec2 halfSize) {
    vec2 d = abs(p) - halfSize;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}
void main() {
    vec2 uv = clamp(vis_uv, 0.0, 1.0);
    vec3 background = mix(vec3(0.018, 0.045, 0.075), vec3(0.035, 0.090, 0.135), 1.0 - uv.y);
    vec3 color;
    if (vis_mode == 0) {
        float column = uv.x * 48.0;
        int band = int(min(floor(column), 47.0));
        float level = clamp(bandLevel(band), 0.0, 1.0);
        vec2 p = vec2((fract(column) - 0.5) * vis_size.x / 48.0, (uv.y - 0.5) * vis_size.y);
        vec2 halfSize = vec2(vis_size.x / 48.0 * 0.34, level * vis_size.y * 0.43);
        float distance = boxDistance(p, halfSize);
        float mask = (1.0 - smoothstep(-0.6, 0.6, distance)) * step(0.008, level);
        float glow = exp(-max(distance, 0.0) / 3.0) * step(0.008, level);
        vec3 ink = mix(vec3(0.10, 0.48, 0.65), vec3(0.37, 0.94, 0.98), abs(uv.y - 0.5) * 2.0);
        if (uv.y > 0.5) ink *= mix(0.85, 0.35, (uv.y - 0.5) * 2.0);
        float axis = 1.0 - smoothstep(0.0, 1.2, abs(p.y));
        color = background + vec3(0.02, 0.09, 0.12) * axis;
        color += ink * (mask + 0.12 * glow);
    } else {
        float scale = min(vis_size.x, vis_size.y);
        vec2 p = (uv - 0.5) * vis_size / scale;
        float angle = fract(atan(p.y, p.x) / TAU + 0.5);
        // Interpolate adjacent bands so the ring is closed and continuous.
        float bandPos = angle * 48.0;
        int band = int(min(floor(bandPos), 47.0));
        int nextBand = band + 1;
        if (nextBand == 48) nextBand = 0;
        float level = mix(bandLevel(band), bandLevel(nextBand), fract(bandPos));
        float radius = 0.23 + clamp(level, 0.0, 1.0) * 0.19;
        float distance = abs(length(p) - radius) * scale;
        float stroke = 1.0 - smoothstep(1.0, 2.3, distance);
        float glow = exp(-distance / 7.0);
        float sweep = 0.5 + 0.5 * sin(angle * TAU * 4.0 - vis_time * 1.5);
        vec3 ink = mix(vec3(0.08, 0.61, 0.85), vec3(0.38, 0.94, 0.98), sweep);
        color = background + ink * (stroke * 0.85 + glow * 0.22);
    }
    gl_FragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
