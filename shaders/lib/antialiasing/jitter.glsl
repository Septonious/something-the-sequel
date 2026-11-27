uniform int frameCounter;

const vec2 jitterOffsets8[8] = vec2[8](
							vec2( 0.125,-0.375),
							vec2(-0.125, 0.375),
							vec2( 0.625, 0.125),
							vec2( 0.375,-0.625),
							vec2(-0.625, 0.625),
							vec2(-0.875,-0.125),
							vec2( 0.375,-0.875),
							vec2( 0.875, 0.875)
						);

vec2 TAAJitter(vec2 coord, float w) {
	vec2 offset = jitterOffsets8[frameCounter & 7] * (w / vec2(viewWidth, viewHeight));

	return coord + offset;
}
vec2 TAAJitterUV(int frame) { return jitterOffsets8[frame & 7] * (0.5 / vec2(viewWidth, viewHeight)); }
