float voxelSkipEmpty(vec3 origin, vec3 direction, float start) {
	vec3 position = (origin + direction * start) * 0.25;
	ivec3 brick = ivec3(floor(position));
	ivec3 brickCount = ivec3(voxelVolumeSize) / 4;
	vec3 directionSign = vec3(greaterThanEqual(direction, vec3(0.0))) * 2.0 - 1.0;
	vec3 delta = 4.0 / max(abs(direction), vec3(0.00001));
	vec3 side = (vec3(brick) + max(directionSign, 0.0) - position) * directionSign * delta + start;
	float brickDistance = start;

	for (int i = 0; i < 96; i++) {
		if (any(lessThan(brick, ivec3(0))) || any(greaterThanEqual(brick, brickCount))) return -1.0;
		if (texelFetch(voxelSpriteSampler, ivec3(int(voxelVolumeSize.x) * 3 + brick.x, brick.yz), 0).r != 0u) return brickDistance;

		if (side.x < side.y && side.x < side.z) {
			brickDistance = side.x;
			side.x += delta.x;
			brick.x += int(directionSign.x);
		} else if (side.y < side.z) {
			brickDistance = side.y;
			side.y += delta.y;
			brick.y += int(directionSign.y);
		} else {
			brickDistance = side.z;
			side.z += delta.z;
			brick.z += int(directionSign.z);
		}
	}

	return -1.0;
}

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
	bool hit = giTrace(origin, direction, ivec3(-1), hitCell, hitFace, hitDistance, hitWord);
	vec3 passLight = giPassLight;

	for (int i = 0; i < int(voxelVolumeSize.x) / giTraceSteps && !hit; i++) {
		float restart = voxelSkipEmpty(origin, direction, hitDistance + 0.01);

		if (restart < 0.0) break;

		restart = max(restart - 0.01, hitDistance + 0.01);
		hit = giTrace(origin + direction * restart, direction, ivec3(-1), hitCell, hitFace, hitDistance, hitWord);
		hitDistance += restart;
		passLight += giPassLight;
	}

	giPassLight = passLight;

	return hit;
}
