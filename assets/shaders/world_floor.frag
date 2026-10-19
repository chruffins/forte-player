#version 120
uniform vec3 u_eye;
varying vec3 world_position;
void main() {
    vec2 p = world_position.xz * 0.5;
    float check = mod(floor(p.x) + floor(p.y), 2.0);
    // Fade unresolved checks into their average instead of shimmering at distance.
    vec2 footprint = fwidth(p);
    check = mix(check, 0.5, smoothstep(0.4, 1.6, max(footprint.x, footprint.y)));
    vec3 color = mix(vec3(0.020, 0.030, 0.043), vec3(0.065, 0.080, 0.093), check);
    float fog = 1.0 - exp(-length(world_position - u_eye) * 0.022);
    color = mix(color, vec3(0.014, 0.023, 0.034), fog);
    gl_FragColor = vec4(color, 1.0);
}
