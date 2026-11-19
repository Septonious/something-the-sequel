vec4 voxelReflectionTrace(sampler2D atlas, vec3 origin, vec3 direction, vec3 lightDirection, float cameraDistance, out float hitDistance) {
	ivec3 hitCell, hitFace;
	uint hitWord;

	if (!voxelReflectionHit(origin, direction, hitCell, hitFace, hitDistance, hitWord)) return vec4(giPassLight, 1.0);

	vec3 hitPos = origin + direction * hitDistance;
	vec2 screenUv;
	float screenWeight = voxelHitScreen(depthtex1, hitPos, hitFace, screenUv);
	vec3 screenColour = vec3(0.0);

	if (screenWeight > 0.0) screenColour = pow(pow8(texture2D(gaux1, screenUv).rgb) * 256.0, vec3(2.2));

	if (screenWeight >= 1.0) return vec4(screenColour, 0.0);

	vec3 albedo = giVoxelAlbedo(hitWord);
	uint sprite = giVoxelNonFull(hitWord) ? 0u : texelFetch(voxelSpriteSampler, ivec3(hitCell.x * 3 + (hitFace.y > 0 ? 0 : (hitFace.y < 0 ? 1 : 2)), hitCell.yz), 0).r;

	if (sprite != 0u) {
		vec2 atlasSize = vec2(textureSize(atlas, 0));
		float spriteSize = float(1u << (sprite & 15u));
		vec2 spriteLow = vec2((sprite >> 17u) & 8191u, (sprite >> 4u) & 8191u);
		vec3 local = fract(hitPos);
		vec2 faceCoord = hitFace.y != 0 ? local.xz : vec2(hitFace.x != 0 ? local.z : local.x, 1.0 - local.y);
		float lod = log2(max((cameraDistance + hitDistance) * 2.0 / (gbufferProjection[1][1] * viewHeight) * spriteSize, 1.0));
		float inset = min(exp2(lod) * 0.5, spriteSize * 0.5);
		vec4 texel = textureLod(atlas, clamp(spriteLow + faceCoord * spriteSize, spriteLow + inset, spriteLow + spriteSize - inset) / atlasSize, lod);
		vec3 colour = mix(textureLod(atlas, (spriteLow + spriteSize * 0.5) / atlasSize, log2(spriteSize)).rgb, texel.rgb, step(0.1, texel.a));

		if (((sprite >> 30u) & 1u) != 0u) {
			uint colourSprite = texelFetch(voxelSpriteSampler, ivec3(hitCell.x * 3, hitCell.yz), 0).r;
			if (colourSprite == 0u) colourSprite = texelFetch(voxelSpriteSampler, ivec3(hitCell.x * 3 + 2, hitCell.yz), 0).r;
			if (colourSprite == 0u) colourSprite = texelFetch(voxelSpriteSampler, ivec3(hitCell.x * 3 + 1, hitCell.yz), 0).r;

			vec2 colourCentre = vec2((colourSprite >> 17u) & 8191u, (colourSprite >> 4u) & 8191u) + float(1u << (colourSprite & 15u)) * 0.5;
			vec3 stored = vec3((hitWord >> 14u) & 127u, (hitWord >> 7u) & 127u, hitWord & 127u) / 127.0;

			colour *= clamp(stored / max(textureLod(atlas, colourCentre / atlasSize, 4.0).rgb, vec3(1.0 / 127.0)), 0.0, 1.0);
		}

		albedo = pow(colour, vec3(2.2));
	}

	vec3 shaded = pow(giHitRadiance(hitCell, hitFace, hitPos, hitWord | 0x1FFFFFu, lightDirection) * albedo + giPassLight, vec3(1.0 / 2.2));
	vec3 hitWorldPos = voxelToWorld(hitPos);
	vec3 hitViewPos = mat3(gbufferModelView) * hitWorldPos + gbufferModelView[3].xyz;
	float hitHardMixFactor = 0.0;

	Fog(shaded, hitViewPos, getAtmosphere(hitViewPos, hitWorldPos, hitHardMixFactor), 0.0);

	return vec4(mix(pow(shaded, vec3(2.2)), screenColour, screenWeight), 0.0);
}
