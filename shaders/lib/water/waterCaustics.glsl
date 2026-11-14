// World-space UVs are shared by the five height probes; only the offset varies.
float getWaterHeightMap(vec2 uvA, vec2 uvB, vec2 offset) {
    float noise = 0.0;
    offset /= 256.0;

    #if WATER_NORMALS == 1
    float noiseA = texture2D(noisetex, uvA + offset).g;
    float noiseB = texture2D(noisetex, uvB + offset).g;
    #elif WATER_NORMALS == 2
    float noiseA = texture2D(noisetex, uvA + offset).r;
    float noiseB = texture2D(noisetex, uvB + offset).r;
    noiseA *= noiseA;
    noiseB *= noiseB;
    #endif

    #if WATER_NORMALS > 0
    noise = mix(noiseA, noiseB, WATER_NORMAL_DETAIL);
    #endif

    return noise * WATER_NORMAL_BUMP;
}

float getWaterCaustics(vec3 waterPos) {
    vec2 wind = vec2(frameTimeCounter) * 0.5 * WATER_NORMAL_SPEED;
    vec2 surfacePos = waterPos.xz - waterPos.y * 0.2;
    vec2 uvA = (surfacePos - wind) / 256.0;

    #if WATER_NORMALS == 1
    vec2 uvB = (surfacePos + wind) / 48.0;
    #elif WATER_NORMALS == 2
    vec2 uvB = (surfacePos + wind) / 96.0;
    #else
    vec2 uvB = vec2(0.0);
    #endif

    float h0 = getWaterHeightMap(uvA, uvB, vec2(0.0));
    float h1 = getWaterHeightMap(uvA, uvB, vec2( WATER_NORMAL_OFFSET, 0.0));
    float h2 = getWaterHeightMap(uvA, uvB, vec2(-WATER_NORMAL_OFFSET, 0.0));
    float h3 = getWaterHeightMap(uvA, uvB, vec2(0.0,  WATER_NORMAL_OFFSET));
    float h4 = getWaterHeightMap(uvA, uvB, vec2(0.0, -WATER_NORMAL_OFFSET));

	float xDeltaA = (h1 - h0) / WATER_NORMAL_OFFSET;
	float xDeltaB = (h2 - h0) / WATER_NORMAL_OFFSET;
	float yDeltaA = (h3 - h0) / WATER_NORMAL_OFFSET;
	float yDeltaB = (h4 - h0) / WATER_NORMAL_OFFSET;

	float height = max((xDeltaA * -xDeltaB + yDeltaA * -yDeltaB) * 48.0, 0.0);

	return height;
}