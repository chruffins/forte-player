#version 120
uniform bool u_ground_pass;
uniform vec3 u_eye;
varying vec3 light_delta, surface_position;
varying vec2 local;
varying vec3 glow;
varying float intensity;
void main() {
    if (u_ground_pass) {
        float d2 = dot(light_delta, light_delta);
        float d = sqrt(max(d2, 0.0001));
        // Omnidirectional finite-range point source, diffuse response on the
        // upward-facing plane, inverse-square-like falloff, smooth range edge.
        float diffuse = max(light_delta.y / d, 0.0);
        float attenuation = (1.0 - smoothstep(4.0, 6.0, d)) / (1.0 + d2);
        vec2 p = surface_position.xz * 0.5;
        float check = mod(floor(p.x) + floor(p.y), 2.0);
        vec2 footprint = fwidth(p);
        check = mix(check, 0.5, smoothstep(0.4, 1.6, max(footprint.x, footprint.y)));
        float albedo = mix(0.28, 0.65, check);
        float visibility = exp(-length(surface_position - u_eye) * 0.022);
        gl_FragColor = vec4(glow * intensity * diffuse * attenuation * albedo * visibility * 2.4, 0.0);
        return;
    }
    float radius_sq = dot(local, local);
    float core = exp(-radius_sq * 28.0);
    float halo = exp(-radius_sq * 4.5) * 0.22;
    gl_FragColor = vec4(glow * (core * 2.3 + halo) * intensity, 0.0);
}
