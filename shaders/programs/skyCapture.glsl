#include "/lib/common.glsl"

#ifdef FSH

in vec2 texCoord;

uniform int isEyeInWater;
uniform int frameCounter;

uniform float timeAngle, timeBrightness, wetness;
uniform float shadowFade;
uniform float blindFactor;
#if MC_VERSION >= 11900
uniform float darknessFactor;
#endif
uniform float frameTimeCounter;

uniform ivec2 eyeBrightnessSmooth;

uniform vec3 cameraPosition;
uniform vec3 skyColor;

uniform sampler2D noisetex;

#if defined VOLUMETRIC_CLOUDS || defined CIRRUS_CLOUDS
uniform sampler2D cloudNoiseSampler;
uniform float cloudRain;
#endif

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjectionInverse;

const bool colortex8Clear = false;

const vec2 sunRotationData = vec2(cos(sunPathRotation * 0.01745329251994), -sin(sunPathRotation * 0.01745329251994));
float fractTimeAngle = fract(timeAngle - 0.25);
float ang = (fractTimeAngle + (cos(fractTimeAngle * 3.14159265358979) * -0.5 + 0.5 - fractTimeAngle) / 3.0) * 6.28318530717959;
vec3 sunVec = normalize((gbufferModelView * vec4(vec3(-sin(ang), cos(ang) * sunRotationData) * 2000.0, 1.0)).xyz);
vec3 upVec = normalize(gbufferModelView[1].xyz);

float eBS = eyeBrightnessSmooth.y / 240.0;
float caveFactor = mix(clamp((cameraPosition.y - 56.0) / 16.0, float(sign(isEyeInWater)), 1.0), 1.0, eBS);
float sunVisibility = clamp((dot( sunVec, upVec) + 0.15) * 3.0, 0.0, 1.0);
float moonVisibility = clamp((dot(-sunVec, upVec) + 0.15) * 3.0, 0.0, 1.0);
vec3 lightVec = sunVec * ((timeAngle < 0.5325 || timeAngle > 0.9675) ? 1.0 : -1.0);

#include "/lib/util/ToView.glsl"
#include "/lib/color/lightColor.glsl"
#include "/lib/atmosphere/sky.glsl"
#include "/lib/atmosphere/skyCapture.glsl"

#if defined VOLUMETRIC_CLOUDS || defined CIRRUS_CLOUDS
#include "/lib/atmosphere/volumetricClouds.glsl"
#endif

#ifdef CIRRUS_CLOUDS
#include "/lib/atmosphere/cirrusClouds.glsl"
#endif

#ifdef OVERWORLD_NEBULA
#include "/lib/atmosphere/overworldNebula.glsl"
#endif

void main() {
	ivec2 texel = ivec2(gl_FragCoord.xy);
	vec4 capture = texelFetch(colortex8, texel, 0);

	if (any(isnan(capture)) || any(isinf(capture))) capture = vec4(0.0);

	if ((texel.y >> 6) == (frameCounter & 7) || capture.a < 0.5) {
		vec3 worldPos = skyCaptureDirection(gl_FragCoord.xy / skyCaptureSize);
		vec3 viewPos = mat3(gbufferModelView) * worldPos;
		float atmosphereHardMixFactor = 0.0;
		vec3 atmosphereColor = getAtmosphere(viewPos, worldPos, atmosphereHardMixFactor);
		vec3 color = atmosphereColor;
		float dither = fract(texture2D(noisetex, gl_FragCoord.xy / 512.0).b + 1.61803398875 * mod(float(frameCounter), 3600.0));
		vec4 vc = vec4(0.0);
		vec2 cloudRange = vec2(VC_DISTANCE);

		#ifdef VOLUMETRIC_CLOUDS
		computeVolumetricClouds(vc, atmosphereColor, worldPos, VC_CLOUD_MAX_DISTANCE, dither, cloudRange);
		#endif

		#ifdef CIRRUS_CLOUDS
		float occlusion = vc.a;
		vec4 cirrus = vec4(0.0);
		drawCirrusClouds(cirrus, atmosphereColor, worldPos, viewPos, caveFactor, occlusion);
		#endif

		#ifdef OVERWORLD_NEBULA
		float nebulaFactor = 0.0;
		if (worldPos.y > 0.0) drawOverworldNebula(color, worldPos, worldPos.y, clamp(dot(viewPos, -sunVec), 0.0, 1.0), dither, caveFactor, nebulaFactor);
		#endif

		#ifdef CIRRUS_CLOUDS
		color = fmix(color, cirrus.rgb, cirrus.a);
		#endif

		#ifdef VOLUMETRIC_CLOUDS
		color = mix(color, pow(max(vc.rgb, vec3(0.0)), vec3(1.0 / 2.2)), vc.a);
		#endif

		capture = vec4(mix(color, capture.rgb, capture.a * 0.5), 1.0);
	}

	/* RENDERTARGETS: 8 */
	gl_FragData[0] = capture;
}

#endif

#ifdef VSH

out vec2 texCoord;

void main() {
	texCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;

	gl_Position = ftransform();
}

#endif
