#include "/lib/common.glsl"

#ifdef FSH

in vec2 texCoord;

uniform int isEyeInWater;
uniform int frameCounter;

uniform float far;
uniform float frameTimeCounter, rainStrength;
uniform float timeAngle, timeBrightness, wetness;
uniform float isRainyBiome;
uniform float blindFactor;
#if MC_VERSION >= 11900
uniform float darknessFactor;
#endif

#if MC_VERSION >= 12104
uniform float isPaleGarden;
#endif

uniform ivec2 eyeBrightnessSmooth;

uniform vec3 cameraPosition;
uniform vec3 skyColor;

uniform sampler2D colortex0, colortex7;
uniform sampler2D depthtex0;
uniform sampler2D noisetex;

uniform mat4 gbufferProjection, gbufferProjectionInverse;
uniform mat4 gbufferModelView, gbufferModelViewInverse;

#ifdef WORLD_SPACE_REFLECTIONS
uniform float near;
uniform float shadowFade;

uniform sampler2D shadowtex1, colortex12;
uniform usampler3D voxelGiSampler, voxelBoxSampler, quadPoolSampler, lightGridSampler, voxelSpriteSampler;
uniform sampler3D giCacheSampler, giCacheSamplerCopy;

uniform mat4 shadowProjection, shadowModelView;
#endif

const vec2 sunRotationData = vec2(cos(sunPathRotation * 0.01745329251994), -sin(sunPathRotation * 0.01745329251994));
float fractTimeAngle = fract(timeAngle - 0.25);
float ang = (fractTimeAngle + (cos(fractTimeAngle * 3.14159265358979) * -0.5 + 0.5 - fractTimeAngle) / 3.0) * 6.28318530717959;
vec3 sunVec = normalize((gbufferModelView * vec4(vec3(-sin(ang), cos(ang) * sunRotationData) * 2000.0, 1.0)).xyz);

vec3 upVec = normalize(gbufferModelView[1].xyz);

float eBS = eyeBrightnessSmooth.y / 240.0;
float caveFactor = mix(clamp((cameraPosition.y - 56.0) / 16.0, float(sign(isEyeInWater)), 1.0), 1.0, eBS);
float sunVisibility = clamp((dot( sunVec, upVec) + 0.15) * 3.0, 0.0, 1.0);
float moonVisibility = clamp((dot(-sunVec, upVec) + 0.15) * 3.0, 0.0, 1.0);

#ifdef WORLD_SPACE_REFLECTIONS
vec3 lightVec = sunVec * ((timeAngle < 0.5325 || timeAngle > 0.9675) ? 1.0 : -1.0);
#endif

#include "/lib/util/bayerDithering.glsl"
#include "/lib/util/ToView.glsl"
#include "/lib/util/ToWorld.glsl"
#include "/lib/color/lightColor.glsl"
#include "/lib/atmosphere/sky.glsl"
#include "/lib/atmosphere/skyCapture.glsl"
#include "/lib/atmosphere/fog.glsl"
#include "/lib/pbr/raytracer.glsl"

#ifdef WORLD_SPACE_REFLECTIONS
#include "/lib/util/transformMacros.glsl"
#include "/lib/util/ToShadow.glsl"
#include "/lib/vx/voxelization.glsl"

vec4 giCacheFetch(ivec3 cell) {
    if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, ivec3(voxelVolumeSize)))) return vec4(0.0, 0.0, 0.0, -1.0);

    return (frameCounter & 1) == 0 ? texelFetch(giCacheSamplerCopy, cell, 0) : texelFetch(giCacheSampler, cell, 0);
}

#include "/lib/util/ToScreen.glsl"
#endif

vec2 getRainRipples(vec2 pos) {
	vec2 cell = floor(pos);
	vec2 slope = vec2(0.0);

	for (int i = 0; i < 9; i++) {
		vec2 dropCell = cell + vec2(i % 3 - 1, i / 3 - 1);
		vec2 hashCell = mod(dropCell, 256.0);
		vec3 random = fract(sin(vec3(dot(hashCell, vec2(127.1, 311.7)), dot(hashCell, vec2(269.5, 183.3)), dot(hashCell, vec2(419.2, 371.9)))) * 43758.5453);
		float age = fract(frameTimeCounter * 1.2 + random.z);
		vec2 offset = pos - dropCell - random.xy;
		float dist = length(offset);
		float front = dist - age * 0.8;
		float ring = max(1.0 - abs(front) * 5.0, 0.0);

		slope += offset / max(dist, 0.0001) * sin(front * 31.4) * ring * ring * (1.0 - age);
	}

	return slope;
}

void main() {
	ivec2 pixel = ivec2(gl_FragCoord.xy);
	vec3 color = texelFetch(colortex0, pixel, 0).rgb;
	float puddle = wetness * isRainyBiome > 0.001 ? texelFetch(colortex7, pixel, 0).r : 0.0;
	float z0 = puddle > 0.001 ? texelFetch(depthtex0, pixel, 0).r : 0.0;

	if (puddle > 0.001 && z0 > 0.56) {
		vec3 viewPos = ToView(vec3(texCoord, z0));
		vec3 worldPos = ToWorld(viewPos);
		vec3 nViewPos = normalize(viewPos);

		vec2 ripples = getRainRipples((worldPos.xz + cameraPosition.xz) * 4.0) * rainStrength * (1.0 - smoothstep(16.0, 40.0, length(worldPos)));
		vec3 normal = normalize(mat3(gbufferModelView) * vec3(-ripples.x * 0.15, 1.0, -ripples.y * 0.15));

		float fresnel = pow3(clamp(1.0 + dot(normal, nViewPos), 0.0, 1.0)) * 0.85 + 0.15;

		float dither = Bayer8(gl_FragCoord.xy);
		#ifdef TAA
		dither = fract(dither + frameTimeCounter * 16.0);
		#endif

		float border = 0.0;
		vec4 reflectPos = rayTrace(depthtex0, viewPos, normal, dither, fresnel, border, 6, 30, 0.1, 2.0);
		border = clamp(13.333 * (1.0 - border), 0.0, 1.0);

		#ifdef WORLD_SPACE_REFLECTIONS
		if (border > 0.0) {
			float reflectDepth = texture2D(depthtex0, reflectPos.xy).r;
			vec3 reflectEnd = ToView(reflectPos.xyz);
			float reflectBehind = ToView(vec3(reflectPos.xy, reflectDepth)).z - reflectEnd.z;

			border *= float(reflectDepth < 1.0 && reflectBehind > -0.25 && reflectBehind < 0.25 + 0.5 * length(reflectEnd - viewPos));
		}
		#endif

		vec3 reflectedViewPos = reflect(nViewPos, normal);
		float reflectedHardMixFactor = 0.0;
		vec3 reflectedWorldPos = mat3(gbufferModelViewInverse) * reflectedViewPos;
		vec3 reflection = (reflectedWorldPos.y > 0.0 ? getSkyCapture(reflectedWorldPos) : getAtmosphere(reflectedViewPos, reflectedWorldPos, reflectedHardMixFactor)) * (1.0 - blindFactor);

		#ifdef WORLD_SPACE_REFLECTIONS
		vec3 worldReflection = normalize(mat3(gbufferModelViewInverse) * reflectedViewPos);

		if (border < 1.0 && worldReflection.y > 0.0) {
			ivec3 hitCell, hitFace;
			float traceDistance;
			uint hitWord;
			vec3 voxelOrigin = worldToVoxel(worldPos) + vec3(0.0, 0.05, 0.0);

			if (voxelReflectionHit(voxelOrigin, worldReflection, hitCell, hitFace, traceDistance, hitWord)) {
				vec2 screenUv;
				float screenWeight = voxelHitScreen(depthtex0, voxelOrigin + worldReflection * traceDistance, hitFace, screenUv);

				reflection = pow(giHitRadiance(hitCell, hitFace, voxelOrigin + worldReflection * traceDistance, hitWord, mat3(gbufferModelViewInverse) * lightVec, 1.0) + giPassLight, vec3(1.0 / 2.2)) * (1.0 - blindFactor);

				if (screenWeight < 1.0) {
					vec3 hitWorldPos = voxelToWorld(voxelOrigin + worldReflection * traceDistance);
					vec3 hitViewPos = mat3(gbufferModelView) * hitWorldPos + gbufferModelView[3].xyz;
					float hitHardMixFactor = 0.0;

					Fog(reflection, hitViewPos, getAtmosphere(hitViewPos, hitWorldPos, hitHardMixFactor), z0);
				}

				if (screenWeight > 0.0) reflection = mix(reflection, texture2D(colortex0, screenUv).rgb, screenWeight);
			} else {
				bool farGeometry;
				vec3 farHit = farReflectionTrace(depthtex0, viewPos, reflectedViewPos, max(traceDistance, 4.0), dither, farGeometry);
				if (farHit.z > 0.0) reflection = mix(reflection, texture2D(colortex0, farHit.xy).rgb, farHit.z);

				if (farHit.z == 0.0 || !farGeometry) {
					vec4 probeHit = farProbeTrace(worldPos, worldReflection, max(traceDistance, 4.0), dither);
					reflection = mix(reflection, probeHit.rgb, probeHit.a);
				}
			}
		}
		#endif

		#if MC_VERSION >= 11900
		reflection *= 1.0 - darknessFactor;
		#endif
		reflection = mix(reflection, texture2D(colortex0, reflectPos.xy).rgb, border);

		float atmosphereHardMixFactor = 0.0;
		vec3 atmosphereColor = getAtmosphere(viewPos, worldPos, atmosphereHardMixFactor);
		Fog(reflection, viewPos, atmosphereColor, z0);

		color = mix(color, reflection, fresnel * puddle);
	}

	/* DRAWBUFFERS:07 */
	gl_FragData[0].rgb = color;
	gl_FragData[1] = vec4(0.0);
}

#endif

#ifdef VSH

out vec2 texCoord;

void main() {
	texCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;

	gl_Position = ftransform();
}

#endif
