vec3 farReflectionTrace(sampler2D depthSampler, vec3 origin, vec3 direction, float startDistance, float dither, out bool geometry) {
	float growth = pow(max(far * 1.5 / startDistance, 1.0), 1.0 / 12.0);
	float lastDistance = startDistance;
	float rayDistance = startDistance * pow(growth, dither);
	vec3 skyHit = vec3(0.0);

	geometry = false;

	for (int i = 0; i < 12; i++) {
		vec3 point = origin + direction * rayDistance;
		vec3 screen = ToScreen(point);

		if (point.z > -near || clamp(screen.xy, 0.0, 1.0) != screen.xy) break;

		float depth = texture2D(depthSampler, screen.xy).r;
		vec2 edge = min(screen.xy, 1.0 - screen.xy);

		if (depth >= 1.0) skyHit = vec3(screen.xy, clamp(min(edge.x, edge.y) * 20.0, 0.0, 1.0));

		if (depth > 0.56 && depth < 1.0 && point.z < ToView(vec3(screen.xy, depth)).z) {
			float low = lastDistance;
			float high = rayDistance;

			for (int j = 0; j < 4; j++) {
				float middle = (low + high) * 0.5;
				vec3 middlePoint = origin + direction * middle;
				vec3 middleScreen = ToScreen(middlePoint);

				if (middlePoint.z < ToView(vec3(middleScreen.xy, texture2D(depthSampler, middleScreen.xy).r)).z) high = middle;
				else low = middle;
			}

			vec3 hitPoint = origin + direction * high;
			vec3 hitScreen = ToScreen(hitPoint);
			float hitDepth = texture2D(depthSampler, hitScreen.xy).r;

			if (hitDepth > 0.56 && hitDepth < 1.0 && ToView(vec3(hitScreen.xy, hitDepth)).z - hitPoint.z < rayDistance - lastDistance) {
				vec2 hitEdge = min(hitScreen.xy, 1.0 - hitScreen.xy);

				geometry = true;

				return vec3(hitScreen.xy, clamp(min(hitEdge.x, hitEdge.y) * 20.0, 0.0, 1.0));
			}
		}

		lastDistance = rayDistance;
		rayDistance *= growth;
	}

	return skyHit;
}

vec4 farProbeTrace(vec3 origin, vec3 direction, float startDistance, float dither) {
	float growth = pow(max(far * 1.5 / startDistance, 1.0), 1.0 / 16.0);
	float lastDistance = startDistance;
	float rayDistance = startDistance * pow(growth, dither);

	for (int i = 0; i < 16; i++) {
		vec3 point = origin + direction * rayDistance;
		float pointDistance = length(point);
		vec4 entry = texelFetch(colortex12, farProbeTexel(point / pointDistance), 0);
		float behind = pointDistance - length(entry.yzw - cameraPosition);

		if (entry.x > 0.5 && behind > 0.0 && behind < rayDistance - lastDistance) {
			uint colour = uint(entry.x) - 1u;

			return vec4(pow8(vec3(colour >> 16u, (colour >> 8u) & 255u, colour & 255u) / 255.0) * 256.0, 1.0);
		}

		lastDistance = rayDistance;
		rayDistance *= growth;
	}

	return vec4(0.0);
}
