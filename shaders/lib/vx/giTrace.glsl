const int giTraceSteps = GI_RAY_STEPS;

uint giSeed = 0u;
float giHitBlockLuminance = 0.0;
vec3 giPassLight = vec3(0.0);
ivec3 giPassCell = ivec3(0);
ivec3 giHitOwner = ivec3(0);

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
	giPassLight = vec3(0.0);

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

		if (hitWord == 0u) continue;

		if (giVoxelSeeThrough(hitWord) || giVoxelPlant(hitWord)) {
			vec4 passFloodfill = (frameCounter & 1) == 0 ? texelFetch(floodfillSamplerCopy, cell, 0) : texelFetch(floodfillSampler, cell, 0);

			if (passFloodfill.a > 1.5 && (passFloodfill.a < 199.5 || passFloodfill.a > 216.5)) {
				giPassLight += pow(passFloodfill.rgb, vec3(1.0 / FLOODFILL_RADIUS)) * (FLOODFILL_BRIGHTNESS * 0.14 * (min(side.x, min(side.y, side.z)) - hitDistance));
				giPassCell = cell;
			}

			continue;
		}

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

				node = quad.a & 524287u;

				uvec2 cutout = uvec2(quad.b, (quad.g >> 18u) | (((quad.r >> 21u) & 1023u) << 14u) | ((quad.a >> 19u) << 24u));

				if ((quad.r >> 31u) != 0u && cutout == uvec2(0xFFFFFFFFu) && ((frontFaces >> ((quad.r >> 18u) & 7u)) & 1u) == 0u) continue;

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

					if (cutout != uvec2(0xFFFFFFFFu)) {
						ivec2 plane = ivec2((face >> 1u) == 0u ? 1 : 0, (face >> 1u) == 2u ? 1 : 2);
						vec3 boxPoint = (local + direction * boxDistance - corner) / max(edgeA, vec3(0.001));
						ivec2 cutoutCell = clamp(ivec2(vec2(boxPoint[plane.x], boxPoint[plane.y]) * 8.0), ivec2(0), ivec2(7));
						int cutoutBit = cutoutCell.x + cutoutCell.y * 8;

						if ((((cutoutBit < 32 ? cutout.x : cutout.y) >> uint(cutoutBit & 31)) & 1u) == 0u) continue;
					}

					nearest = boxDistance;
					nearestNormal = vec3(equal(ivec3(face >> 1u), ivec3(0, 1, 2))) * (float(face & 1u) * 2.0 - 1.0) * (((frontFaces >> face) & 1u) == 0u ? -1.0 : 1.0);
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
			giHitOwner = cell;

			return true;
		}

		hitCell = cell;
		giHitOwner = cell;

		return true;
	}

	return false;
}

float giBlockVisibility(vec3 origin) {
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
			float weight = float(count) / float(stored) * clamp(1.0 - lightDistance / 16.0, 0.0, 1.0) / (lightDistance * lightDistance + 0.5);

			weightSum += weight;

			if (giRandom() * weightSum < weight) lightPos = candidate;
		}
	}

	if (weightSum <= 0.0 || ivec3(lightPos) == ivec3(floor(origin))) return 1.0;

	ivec3 hitCell, hitFace;
	float hitDistance;
	uint hitWord;

	return giTrace(origin, normalize(lightPos - origin), ivec3(lightPos), hitCell, hitFace, hitDistance, hitWord) ? 0.0 : 1.0;
}

float giCellSphere(ivec3 cell, out vec3 centre) {
	centre = vec3(cell) + 0.5;

	if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, ivec3(voxelVolumeSize)))) return 0.765625;

	uint bounds = texelFetch(voxelBoxSampler, ivec3(cell.x * 2 + 1, cell.yz), 0).r;

	if (bounds == 0u) return 0.765625;

	uvec3 boundBits = uvec3(bounds & 511u, (bounds >> 9u) & 511u, bounds >> 18u);
	vec3 low = vec3(findLSB(boundBits)) * 0.125;
	vec3 high = vec3(findMSB(boundBits)) * 0.125;

	centre = vec3(cell) + (low + high) * 0.5;

	return dot(high - low, high - low) * 0.255;
}

float giCellCone(ivec3 cell, vec3 origin, out vec3 axis) {
	vec3 centre;
	float radiusSquared = giCellSphere(cell, centre);
	vec3 toCentre = centre - origin;
	float sineSquared = min(radiusSquared / dot(toCentre, toCentre), 1.0);

	axis = normalize(toCentre);

	return sineSquared / (1.0 + sqrt(1.0 - sineSquared));
}

float giCosinePdf(vec3 normal, vec3 direction) {
	float facing = max(dot(normal, direction), 0.0);

	return facing * facing > 0.001999 ? (2.0 * facing * facing - 0.001999) / (6.27690212 * sqrt(facing * facing - 0.001999)) : 0.0;
}

vec3 giConeDirection(vec3 axis, float size, vec2 point) {
	vec3 tangent = normalize(cross(axis, abs(axis.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
	float cosine = 1.0 - point.x * size;
	float angle = point.y * 6.28318530718;

	return axis * cosine + (tangent * cos(angle) + cross(axis, tangent) * sin(angle)) * sqrt(max(1.0 - cosine * cosine, 0.0));
}

float giLampWeight(vec3 origin, vec3 normal, uint data, out vec3 lampCentre) {
	lampCentre = vec3(data & 1023u, (data >> 10u) & 1023u, (data >> 20u) & 1023u) + 0.5;

	vec3 toLamp = lampCentre - origin;
	float lampDistance = length(toLamp);
	float level = float(data >> 30u);

	if (lampDistance < 1.2375 || dot(normal, toLamp) + 0.875 <= 0.0) return 0.0;

	return level * level * clamp(1.0 - lampDistance / 16.0, 0.0, 1.0) / (lampDistance * lampDistance + 0.5);
}

float giLampPick(vec3 origin, vec3 normal, out ivec3 lampCell) {
	ivec3 gridCell = ivec3(origin) >> 4;
	ivec3 gridSize = ivec3(voxelVolumeSize) >> 4;
	float total = 0.0;

	lampCell = ivec3(-1);

	for (int i = 0; i < 27; i++) {
		ivec3 cell = gridCell + ivec3(i % 3, (i / 3) % 3, i / 9) - 1;

		if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, gridSize)) || distance(clamp(origin, vec3(cell) * 16.0, vec3(cell) * 16.0 + 16.0), origin) >= 16.0) continue;

		uint stored = min(texelFetch(lightGridSampler, ivec3(cell.x * 16, cell.yz), 0).r, 15u);

		for (uint slot = 0u; slot < stored; slot++) {
			vec3 lampCentre;
			float weight = giLampWeight(origin, normal, texelFetch(lightGridSampler, ivec3(cell.x * 16 + 1 + int(slot), cell.yz), 0).r, lampCentre);

			total += weight;

			if (weight > 0.0 && giRandom() * total < weight) lampCell = ivec3(lampCentre);
		}
	}

	return total;
}

vec2 giLampDensity(vec3 origin, vec3 normal, vec3 directionA, vec3 directionB, ivec3 lampCell) {
	ivec3 gridCell = ivec3(origin) >> 4;
	ivec3 gridSize = ivec3(voxelVolumeSize) >> 4;
	vec2 density = vec2(0.0);

	for (int i = 0; i < 27; i++) {
		ivec3 cell = gridCell + ivec3(i % 3, (i / 3) % 3, i / 9) - 1;

		if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, gridSize)) || distance(clamp(origin, vec3(cell) * 16.0, vec3(cell) * 16.0 + 16.0), origin) >= 16.0) continue;

		uint stored = min(texelFetch(lightGridSampler, ivec3(cell.x * 16, cell.yz), 0).r, 15u);

		for (uint slot = 0u; slot < stored; slot++) {
			vec3 lampCentre;
			float weight = giLampWeight(origin, normal, texelFetch(lightGridSampler, ivec3(cell.x * 16 + 1 + int(slot), cell.yz), 0).r, lampCentre);

			if (weight <= 0.0) continue;

			vec3 toLamp = lampCentre - origin;
			float reach = dot(toLamp, toLamp) > 1.5625 ? sqrt(dot(toLamp, toLamp) - 1.5625) : -2.0;
			bool chosen = ivec3(lampCentre) == lampCell;

			if (!chosen && dot(directionA, toLamp) < reach && dot(directionB, toLamp) < reach) continue;

			vec3 axis;
			float size = giCellCone(ivec3(lampCentre), origin, axis);

			density += weight / (6.28318530718 * size) * vec2(dot(directionA, axis) >= 1.0 - size, chosen || dot(directionB, axis) >= 1.0 - size);
		}
	}

	return density;
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

	vec4 floodfill = (frameCounter & 1) == 0 ? texelFetch(floodfillSamplerCopy, giHitOwner, 0) : texelFetch(floodfillSampler, giHitOwner, 0);
	vec3 blockLight = floodfill.a > 1.5 && (floodfill.a < 199.5 || floodfill.a > 216.5) ? pow(floodfill.rgb, vec3(1.0 / FLOODFILL_RADIUS)) * FLOODFILL_BRIGHTNESS * (giVoxelNonFull(hitWord) ? 5.0 : 1.0) : vec3(0.0);

	vec4 cached = giCacheFetch(hitCell + hitFace);
	vec3 ambient = cached.a < 0.0 ? vec3(0.0) : ambientCol * cached.a * clamp(skyLight * 8.0, 0.0, 1.0) + cached.rgb * GI_MULTI_BOUNCE;
	vec3 lighting = mix(ambient, lightCol * (0.15 + skyLight * 0.85), sunLight) + blockLight;
	vec3 surface = giVoxelAlbedo(hitWord) * vanillaDiffuse;

	giHitBlockLuminance = dot(surface * blockLight, vec3(0.2126, 0.7152, 0.0722));

	return surface * lighting;
}

vec4 giTraceRadiance(vec3 origin, vec3 direction, vec3 lightDirection) {
	vec4 radiance = vec4(0.0, 0.0, 0.0, 1.0);
	ivec3 hitCell, hitFace;
	float hitDistance;
	uint hitWord;

	if (giTrace(origin, direction, ivec3(-1), hitCell, hitFace, hitDistance, hitWord)) radiance = vec4(giHitRadiance(hitCell, hitFace, origin + direction * hitDistance, hitWord, lightDirection), 0.0);

	radiance.rgb += giPassLight;

	return radiance;
}

vec2 giLampedDirections(vec3 origin, vec3 normal, out vec3 direction, out vec3 lampDirection) {
	ivec3 lampCell;
	float lampTotal = giLampPick(origin, normal, lampCell);

	direction = giCosineDirection(normal);
	lampDirection = direction;

	if (lampTotal <= 0.0) return vec2(1.0, 0.0);

	vec3 lampAxis;
	float lampSize = giCellCone(lampCell, origin, lampAxis);
	float pointX = giRandom();
	float pointY = giRandom();

	lampDirection = giConeDirection(lampAxis, lampSize, vec2(pointX, pointY));

	vec2 lampDensity = giLampDensity(origin, normal, direction, lampDirection, lampCell) / lampTotal;
	float cosineDensity = giCosinePdf(normal, direction);
	float lampCosineDensity = giCosinePdf(normal, lampDirection);

	return vec2(lampDensity.x > 0.0 ? cosineDensity / (cosineDensity + lampDensity.x) : 1.0, lampCosineDensity > 0.0 ? lampCosineDensity / (lampCosineDensity + lampDensity.y) : 0.0);
}
