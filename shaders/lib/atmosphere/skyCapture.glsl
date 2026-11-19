uniform sampler2D colortex8;

const float skyCaptureSize = 512.0;

vec3 skyCaptureDirection(vec2 coord) {
	vec2 square = coord * 2.0 - 1.0;
	vec2 diamond = vec2(square.x + square.y, square.x - square.y) * 0.5;

	return normalize(vec3(diamond.x, 1.0 - abs(diamond.x) - abs(diamond.y), diamond.y));
}

vec2 skyCaptureCoord(vec3 direction) {
	direction.y = max(direction.y, 0.0);

	vec2 diamond = direction.xz / max(abs(direction.x) + direction.y + abs(direction.z), 0.0001);

	return clamp(vec2(diamond.x + diamond.y, diamond.x - diamond.y) * 0.5 + 0.5, 0.5 / skyCaptureSize, 1.0 - 0.5 / skyCaptureSize);
}

vec3 getSkyCapture(vec3 direction) {
	return texture2D(colortex8, skyCaptureCoord(direction)).rgb;
}
