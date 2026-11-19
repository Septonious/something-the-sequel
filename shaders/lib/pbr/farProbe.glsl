const ivec2 farProbeSize = ivec2(1024, 512);

ivec2 farProbeTexel(vec3 direction) {
	vec2 coord = vec2(fract(atan(direction.z, direction.x) / 6.2831853), acos(clamp(direction.y, -1.0, 1.0)) / 3.1415927);

	return min(ivec2(coord * vec2(farProbeSize)), farProbeSize - 1);
}
