float getStarNoise(vec2 pos) {
	vec3 p3 = fract(vec3(pos.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

vec3 getStarColor(float value) {
	if (value < 0.50) return vec3(0.68, 0.80, 1.00); // Blue
	if (value < 0.74) return vec3(0.84, 0.90, 1.00); // Cool white
	if (value < 0.95) return vec3(1.00, 0.98, 0.92); // White
	if (value < 0.97) return vec3(1.00, 0.86, 0.64); // Warm
	return vec3(1.00, 0.68, 0.46);                   // Orange-red
}

void drawStars(inout vec3 color, in vec3 worldPos, in vec3 sunVec, in float VoU, in float VoS, in float caveFactor, in float nebulaFactor, in float atmosphereHardMixFactor, in float occlusion, float size) {
	#ifdef OVERWORLD
	float spaceFactor = clamp(cameraPosition.y / KARMAN_LINE, 0.0, 1.0);
	float visibility = fmix((1.0 - sunVisibility) * (1.0 - wetness) * sqrt(max(VoU, 0.0)), 1.0 - atmosphereHardMixFactor, spaceFactor) * (1.0 - occlusion) * caveFactor;
	#else
	float visibility = 0.4 - nebulaFactor * 0.2;
	#endif

	if (visibility > 0.0) {
		vec2 planeCoord = worldPos.xz / max(abs(worldPos.y) + length(worldPos.xz), 1e-4);
			 planeCoord *= size * 1.5;
			 planeCoord += cameraPosition.xz * 0.00001 + frameTimeCounter * 0.0;

		float gridScale = 750.0 * STAR_SCALE;
		vec2 starCoord = planeCoord * gridScale;
		vec2 cell = floor(starCoord);
		vec2 localCoord = fract(starCoord) - 0.5;

		// Evaluate derivatives before the potentially nonuniform early exit.
		float distanceToStar = length(localCoord);
		float antialiasing = max(fwidth(distanceToStar), 0.010);

		float spawnNoise = getStarNoise(cell + vec2(17.0, 53.0));
		float spawn = step(0.999 - min(nebulaFactor * 0.5, 0.5), spawnNoise);
		if (spawn == 0.0) return;

		float sizeNoise = getStarNoise(cell + vec2(233.0, 71.0));
		float colorNoise = getStarNoise(cell + vec2(359.0, 131.0));
		float radius = 0.05 + pow2(sizeNoise) * 0.25 + pow3(sizeNoise) * 0.5 * colorNoise;
		float star = 1.0 - smoothstep(
			radius - antialiasing,
			radius + antialiasing,
			distanceToStar
		);
		star *= spawn;

		star *= visibility * visibility * (0.5 + nebulaFactor * 1.5);

		vec3 starColor = getStarColor(colorNoise);

		#ifdef OVERWORLD
		color += star * starColor;
		#else
		color += star * starColor * 0.65;
		#endif
	}
}
