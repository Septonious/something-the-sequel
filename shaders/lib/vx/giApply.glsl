vec3 giAmbientDelta(vec4 gi, float ambientWeight, vec3 viewPos) {
	vec3 skyAmbient = ambientCol * (1.0 - clamp(dot(normalize(viewPos), lightVec), 0.0, 1.0) * 0.5);
	vec3 ambient = skyAmbient * mix(ambientWeight, gi.a * clamp(ambientWeight * 8.0, 0.0, 1.0), GI_SKY_SHADOW) + gi.rgb * GI_STRENGTH;
	vec3 tinted = ambient + gi.rgb * GI_STRENGTH * (GI_COLOR - 1.0);

	return tinted * dot(ambient, vec3(0.2126, 0.7152, 0.0722)) / max(dot(tinted, vec3(0.2126, 0.7152, 0.0722)), 0.000001) - skyAmbient * ambientWeight;
}

vec3 giBlockLight(vec4 gi, float blockLuminance) {
	return gi.rgb * (clamp(blockLuminance / max(dot(gi.rgb, vec3(0.2126, 0.7152, 0.0722)), 0.000001), 0.0, 1.0) * GI_STRENGTH);
}
