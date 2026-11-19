#include "/lib/common.glsl"

#ifdef GI_CACHE_TRACE
layout (local_size_x = 16, local_size_y = 1, local_size_z = 32) in;

#if VOXEL_VOLUME_SIZE == 128
const ivec3 workGroups = ivec3(2, 64, 4);
#elif VOXEL_VOLUME_SIZE == 192
const ivec3 workGroups = ivec3(3, 96, 6);
#else
const ivec3 workGroups = ivec3(4, 128, 8);
#endif
#else
layout (local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

#if VOXEL_VOLUME_SIZE == 128
const ivec3 workGroups = ivec3(16, 8, 16);
#elif VOXEL_VOLUME_SIZE == 192
const ivec3 workGroups = ivec3(24, 12, 24);
#else
const ivec3 workGroups = ivec3(32, 16, 32);
#endif
#endif

uniform int frameCounter;

uniform float timeAngle, timeBrightness, wetness;
uniform float shadowFade;

uniform vec3 cameraPosition, previousCameraPosition;

uniform sampler2D shadowtex1;

uniform sampler3D floodfillSampler, floodfillSamplerCopy;
uniform sampler3D giCacheSampler, giCacheSamplerCopy;
uniform usampler3D voxelGiSampler;
uniform usampler3D voxelBoxSampler;
uniform usampler3D quadPoolSampler;
uniform usampler3D lightGridSampler;

writeonly uniform image3D gi_cache_img, gi_cache_img_copy;

#ifdef LPV_FOG
layout(r16f) uniform image3D fog_visibility_img;
#endif

uniform mat4 shadowProjection;
uniform mat4 shadowModelView;

const vec2 sunRotationData = vec2(cos(sunPathRotation * 0.01745329251994), -sin(sunPathRotation * 0.01745329251994));
float fractTimeAngle = fract(timeAngle - 0.25);
float ang = (fractTimeAngle + (cos(fractTimeAngle * 3.14159265358979) * -0.5 + 0.5 - fractTimeAngle) / 3.0) * 6.28318530717959;
vec3 sunDirection = normalize(vec3(-sin(ang), cos(ang) * sunRotationData));
float sunVisibility = clamp((sunDirection.y + 0.15) * 3.0, 0.0, 1.0);
vec3 lightDirection = sunDirection * ((timeAngle < 0.5325 || timeAngle > 0.9675) ? 1.0 : -1.0);

#include "/lib/util/transformMacros.glsl"
#include "/lib/util/ToShadow.glsl"
#include "/lib/color/lightColor.glsl"
#include "/lib/vx/voxelization.glsl"
#include "/lib/vx/giVoxel.glsl"

vec4 giCacheFetch(ivec3 cell) {
	ivec3 previousCell = ivec3(vec3(cell) - floor(previousCameraPosition) + floor(cameraPosition));

	if (any(lessThan(previousCell, ivec3(0))) || any(greaterThanEqual(previousCell, ivec3(voxelVolumeSize)))) return vec4(0.0, 0.0, 0.0, -1.0);

	return (frameCounter & 1) == 0 ? texelFetch(giCacheSampler, previousCell, 0) : texelFetch(giCacheSamplerCopy, previousCell, 0);
}

#include "/lib/vx/giTrace.glsl"

bool giSolid(ivec3 cell) {
	if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, ivec3(voxelVolumeSize)))) return false;

	uint word = texelFetch(voxelGiSampler, cell, 0).r;

	return word != 0u && !(giVoxelNonFull(word) || giVoxelSeeThrough(word) || giVoxelPlant(word) || giVoxelLeaves(word));
}

void main() {
	ivec3 pos = ivec3(gl_GlobalInvocationID);

	#ifdef GI_CACHE_TRACE
	pos.x = pos.x * 4 + ((-(pos.y * 3 + pos.z * 5 + frameCounter)) & 3);
	#endif

	vec4 cache = giCacheFetch(pos);

	if (any(isnan(cache)) || any(isinf(cache))) cache = vec4(0.0, 0.0, 0.0, -1.0);

	cache = clamp(cache, vec4(0.0, 0.0, 0.0, -1.0), vec4(64.0, 64.0, 64.0, 1.0));

	#ifdef GI_CACHE_TRACE
	if (giSolid(pos)) return;

	giSeed = uint(pos.x) * 1973u + uint(pos.y) * 9277u + uint(pos.z) * 26699u + uint(frameCounter) * 4099u;
	giRandom();

	ivec3 face = ivec3(0);
	float faces = 0.0;

	for (int i = 0; i < 6; i++) {
		ivec3 offset = ivec3(i == 0, i == 1, i == 2) - ivec3(i == 3, i == 4, i == 5);

		uint neighbour = any(lessThan(pos + offset, ivec3(0))) || any(greaterThanEqual(pos + offset, ivec3(voxelVolumeSize))) ? 0u : texelFetch(voxelGiSampler, pos + offset, 0).r;

		if (neighbour != 0u && !giVoxelSeeThrough(neighbour) && !giVoxelPlant(neighbour)) {
			faces += 1.0;

			if (giRandom() * faces < 1.0) face = offset;
		}
	}

	if (faces > 0.0) {
		vec3 normal = -vec3(face);
		vec3 origin = vec3(pos) + 0.5 - normal * 0.45;
		vec3 direction, lampDirection;
		vec2 weights = giLampedDirections(origin, normal, direction, lampDirection);
		vec4 current = giTraceRadiance(origin, direction, lightDirection) * weights.x;

		if (weights.y > 0.0) current += giTraceRadiance(origin, lampDirection, lightDirection) * weights.y;

		cache = cache.a < 0.0 ? current : mix(cache, current, 0.03125);
	} else {
		cache = vec4(0.0, 0.0, 0.0, -1.0);
	}

	#ifdef LPV_FOG
	vec3 fogLight = (frameCounter & 1) == 0 ? texelFetch(floodfillSamplerCopy, pos, 0).rgb : texelFetch(floodfillSampler, pos, 0).rgb;

	if (maxOf(fogLight) > 0.0001) {
		float offsetX = giRandom();
		float offsetY = giRandom();
		float offsetZ = giRandom();
		ivec3 fogSlot = ivec3(mod(vec3(pos) + floor(cameraPosition), voxelVolumeSize));
		float fogVisibility = giBlockVisibility(vec3(pos) + 0.05 + vec3(offsetX, offsetY, offsetZ) * 0.9);
		float fogHistory = imageLoad(fog_visibility_img, fogSlot).r;

		imageStore(fog_visibility_img, fogSlot, vec4(fogHistory >= 0.0 && fogHistory <= 1.0 ? mix(fogHistory, fogVisibility, 0.0625) : fogVisibility));
	}
	#endif
	#else
	if (giSolid(pos)) cache = vec4(0.0, 0.0, 0.0, -1.0);
	#endif

	if ((frameCounter & 1) == 0) {
		imageStore(gi_cache_img_copy, pos, cache);
	} else {
		imageStore(gi_cache_img, pos, cache);
	}}
