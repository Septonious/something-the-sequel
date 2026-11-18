const int giTraceSteps = GI_RAY_STEPS;

uint giSeed = 0u;

float giRandom() {
	giSeed = giSeed * 747796405u + 2891336453u;
	uint word = ((giSeed >> ((giSeed >> 28u) + 4u)) ^ giSeed) * 277803737u;

	return float((word >> 22u) ^ word) / 4294967296.0;
}

vec3 giCosineDirection(vec3 normal, vec2 point) {
	float height = point.x * 2.0 - 1.0;
	float angle = point.y * 6.28318530718;
	float radius = sqrt(max(1.0 - height * height, 0.0));

	return normalize(normal + vec3(radius * cos(angle), radius * sin(angle), height) * 0.999);
}

vec3 giCosineDirection(vec3 normal) {
	float pointX = giRandom();
	float pointY = giRandom();

	return giCosineDirection(normal, vec2(pointX, pointY));
}

bool giTrace(vec3 origin, vec3 direction, ivec3 targetCell, out ivec3 hitCell, out ivec3 hitFace, out float hitDistance, out uint hitWord) {
	vec3 directionSign = vec3(greaterThanEqual(direction, vec3(0.0))) * 2.0 - 1.0;
	vec3 delta = 1.0 / max(abs(direction), vec3(0.00001));
	ivec3 cell = ivec3(floor(origin));
	ivec3 cellStep = ivec3(directionSign);
	vec3 side = (vec3(cell) + max(directionSign, 0.0) - origin) * directionSign * delta;
	vec3 rayInverse = directionSign * delta;
	uint frontFaces = (directionSign.x > 0.0 ? 1u : 2u) | (directionSign.y > 0.0 ? 4u : 8u) | (directionSign.z > 0.0 ? 16u : 32u);

	hitCell = cell;
	hitFace = ivec3(0);
	hitDistance = 0.0;
	hitWord = 0u;

	for (int i = 0; i < giTraceSteps; i++) {
		if (i == 0) {
		} else if (side.x < side.y && side.x < side.z) {
			hitDistance = side.x;
			side.x += delta.x;
			cell.x += cellStep.x;
			hitFace = ivec3(-cellStep.x, 0, 0);
		} else if (side.y < side.z) {
			hitDistance = side.y;
			side.y += delta.y;
			cell.y += cellStep.y;
			hitFace = ivec3(0, -cellStep.y, 0);
		} else {
			hitDistance = side.z;
			side.z += delta.z;
			cell.z += cellStep.z;
			hitFace = ivec3(0, 0, -cellStep.z);
		}

		if (cell == targetCell || any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, ivec3(voxelVolumeSize)))) return false;

		hitWord = texelFetch(voxelGiSampler, cell, 0).r;

		if (i == 0 && !giVoxelNonFull(hitWord)) continue;

		if (hitWord == 0u || giVoxelSeeThrough(hitWord) || giVoxelPlant(hitWord)) continue;
		if (giVoxelLeaves(hitWord) && giRandom() < GI_LEAF_PASS) continue;

		if (giVoxelNonFull(hitWord)) {
			uint bounds = texelFetch(voxelBoxSampler, ivec3(cell.x * 2 + 1, cell.yz), 0).r;

			#if GI_DEBUG == 12
			if (bounds == 0u) {
				hitWord = 2080895u;
				hitCell = cell;

				return true;
			}
			#endif

			if (bounds == 0u) continue;

			uvec3 boundBits = uvec3(bounds & 511u, (bounds >> 9u) & 511u, bounds >> 18u);
			vec3 local = (origin - vec3(cell)) * 32.0;
			vec3 boundA = (vec3(findLSB(boundBits)) * 4.0 - local) * rayInverse;
			vec3 boundB = (vec3(findMSB(boundBits)) * 4.0 - local) * rayInverse;
			vec3 boundEnter = min(boundA, boundB);
			vec3 boundLeave = max(boundA, boundB);
			float boundExit = min(boundLeave.x, min(boundLeave.y, boundLeave.z));

			if (max(boundEnter.x, max(boundEnter.y, boundEnter.z)) > boundExit || boundExit < hitDistance * 32.0 - 0.01) continue;

			uint node = texelFetch(voxelBoxSampler, ivec3(cell.x * 2, cell.yz), 0).r;
			vec3 nearestNormal = vec3(0.0);
			float nearest = 1000000.0;

			for (int j = 0; j < 128 && node != 0u; j++) {
				uvec4 quad = texelFetch(quadPoolSampler, ivec3((node - 1u) & 63u, ((node - 1u) >> 6u) & 63u, (node - 1u) >> 12u), 0);

				node = quad.a;

				if ((quad.r >> 31u) != 0u && ((frontFaces >> ((quad.r >> 18u) & 7u)) & 1u) == 0u) continue;

				vec3 corner = vec3(quad.r & 63u, (quad.r >> 6u) & 63u, (quad.r >> 12u) & 63u);
				vec3 edgeA = vec3(quad.g & 63u, (quad.g >> 6u) & 63u, (quad.g >> 12u) & 63u) - corner;

				if ((quad.r >> 31u) != 0u) {
					uint face = (quad.r >> 18u) & 7u;
					vec3 planeA = (corner - local) * rayInverse;
					vec3 planeB = planeA + edgeA * rayInverse;
					vec3 enter = min(planeA, planeB);
					vec3 leave = max(planeA, planeB);
					float boxDistance = max(enter.x, max(enter.y, enter.z));

					if (boxDistance > min(leave.x, min(leave.y, leave.z)) || boxDistance < hitDistance * 32.0 - 0.01 || boxDistance >= nearest) continue;

					nearest = boxDistance;
					nearestNormal = vec3(equal(ivec3(face >> 1u), ivec3(0, 1, 2))) * (float(face & 1u) * 2.0 - 1.0);
				} else {
					vec3 edgeB = vec3(quad.b & 63u, (quad.b >> 6u) & 63u, (quad.b >> 12u) & 63u) - corner;
					vec3 normal = cross(edgeA, edgeB);
					float facing = dot(normal, direction);

					if (facing >= 0.0) continue;

					float quadDistance = dot(normal, corner - local) / facing;
					vec3 point = local + direction * quadDistance - corner;
					vec2 quadCoord = vec2(dot(cross(point, edgeB), normal), dot(cross(edgeA, point), normal)) / dot(normal, normal);

					if (quadDistance < hitDistance * 32.0 - 0.01 || quadDistance >= nearest || clamp(quadCoord, 0.0, 1.0) != quadCoord) continue;

					nearest = quadDistance;
					nearestNormal = normal;
				}

				if (targetCell.x >= 0) break;
			}

			if (nearestNormal == vec3(0.0)) continue;

			vec3 dominant = abs(nearestNormal);

			hitDistance = nearest / 32.0;
			hitFace = ivec3(sign(nearestNormal) * step(max(dominant.yzx, dominant.zxy), dominant));
			hitCell = ivec3(floor(origin + direction * hitDistance + normalize(nearestNormal) * 0.01)) - hitFace;

			return true;
		}

		hitCell = cell;

		return true;
	}

	return false;
}

float giBlockVisibility(vec3 origin, vec3 normal) {
	ivec3 gridCell = ivec3(origin) >> 4;
	ivec3 gridSize = ivec3(voxelVolumeSize) >> 4;
	vec3 lightPos = vec3(0.0);
	float weightSum = 0.0;

	for (int i = 0; i < 27; i++) {
		ivec3 cell = gridCell + ivec3(i % 3, (i / 3) % 3, i / 9) - 1;

		if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, gridSize)) || distance(clamp(origin, vec3(cell) * 16.0, vec3(cell) * 16.0 + 16.0), origin) >= 16.0) continue;

		uint count = texelFetch(lightGridSampler, ivec3(cell.x * 16, cell.yz), 0).r;
		uint stored = min(count, 15u);

		for (uint slot = 0u; slot < stored; slot++) {
			uint data = texelFetch(lightGridSampler, ivec3(cell.x * 16 + 1 + int(slot), cell.yz), 0).r;
			vec3 candidate = vec3(data & 1023u, (data >> 10u) & 1023u, (data >> 20u) & 1023u) + 0.5;
			vec3 toLight = candidate - origin;
			float lightDistance = length(toLight);
			float weight = float(count) / float(stored) * max(dot(normal, toLight), 0.0) * clamp(1.0 - lightDistance / 16.0, 0.0, 1.0) / (lightDistance * lightDistance * lightDistance + 0.5);

			weightSum += weight;

			if (giRandom() * weightSum < weight) lightPos = candidate;
		}
	}

	if (weightSum <= 0.0 || ivec3(lightPos) == ivec3(floor(origin))) return 1.0;

	vec3 target = lightPos + vec3(giRandom(), giRandom(), giRandom()) - 0.5;
	ivec3 hitCell, hitFace;
	float hitDistance;
	uint hitWord;

	return giTrace(origin, normalize(target - origin), ivec3(lightPos), hitCell, hitFace, hitDistance, hitWord) ? 0.0 : 1.0;
}

vec3 giHitRadiance(ivec3 hitCell, ivec3 hitFace, vec3 hitPos, uint hitWord, vec3 lightDirection) {
	vec3 faceNormal = vec3(hitFace);
	float skyLight = giVoxelSkyLight(hitWord);

	vec3 shadowPos = ToShadow(voxelToWorld(hitPos) + faceNormal * 0.2);
	     shadowPos.z -= 0.0512 / float(shadowMapResolution) + 2.0 / 65536.0;
	float sunLight = pow32(skyLight * skyLight);

	if (clamp(shadowPos, 0.0, 1.0) == shadowPos) sunLight = clamp((texture2D(shadowtex1, shadowPos.xy).r - shadowPos.z) * 65536.0, 0.0, 1.0);

	sunLight *= clamp(dot(faceNormal, lightDirection) * 1.01 - 0.01, 0.0, 1.0) * (1.0 - wetness * 0.5) * shadowFade;

	float vanillaDiffuse = (0.25 * faceNormal.y + 0.75) + (0.667 - abs(faceNormal.x)) * (1.0 - abs(faceNormal.y)) * 0.15;
	      vanillaDiffuse *= vanillaDiffuse;

	vec3 airPos = (vec3(hitCell + hitFace) + 0.5) / voxelVolumeSize;
	vec3 blockLight = (frameCounter & 1) == 0 ? texture3D(floodfillSamplerCopy, airPos).rgb : texture3D(floodfillSampler, airPos).rgb;
	     blockLight = pow(blockLight, vec3(1.0 / FLOODFILL_RADIUS)) * FLOODFILL_BRIGHTNESS;

	vec4 cached = giCacheFetch(hitCell + hitFace);
	vec3 ambient = cached.a < 0.0 ? vec3(0.0) : ambientCol * cached.a * clamp(skyLight * 8.0, 0.0, 1.0) + cached.rgb * GI_MULTI_BOUNCE;
	vec3 lighting = mix(ambient, lightCol * (0.15 + skyLight * 0.85), sunLight) + blockLight;

	return giVoxelAlbedo(hitWord) * vanillaDiffuse * lighting;
}
