// Photon bloom reconstruction.
//
// Six progressively downsampled and Gaussian-filtered tiles are read from
// colortex0. Photon's default radius gives equal importance to every scale.

void getBloom(inout vec3 color, vec2 coord) {
    vec3 bloom = vec3(0.0);
    float bloomIntensity = 0.125 * BLOOM_STRENGTH;

    #ifdef OVERWORLD
    bloomIntensity *= 1.0 + wetness * eBS + caveFactor;
    #endif

    // Photon atlas: six equal-weight samples, tile coordinates resolved at compile time.
    bloom += texture2D(colortex0, coord * 0.5).rgb;
    bloom += texture2D(colortex0, coord * 0.25 + vec2(0.5, 0.75)).rgb;
    bloom += texture2D(colortex0, coord * 0.125 + vec2(0.75, 0.0)).rgb;
    bloom += texture2D(colortex0, coord * 0.0625 + vec2(0.875, 0.9375)).rgb;
    bloom += texture2D(colortex0, coord * 0.03125 + vec2(0.9375, 0.0)).rgb;
    bloom += texture2D(colortex0, coord * 0.015625 + vec2(0.96875, 0.984375)).rgb;
    bloom *= 1.0 / 6.0;
    color = mix(color, bloom, bloomIntensity);
}
