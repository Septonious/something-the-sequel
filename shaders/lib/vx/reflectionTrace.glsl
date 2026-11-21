float voxelHitScreen(sampler2D depthSampler, vec3 hitPos, ivec3 hitFace, out vec2 hitUv) {
	vec3 worldHit = voxelToWorld(hitPos);
	vec3 viewHit = mat3(gbufferModelView) * worldHit + gbufferModelView[3].xyz;
	vec3 screen = ToScreen(viewHit);

	hitUv = screen.xy;

	if (dot(vec3(hitFace), worldHit) >= 0.0 || viewHit.z > -near || clamp(screen.xy, 0.0, 1.0) != screen.xy) return 0.0;

	vec2 edge = min(screen.xy, 1.0 - screen.xy);

	return float(abs(ToView(vec3(screen.xy, texture2D(depthSampler, screen.xy).r)).z - viewHit.z) < 0.25 - viewHit.z * 0.01) * clamp(min(edge.x, edge.y) * 20.0, 0.0, 1.0);
}

bool voxelReflectionHit(vec3 origin, vec3 direction, out ivec3 hitCell, out ivec3 hitFace, out float hitDistance, out uint hitWord) {
	vec3 directionSign = vec3(greaterThanEqual(direction, vec3(0.0))) * 2.0 - 1.0;
	vec3 delta = 1.0 / max(abs(direction), vec3(0.00001));
	ivec3 cell = ivec3(floor(origin));
	ivec3 cellStep = ivec3(directionSign);
	vec3 rayInverse = directionSign * delta;
	vec3 side = (vec3(cell) + max(directionSign, 0.0) - origin) * rayInverse;
	uint frontFaces = (directionSign.x > 0.0 ? 1u : 2u) | (directionSign.y > 0.0 ? 4u : 8u) | (directionSign.z > 0.0 ? 16u : 32u);
	const ivec3 brickShift = ivec3(2, 1, 2);
	const vec3 brickSize = vec3(4.0, 2.0, 4.0);
	ivec3 brickCount = ivec3(voxelVolumeSize) >> brickShift;
	int brickOffset = int(voxelVolumeSize.x) * 3;
	uint brickMask = 0u;
	bool first = true;
	bool advance = false;
	bool sameBrick = false;

	hitCell = cell;
	hitFace = ivec3(0);
	hitDistance = 0.0;
	hitWord = 0u;
	giPassLight = vec3(0.0);

	vec3 local = vec3(0.0);
	int i = 0;

	for (int rounds = 0; rounds < 768; rounds++) {
		int pending = 0;

		for (; i < 384; i++) {
			if (advance) {
				ivec3 previousCell = cell;

				if (side.x < side.y && side.x < side.z) {
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

				sameBrick = (cell >> brickShift) == (previousCell >> brickShift);
			}

			advance = true;

			if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, ivec3(voxelVolumeSize)))) return false;

			if (!sameBrick) {
				ivec3 brick = cell >> brickShift;

				brickMask = texelFetch(voxelSpriteSampler, ivec3(brickOffset + brick.x, brick.yz), 0).r;

				if (brickMask == 0u) {
					pending = 1;

					break;
				}

				sameBrick = true;
			}

			if (((brickMask >> uint((cell.x & 3) | ((cell.z & 3) << 2) | ((cell.y & 1) << 4))) & 1u) == 0u) {
				first = false;

				continue;
			}

			hitWord = texelFetch(voxelGiSampler, cell, 0).r;

			bool skipFirst = first && !giVoxelNonFull(hitWord);

			first = false;

			if (skipFirst || hitWord == 0u) continue;

			if (giVoxelSeeThrough(hitWord) || giVoxelPlant(hitWord)) {
				vec4 passFloodfill = (frameCounter & 1) == 0 ? texelFetch(floodfillSamplerCopy, cell, 0) : texelFetch(floodfillSampler, cell, 0);

				if (passFloodfill.a > 1.5 && (passFloodfill.a < 199.5 || passFloodfill.a > 216.5)) giPassLight += pow(passFloodfill.rgb, vec3(1.0 / FLOODFILL_RADIUS)) * (FLOODFILL_BRIGHTNESS * 0.28 * (min(side.x, min(side.y, side.z)) - hitDistance));

				continue;
			}

			if (giVoxelNonFull(hitWord)) {
				uint bounds = texelFetch(voxelBoxSampler, ivec3(cell.x * 2 + 1, cell.yz), 0).r;

				if (bounds == 0u) continue;

				uvec3 boundBits = uvec3(bounds & 511u, (bounds >> 9u) & 511u, bounds >> 18u);

				local = (origin - vec3(cell)) * 32.0;

				vec3 boundA = (vec3(findLSB(boundBits)) * 4.0 - local) * rayInverse;
				vec3 boundB = (vec3(findMSB(boundBits)) * 4.0 - local) * rayInverse;
				vec3 boundEnter = min(boundA, boundB);
				vec3 boundLeave = max(boundA, boundB);
				float boundExit = min(boundLeave.x, min(boundLeave.y, boundLeave.z));

				if (max(boundEnter.x, max(boundEnter.y, boundEnter.z)) > boundExit || boundExit < hitDistance * 32.0 - 0.01) continue;

				pending = 2;

				break;
			}

			hitCell = cell;
			giHitOwner = cell;

			return true;
		}

		if (pending == 0) return false;

		if (pending == 1) {
			ivec3 brick = cell >> brickShift;

			vec3 brickSide = ((vec3(brick) + max(directionSign, 0.0)) * brickSize - origin) * rayInverse;
			vec3 brickDelta = delta * brickSize;
			ivec3 axis = ivec3(0);

			for (int j = 0; j < 160; j++) {
				if (brickSide.x < brickSide.y && brickSide.x < brickSide.z) {
					hitDistance = brickSide.x;
					brickSide.x += brickDelta.x;
					brick.x += cellStep.x;
					axis = ivec3(1, 0, 0);
				} else if (brickSide.y < brickSide.z) {
					hitDistance = brickSide.y;
					brickSide.y += brickDelta.y;
					brick.y += cellStep.y;
					axis = ivec3(0, 1, 0);
				} else {
					hitDistance = brickSide.z;
					brickSide.z += brickDelta.z;
					brick.z += cellStep.z;
					axis = ivec3(0, 0, 1);
				}

				if (any(lessThan(brick, ivec3(0))) || any(greaterThanEqual(brick, brickCount))) return false;

				brickMask = texelFetch(voxelSpriteSampler, ivec3(brickOffset + brick.x, brick.yz), 0).r;

				if (brickMask != 0u) break;
			}

			cell = clamp(ivec3(floor(origin + direction * hitDistance)), brick << brickShift, (brick << brickShift) + ivec3(3, 1, 3));
			side = (vec3(cell) + max(directionSign, 0.0) - origin) * rayInverse;
			hitFace = -cellStep * axis;
			first = false;
			sameBrick = true;
			advance = false;

			continue;
		}

		uint node = texelFetch(voxelBoxSampler, ivec3(cell.x * 2, cell.yz), 0).r;
		vec3 nearestNormal = vec3(0.0);
		float nearest = 1000000.0;

		for (int j = 0; j < 128 && node != 0u; j++) {
			uvec4 quad = texelFetch(quadPoolSampler, ivec3((node - 1u) & 63u, ((node - 1u) >> 6u) & 63u, (node - 1u) >> 12u), 0);

			node = quad.a & 2097151u;

			uvec2 cutout = uvec2(quad.b, (quad.g >> 18u) | (((quad.r >> 21u) & 1023u) << 14u) | ((quad.a >> 21u) << 24u));

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
		}

		if (nearestNormal != vec3(0.0)) {
			vec3 dominant = abs(nearestNormal);

			hitDistance = nearest / 32.0;
			hitFace = ivec3(sign(nearestNormal) * step(max(dominant.yzx, dominant.zxy), dominant));
			hitCell = ivec3(floor(origin + direction * hitDistance + normalize(nearestNormal) * 0.01)) - hitFace;
			giHitOwner = cell;

			return true;
		}

		i++;
	}

	return false;
}
