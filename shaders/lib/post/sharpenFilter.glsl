// Four-neighbour sharpening, with fixed offsets instead of dynamic indexing.
void sharpenFilter(inout vec3 color, in vec2 coord) {
    float mult = MC_RENDER_QUALITY * 0.0625;
    vec2 pixel = 1.0 / vec2(viewWidth, viewHeight);

    vec3 neighbours = texture2D(colortex1, coord + vec2( pixel.x, 0.0)).rgb;
    neighbours += texture2D(colortex1, coord + vec2(-pixel.x, 0.0)).rgb;
    neighbours += texture2D(colortex1, coord + vec2(0.0,  pixel.y)).rgb;
    neighbours += texture2D(colortex1, coord + vec2(0.0, -pixel.y)).rgb;
    color = color * (MC_RENDER_QUALITY * 0.25 + 1.0) - neighbours * mult;
}
