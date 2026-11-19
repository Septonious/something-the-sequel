#define GBUFFERS_TERRAIN

#include "/lib/common.glsl"

#ifdef FSH

// VSH Data //
in vec4 color;
in vec3 normal;
in vec2 texCoord, lmCoord;
flat in int mat;

// Uniforms //
uniform int isEyeInWater;
uniform int frameCounter;

uniform float frameTimeCounter;
uniform float viewWidth, viewHeight;
uniform float blindFactor, nightVision;
#if MC_VERSION >= 11900
uniform float darknessFactor;
#endif

#ifdef OVERWORLD
uniform float wetness;
uniform float shadowFade;
uniform float timeAngle, timeBrightness;

#ifdef RAIN_PUDDLES
uniform float isRainyBiome;
#endif
#endif

uniform ivec2 eyeBrightnessSmooth;
uniform vec3 cameraPosition;
uniform vec4 lightningBoltPosition;

uniform sampler2D texture, noisetex;

#ifdef VX_SUPPORT
uniform sampler3D floodfillSampler, floodfillSamplerCopy;
uniform usampler3D voxelSampler;

#if AO_TYPE == 0
in float aoFull;

uniform usampler3D aoLatticeSampler;
#endif
#endif

uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 shadowProjection;
uniform mat4 shadowModelView;

// Global Variables //
#if defined OVERWORLD
const vec2 sunRotationData = vec2(cos(sunPathRotation * 0.01745329251994), -sin(sunPathRotation * 0.01745329251994));
float fractTimeAngle = fract(timeAngle - 0.25);
float ang = (fractTimeAngle + (cos(fractTimeAngle * 3.14159265358979) * -0.5 + 0.5 - fractTimeAngle) / 3.0) * 6.28318530717959;
vec3 sunVec = normalize((gbufferModelView * vec4(vec3(-sin(ang), cos(ang) * sunRotationData) * 2000.0, 1.0)).xyz);
#elif defined END
const vec2 sunRotationData = vec2(cos(sunPathRotation * 0.01745329251994), -sin(sunPathRotation * 0.01745329251994));
vec3 sunVec = normalize((gbufferModelView * vec4(1.0, sunRotationData * 2000.0, 1.0)).xyz);
#else
vec3 sunVec = vec3(0.0);
#endif

vec3 upVec = normalize(gbufferModelView[1].xyz);
vec3 eastVec = normalize(gbufferModelView[0].xyz);

#ifdef OVERWORLD
float eBS = eyeBrightnessSmooth.y / 240.0;
float caveFactor = mix(clamp((cameraPosition.y - 56.0) / 16.0, float(sign(isEyeInWater)), 1.0), 1.0, eBS);
float sunVisibility = clamp((dot( sunVec, upVec) + 0.15) * 3.0, 0.0, 1.0);
float moonVisibility = clamp((dot(-sunVec, upVec) + 0.15) * 3.0, 0.0, 1.0);
vec3 lightVec = sunVec * ((timeAngle < 0.5325 || timeAngle > 0.9675) ? 1.0 : -1.0);
#endif

// Includes //
#include "/lib/util/bayerDithering.glsl"
#include "/lib/util/transformMacros.glsl"
#include "/lib/util/ToNDC.glsl"
#include "/lib/util/ToWorld.glsl"
#include "/lib/util/ToShadow.glsl"
#include "/lib/color/lightColor.glsl"
#include "/lib/pbr/ggx.glsl"

#ifdef VX_SUPPORT
#include "/lib/vx/blocklightColor.glsl"
#include "/lib/vx/voxelization.glsl"
#endif

#include "/lib/lighting/lightning.glsl"
#include "/lib/lighting/shadows.glsl"

#if AO_TYPE == 0 && defined VX_SUPPORT
#include "/lib/lighting/aoLattice.glsl"
#endif

#include "/lib/lighting/gbuffersLighting.glsl"

#ifdef GENERATED_EMISSION
#include "/lib/pbr/generatedPBR.glsl"
#endif

// Main //
void main() {
    vec4 albedo = texture2D(texture, texCoord) * color;
    if (!(albedo.a > 0.1)) discard;

    vec2 lightmap = clamp(lmCoord, vec2(0.0), vec2(1.0));
    vec3 newNormal = normal;
    vec3 screenPos = vec3(gl_FragCoord.xy / vec2(viewWidth, viewHeight), gl_FragCoord.z);
    vec3 viewPos = ToNDC(screenPos);
    vec3 worldPos = ToWorld(viewPos);

	float leaves = float(mat == 10314);
	float saplings = float(mat == 10317);
	float foliage = float(mat >= 10304 && mat <= 10319 || mat >= 10035 && mat <= 10040) * (1.0 - leaves) * (1.0 - saplings);
	float subsurface = leaves + foliage * 0.6 + saplings * 0.4;
    float emission = 0.0, smoothness = 0.0, metalness = 0.0, f0 = 0.0, ao = 1.0, porosity = 0.5, parallaxShadow = 0.0;
    vec3 fresnel3 = vec3(0.0);

	if (foliage > 0.5) {
		float foliageNormalDistance = min(1.0, length(viewPos.xz) / shadowDistance);
		newNormal = normalize(upVec) * (1.0 - foliageNormalDistance * 0.5 * timeBrightness);
	}

	float NoU = clamp(dot(newNormal, upVec), -1.0, 1.0);
	float NoL = clamp(dot(newNormal, lightVec), 0.0, 1.0);
	float NoE = clamp(dot(newNormal, eastVec), -1.0, 1.0);

	#if defined GENERATED_EMISSION || defined GENERATED_SPECULAR
	float generatedEmission = emission;
	float generatedSmoothness = 0.0;
	float generatedMetalness = 0.0;
	float generatedSubsurface = subsurface;

	generateIPBR(albedo, worldPos, viewPos, lightmap, NoU, generatedEmission, generatedSmoothness, generatedMetalness, generatedSubsurface, mat);
	
	#ifdef GENERATED_EMISSION
	emission = max(emission, generatedEmission);
	#endif

	#ifdef GENERATED_SPECULAR
	smoothness = max(smoothness, generatedSmoothness);
	metalness = max(metalness, generatedMetalness);
	#endif

	subsurface = max(subsurface, generatedSubsurface);
	if (smoothness > 0.01 && f0 <= 0.0) f0 = 0.04;
	#endif

	#if defined RAIN_PUDDLES && defined OVERWORLD
	float puddle = 0.0;
	float rainWetness = wetness * isRainyBiome * clamp(lightmap.y * 15.0 - 14.0, 0.0, 1.0) * (1.0 - leaves - foliage - saplings) * float(emission < 0.01);

	if (rainWetness > 0.001) {
		vec3 worldNormal = mat3(gbufferModelViewInverse) * normal;
		vec2 puddleCoord = worldPos.xz + cameraPosition.xz;
		float puddleNoise = texture2D(noisetex, puddleCoord / 320.0).g * 0.65 + texture2D(noisetex, puddleCoord / 96.0 + 0.37).g * 0.35;
		float puddleThreshold = rainWetness * PUDDLE_AMOUNT;
		puddle = (1.0 - smoothstep(puddleThreshold - 0.02, puddleThreshold, puddleNoise)) * step(0.99, worldNormal.y);

		float wetDarkening = max(rainWetness * clamp(worldNormal.y * 0.3 + 0.3, 0.0, 0.6), puddle);
		albedo.rgb = pow(albedo.rgb, vec3(1.0 + wetDarkening * 0.35)) * (1.0 - wetDarkening * 0.2);
		smoothness = max(smoothness, wetDarkening * 0.6 + puddle * 0.35);
	}
	#endif

    vec3 shadow = vec3(0.0);
    gbuffersLighting(albedo, screenPos, viewPos, worldPos, newNormal, shadow, lightmap, NoU, NoL, NoE, subsurface, emission, smoothness, parallaxShadow, metalness, f0);

    /* DRAWBUFFERS:0 */
    gl_FragData[0] = albedo;

    #ifdef SCREEN_SPACE_SHADOWS
    /* DRAWBUFFERS:09 */
    gl_FragData[1] = vec4(directLighting * (1.0 - leaves), albedo.a);
    #endif

    #if AO_TYPE > 0
    #ifdef SCREEN_SPACE_SHADOWS
    /* RENDERTARGETS: 0,9,10,11 */
    gl_FragData[2] = vec4(occludableLighting * (1.0 - foliage * 0.35), albedo.a);
    gl_FragData[3] = vec4(foliage, 0.0, 0.0, albedo.a);
    #else
    /* RENDERTARGETS: 0,10,11 */
    gl_FragData[1] = vec4(occludableLighting * (1.0 - foliage * 0.35), albedo.a);
    gl_FragData[2] = vec4(foliage, 0.0, 0.0, albedo.a);
    #endif
    #endif

    #ifdef GI
    /* RENDERTARGETS: 0,9,10,11,13 */
    gl_FragData[1] = vec4(directLighting * (1.0 - leaves), albedo.a);
    gl_FragData[2] = vec4(occludableLighting * (1.0 - foliage * 0.35), albedo.a);
    gl_FragData[3] = vec4(foliage, giSurface, albedo.a);
    gl_FragData[4] = vec4(giReceptor, albedo.a);
    #endif

    #if defined RAIN_PUDDLES && defined OVERWORLD
    vec4 puddleData = vec4(puddle, 0.0, 0.0, 1.0);
    #include "/lib/pbr/puddleTarget.glsl"
    #endif
}

#endif


//**//**//**//**//**//**//**//**//**//**//**//**//**//**//


#ifdef VSH

// VSH Data //
out vec4 color;
out vec3 normal;
out vec2 texCoord, lmCoord;
flat out int mat;

#if AO_TYPE == 0 && defined VX_SUPPORT
out float aoFull;
#endif

// Uniforms //
#ifdef TAA
uniform float viewWidth, viewHeight;
#endif

#if defined WAVING_LEAVES || defined WAVING_PLANTS
uniform float frameTimeCounter, rainStrength;

uniform vec3 cameraPosition;
#endif

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;

// Attributes //
attribute vec4 mc_Entity;

#if defined WAVING_PLANTS || defined WAVING_LEAVES
attribute vec4 mc_midTexCoord;
#endif

#if AO_TYPE == 0 && defined VX_SUPPORT
attribute vec3 at_midBlock;
#endif

// Includes //
#ifdef TAA
#include "/lib/antialiasing/jitter.glsl"
#endif

#if defined WAVING_LEAVES || defined WAVING_PLANTS
#include "/lib/pbr/waving.glsl"
#endif

// Main //
void main() {
	texCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    
	lmCoord = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
	lmCoord = clamp((lmCoord - 0.03125) * 1.06667, vec2(0.0), vec2(0.9333, 1.0));
	
    color = gl_Color;

    normal = normalize(gl_NormalMatrix * gl_Normal);

    mat = int(mc_Entity.x + 0.5);

    #if AO_TYPE == 0 && defined VX_SUPPORT
    aoFull = float(all(greaterThanEqual(abs(at_midBlock), vec3(31.0))));
    #endif

	//Position
	vec4 position = gbufferModelViewInverse * gl_ModelViewMatrix * gl_Vertex;

	#if defined WAVING_PLANTS || defined WAVING_LEAVES
	float istopv = gl_MultiTexCoord0.t < mc_midTexCoord.t ? 1.0 : 0.0;
	position.xyz = getWavingBlocks(position.xyz, istopv, lmCoord.y);
	#endif

	gl_Position = gl_ProjectionMatrix * gbufferModelView * position;

	//TAA jittering
    #ifdef TAA
	gl_Position.xy = TAAJitter(gl_Position.xy, gl_Position.w);
    #endif
}

#endif