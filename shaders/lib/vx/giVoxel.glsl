bool giVoxelNonFull(uint word) {
	return (word >> 31u) != 0u;
}

bool giVoxelSeeThrough(uint word) {
	return word != 0u && ((word >> 30u) & 1u) == (word >> 31u);
}

bool giVoxelLeaves(uint word) {
	return ((word >> 27u) & 1u) != 0u;
}

bool giVoxelPlant(uint word) {
	return ((word >> 26u) & 1u) != 0u;
}

float giVoxelSkyLight(uint word) {
	return float((word >> 21u) & 31u) / 31.0;
}

vec3 giVoxelAlbedo(uint word) {
	vec3 albedo = vec3((word >> 14u) & 127u, (word >> 7u) & 127u, word & 127u) / 127.0;

	return pow(albedo, vec3(2.2));
}

#if defined VSH && defined SHADOW
uint giHash(uint value) {
	value ^= value >> 16u;
	value *= 0x7feb352du;
	value ^= value >> 15u;
	value *= 0x846ca68bu;

	return value ^ (value >> 16u);
}

void updateVoxelGi(int blockId, float skyLight) {
	bool head = blockEntityId == 10086;

	if (!head && (blockId == 10001 || !any(equal(ivec4(renderStage), ivec4(MC_RENDER_STAGE_TERRAIN_SOLID, MC_RENDER_STAGE_TERRAIN_TRANSLUCENT, MC_RENDER_STAGE_TERRAIN_CUTOUT, MC_RENDER_STAGE_TERRAIN_CUTOUT_MIPPED))))) return;

	vec3 midBlock = head ? vec3(0.0) : at_midBlock;
	vec3 modelPos = gl_Vertex.xyz + midBlock / 64.0;
	vec3 viewPos  = mat3(gl_ModelViewMatrix) * modelPos + gl_ModelViewMatrix[3].xyz;
	vec3 shadowPos = mat3(shadowModelViewInverse) * viewPos + shadowModelViewInverse[3].xyz;
	vec3 voxelPos = worldToVoxel(shadowPos);

	if (head) {
		vec2 uvSide = sign(gl_MultiTexCoord0.xy - mc_midTexCoord.xy);
		vec3 outward = gl_Normal + at_tangent.xyz * uvSide.x + cross(at_tangent.xyz, gl_Normal) * (at_tangent.w * uvSide.y);

		blockId = 0;
		midBlock = (floor(voxelPos - mat3(shadowModelViewInverse) * (mat3(gl_ModelViewMatrix) * outward) * 0.1) + 0.5 - voxelPos) * 64.0;
		voxelPos += midBlock / 64.0;
	}

	if (!isInsideVoxelVolume(voxelPos)) return;

	bool plant = (blockId >= 10304 && blockId <= 10319 && blockId != 10314) || (blockId >= 10035 && blockId <= 10040);
	bool corner = all(greaterThanEqual(abs(midBlock), vec3(31.5)));
	ivec3 cell = ivec3(voxelPos);
	ivec3 previousCell = cell + ivec3(floor(cameraPosition) - floor(previousCameraPosition));
	int quadVertex = (gl_VertexID - gl_BaseVertexARB) & 3;
	uint shape = 0u;

	if (!plant && quadVertex != 2 && all(lessThan(cell, ivec3(voxelVolumeSize))) && all(greaterThanEqual(previousCell, ivec3(0))) && all(lessThan(previousCell, ivec3(voxelVolumeSize)))) {
		if ((frameCounter & 1) == 0) {
			shape = texelFetch(voxelShapeSamplerCopy, previousCell, 0).r;
		} else {
			shape = texelFetch(voxelShapeSampler, previousCell, 0).r;
		}
	}

	if (shape == uint((frameCounter + 254) % 255 + 1)) {
		uint cellIndex = uint(cell.x + (cell.y + cell.z * (VOXEL_VOLUME_SIZE / 2)) * VOXEL_VOLUME_SIZE);
		uint quadId = uint(gl_VertexID - quadVertex) + uint(renderStage) * 0x9e3779b9u;
		uint keyA = giHash(quadId + giHash(cellIndex)) | 1u;
		uint keyB = giHash(cellIndex + giHash(quadId ^ 0x85ebca6bu)) | 1u;
		uint slot = keyA & 262143u;
		uvec3 point = uvec3(clamp(floor((0.5 - midBlock / 64.0) * 32.0 + 0.5), 0.0, 32.0));
		uint uvCorner = uint(gl_MultiTexCoord0.x > mc_midTexCoord.x) | (uint(gl_MultiTexCoord0.y > mc_midTexCoord.y) << 1u);
		uint entry = point.x | (point.y << 6u) | (point.z << 12u) | ((quadVertex == 0 ? cellIndex & 16383u : (quadVertex == 1 ? (cellIndex >> 14u) | (uvCorner << 9u) : uvCorner)) << 18u);
		uvec2 alphaMask = uvec2(0u);

		if (quadVertex == 0) {
			vec2 uvLow = min(gl_MultiTexCoord0.xy, mc_midTexCoord.xy * 2.0 - gl_MultiTexCoord0.xy);
			vec2 uvSize = abs(mc_midTexCoord.xy - gl_MultiTexCoord0.xy) * 2.0;

			for (int i = 0; i < 64; i++) {
				uint texelBit = uint(texture2DLod(tex, uvLow + uvSize * (vec2(i % 8, i / 8) + 0.25) / 8.0, 0.0).a >= 0.1) << uint(i & 31);

				if (i < 32) alphaMask.x |= texelBit; else alphaMask.y |= texelBit;
			}
		}

		for (int i = 0; i < 16; i++) {
			ivec3 base = ivec3(int(slot & 127u) * 8, int((slot >> 7u) & 63u), int(slot >> 13u));
			uint owner = imageAtomicCompSwap(quad_hash_img, base, 0u, keyA);

			if (owner == 0u || owner == keyA) {
				owner = imageAtomicCompSwap(quad_hash_img, base + ivec3(1, 0, 0), 0u, keyB);

				if (owner == 0u || owner == keyB) {
					imageStore(quad_hash_img, base + ivec3(2 + min(quadVertex, 2), 0, 0), uvec4(entry));

					if (quadVertex == 0) {
						imageStore(quad_hash_img, base + ivec3(5, 0, 0), uvec4(alphaMask.x));
						imageStore(quad_hash_img, base + ivec3(6, 0, 0), uvec4(alphaMask.y));
						imageStore(quad_hash_img, base + ivec3(7, 0, 0), uvec4(uvCorner));
					}

					break;
				}
			}

			slot = (slot + 1u) & 262143u;
		}
	}

	if (quadVertex != 0 && corner) return;

	vec4 texel = texture2DLod(tex, mc_midTexCoord.xy, 4.0);

	if (head && texel.a < 0.5) return;

	uvec3 albedo = uvec3(clamp(texel.rgb * gl_Color.rgb, 0.0, 1.0) * 127.0 + 0.5);
	uint priority = gl_Normal.y > 0.5 ? 3u : (gl_Normal.y > -0.5 ? 2u : 1u);
	uint word = (corner ? 0u : 0x80000000u) | (uint(corner != (texel.a < 0.5 || (blockId >= 10201 && blockId <= 10216))) << 30u) | (priority << 28u) | (uint(blockId == 10314) << 27u) | (uint(plant) << 26u) | (uint(clamp(skyLight, 0.0, 1.0) * 31.0 + 0.5) << 21u) | (albedo.r << 14u) | (albedo.g << 7u) | albedo.b;

	imageAtomicMax(voxel_gi_img, ivec3(voxelPos), word);

	#ifdef WORLD_SPACE_REFLECTIONS
	if (corner && !head) {
		vec2 atlasSize = vec2(textureSize(tex, 0));
		uvec2 spriteLow = min(uvec2(min(gl_MultiTexCoord0.xy, mc_midTexCoord.xy * 2.0 - gl_MultiTexCoord0.xy) * atlasSize + 0.5), uvec2(8191u));
		uint spriteSize = uint(abs(mc_midTexCoord.x - gl_MultiTexCoord0.x) * 2.0 * atlasSize.x + 0.5);
		uint sprite = (uint(texel.a >= 0.5) << 31u) | (uint(any(lessThan(gl_Color.rgb, vec3(0.99)))) << 30u) | (spriteLow.x << 17u) | (spriteLow.y << 4u) | uint(findMSB(max(spriteSize, 1u)));

		imageAtomicMax(voxel_sprite_img, ivec3(cell.x * 3 + (gl_Normal.y > 0.5 ? 0 : (gl_Normal.y < -0.5 ? 1 : 2)), cell.yz), sprite);
	}

	if (quadVertex == 0 || head) imageAtomicOr(voxel_sprite_img, ivec3(int(voxelVolumeSize.x) * 3 + (cell.x >> 2), cell.y >> 1, cell.z >> 2), 1u << uint((cell.x & 3) | ((cell.z & 3) << 2) | ((cell.y & 1) << 4)));
	#endif

	if ((word & 0xC4000000u) == 0x80000000u) {
		if ((frameCounter & 1) == 0) {
			imageStore(voxel_shape_img, cell, uvec4(frameCounter % 255 + 1));
		} else {
			imageStore(voxel_shape_img_copy, cell, uvec4(frameCounter % 255 + 1));
		}
	}
}
#endif
