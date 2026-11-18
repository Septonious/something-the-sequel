#include "/lib/common.glsl"

#ifdef FSH

// VSH Data //
in vec2 texCoord;

// Uniforms //
uniform int isEyeInWater;
uniform int frameCounter;

#ifdef OVERWORLD
uniform int worldDay;
uniform int moonPhase;

#ifdef VOLUMETRIC_CLOUDS
uniform int worldTime;
#endif

#if defined VOLUMETRIC_CLOUDS || defined CIRRUS_CLOUDS
uniform float shadowFade;
#endif

uniform float timeAngle, timeBrightness, wetness;

#if MC_VERSION >= 12104
uniform float isPaleGarden;
#endif

uniform vec3 skyColor;
#endif

uniform float far, near;

uniform float blindFactor, nightVision;
#if MC_VERSION >= 11900
uniform float darknessFactor;
#endif

uniform float frameTimeCounter;

uniform ivec2 eyeBrightnessSmooth;

uniform vec3 cameraPosition;

uniform sampler2D colortex0;
uniform sampler2D depthtex0;
uniform sampler2D noisetex;

#if defined VOLUMETRIC_CLOUDS || defined CIRRUS_CLOUDS
uniform sampler2D colortex8;
#endif

#ifdef SCREEN_SPACE_SHADOWS
uniform sampler2D colortex9;
uniform mat4 gbufferProjection;
#endif

#if AO_TYPE > 0
uniform sampler2D colortex10;
uniform sampler2D colortex12;
#endif

#ifdef GI
uniform sampler2D colortex11;
uniform sampler2D colortex13;
uniform sampler2D colortex14;
uniform sampler2D colortex15;

uniform usampler3D voxelGiSampler;
uniform sampler3D floodfillSampler, floodfillSamplerCopy;
uniform sampler3D giCacheSampler, giCacheSamplerCopy;
#endif


uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjectionInverse;

// Pipeline Options //
const bool colortex4Clear = false;
const bool colortex5Clear = false;
const bool colortex6Clear = false;

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
#include "/lib/util/ToView.glsl"
#include "/lib/util/ToWorld.glsl"

#ifdef OVERWORLD
#include "/lib/color/lightColor.glsl"
#include "/lib/atmosphere/sky.glsl"

#ifdef ROUND_SUN_MOON
#include "/lib/atmosphere/sunMoon.glsl"
#endif

#if defined VOLUMETRIC_CLOUDS || defined CIRRUS_CLOUDS
#include "/lib/atmosphere/volumetricClouds.glsl"
#endif

#ifdef CIRRUS_CLOUDS
#include "/lib/atmosphere/cirrusClouds.glsl"
#endif

#ifdef STARS
#include "/lib/atmosphere/stars.glsl"
#endif

#ifdef OVERWORLD_NEBULA
#include "/lib/atmosphere/overworldNebula.glsl"
#endif
#endif

#include "/lib/atmosphere/fog.glsl"

#ifdef SCREEN_SPACE_SHADOWS
#include "/lib/lighting/screenSpaceShadows.glsl"
#endif

#ifdef GI
#include "/lib/vx/voxelization.glsl"
#include "/lib/vx/giVoxel.glsl"
#include "/lib/vx/giNormal.glsl"
#include "/lib/vx/giApply.glsl"
#endif

// Main //
void main() {
    vec3 color = texture2D(colortex0, texCoord).rgb;
    #ifdef GI
         color = max(color, vec3(0.0));
    #endif

    float z0 = texture2D(depthtex0, texCoord).r;
	vec3 viewPos = ToView(vec3(texCoord, z0));
	vec3 worldPos = ToWorld(viewPos);

    #if defined OVERWORLD
	float atmosphereHardMixFactor = 0.0;
    vec3 atmosphereColor = getAtmosphere(viewPos, worldPos, atmosphereHardMixFactor);
	#elif defined NETHER
	vec3 atmosphereColor = netherColSqrt.rgb * 0.25;
	#elif defined END
	vec3 atmosphereColor = endLightCol * 0.15;
	#endif


    //Volumetric Clouds
	vec4 vc = vec4(0.0);
	vec2 cloudRange = vec2(VC_DISTANCE);

	float blueNoiseDither = texture2D(noisetex, gl_FragCoord.xy / 512.0).b;
	#ifdef TAA
		  blueNoiseDither = fract(blueNoiseDither + 1.61803398875 * mod(float(frameCounter), 3600.0));
	#endif

	#ifdef VOLUMETRIC_CLOUDS
	computeVolumetricClouds(vc, atmosphereColor, z0, blueNoiseDither, cloudRange);
	#endif

	//Sky
    if (z0 == 1.0) {
	#if defined OVERWORLD || defined END
	vec3 nViewPos = normalize(viewPos);

	float VoU = dot(nViewPos, upVec);
	float VoS = clamp(dot(nViewPos, sunVec), 0.0, 1.0);
	float VoM = clamp(dot(nViewPos, -sunVec), 0.0, 1.0);
	#endif
        color = atmosphereColor * (1.0 + Bayer8(gl_FragCoord.xy) / 32.0);

		float occlusion = vc.a;
		float nebulaFactor = 0.0;

		#ifdef CIRRUS_CLOUDS
		vec4 cirrus = vec4(0.0);
		drawCirrusClouds(cirrus, atmosphereColor, worldPos, nViewPos, caveFactor, occlusion);
		#endif

		if (VoU > 0.0) {
			#ifdef OVERWORLD_NEBULA
			drawOverworldNebula(color, worldPos, VoU, VoM, blueNoiseDither, caveFactor, nebulaFactor);
			#endif
		}

		#ifdef ROUND_SUN_MOON
		drawSunMoon(color, worldPos, nViewPos, VoU, VoS, VoM, caveFactor, occlusion);
		#endif

		#ifdef STARS
		drawStars(color, worldPos, sunVec, VoU, VoS, caveFactor, nebulaFactor, atmosphereHardMixFactor, occlusion, 0.6);
		#endif

		#ifdef CIRRUS_CLOUDS
		color = fmix(color, cirrus.rgb, cirrus.a);
		#endif

		color *= 1.0 - blindFactor;
		#if MC_VERSION >= 11900
		color *= 1.0 - darknessFactor;
		#endif
    }

	if (z0 < 1.0) {
		#ifdef GI
		float giScreenShadow = 1.0;
		float giOcclusion = 0.0;
		#endif

		#ifdef SCREEN_SPACE_SHADOWS
		vec3 directLighting = texture2D(colortex9, texCoord).rgb;
		if (z0 > 0.56 && maxOf(directLighting) > 0.0) {
			float screenSpaceShadow = getScreenSpaceShadow(viewPos, blueNoiseDither);
			#ifdef GI
			giScreenShadow = screenSpaceShadow;
			#endif
			if (screenSpaceShadow < 1.0) color = pow(max(pow(color, vec3(2.2)) - directLighting * (1.0 - screenSpaceShadow), vec3(0.0)), vec3(1.0 / 2.2));
		}
		#endif

		#if AO_TYPE > 0
		vec3 occludableLighting = texture2D(colortex10, texCoord).rgb;
		if (z0 > 0.56 && maxOf(occludableLighting) > 0.0) {
			vec2 aoSize = vec2(textureSize(colortex12, 0));
			vec2 aoPos = (texCoord * vec2(textureSize(depthtex0, 0)) - 0.5) * 0.5;
			vec2 aoBase = floor(aoPos) - 1.0;
			float occlusion = 0.0;
			float occlusionWeight = 0.0;

			for (int i = 0; i < 16; i++) {
				vec2 aoTap = aoBase + vec2(i % 4, i / 4);
				vec2 aoData = texture2D(colortex12, (clamp(aoTap, vec2(0.0), aoSize - 1.0) + 0.5) / aoSize).rg;
				vec2 tent = max(1.0 - abs(aoTap - aoPos) * 0.5, 0.0);
				float weight = tent.x * tent.y / (0.01 + abs(aoData.g + viewPos.z) / -viewPos.z);
				occlusion += aoData.r * weight;
				occlusionWeight += weight;
			}

			#ifdef GI
			giOcclusion = occlusion / occlusionWeight;
			#endif

			color = pow(max(pow(color, vec3(2.2)) - occludableLighting * (occlusion / occlusionWeight), vec3(0.0)), vec3(1.0 / 2.2));
		}
		#endif

		#ifdef GI
		vec3 giReceptor = texture2D(colortex13, texCoord).rgb;
		     giReceptor *= giReceptor;
		float giFade = clamp(maxOf(abs(worldPos) / (voxelVolumeSize * 0.5)), 0.0, 1.0);
		      giFade = 1.0 - giFade * giFade;

		#if GI_DEBUG == 7
		if (texCoord.x > 0.5) giFade = 0.0;
		#endif

		if (z0 > 0.56 && maxOf(giReceptor) > 0.0 && giFade > 0.0) {
			vec3 giSurface = texture2D(colortex11, texCoord).rgb;
			vec2 giSize = vec2(textureSize(colortex14, 0));
			vec2 giPos = (texCoord * vec2(textureSize(depthtex0, 0)) - (float(GI_RESOLUTION / 4) + 0.5)) / float(GI_RESOLUTION);
			vec2 giBase = floor(giPos) - 1.0;
			vec4 gi = vec4(0.0);
			float giBlockLuminance = 0.0;
			float giWeight = 0.0;
			int giPixelFace = giFace(giSurface.r > 0.5 ? vec3(0.0, 1.0, 0.0) : mat3(gbufferModelViewInverse) * giViewNormal(texCoord, viewPos));

			for (int i = 0; i < 16; i++) {
				vec2 giTap = giBase + vec2(i % 4, i / 4);
				vec2 giCoord = (clamp(giTap, vec2(0.0), giSize - 1.0) + 0.5) / giSize;
				vec2 tent = max(1.0 - abs(giTap - giPos) * 0.5, 0.0);
				vec4 giTapSurface = texture2D(colortex15, giCoord);
				float weight = tent.x * tent.y / (0.01 + abs(abs(giTapSurface.r) + viewPos.z) / -viewPos.z) * (giStoredFace(giTapSurface) == giPixelFace ? 1.0 : 0.0001);
				gi += texture2D(colortex14, giCoord) * weight;
				giBlockLuminance += giTapSurface.b * weight;
				giWeight += weight;
			}
			gi /= giWeight;
			giBlockLuminance /= giWeight;

			#if GI_DEBUG == 4
			gi = vec4(0.0);
			#endif

			float receptorWeight = max(1.0 - giSurface.b * giScreenShadow - (1.0 - giSurface.r * 0.35) * giOcclusion, 0.0) * giFade;
			float lightWeight = max(1.0 - (1.0 - giSurface.r * 0.35) * giOcclusion, 0.0) * giFade;
			vec3 giDelta = giAmbientDelta(gi, giSurface.g, viewPos);

			#if GI_DEBUG == 8
			color = vec3(gi.a);
			#elif GI_DEBUG == 9
			color = pow(gi.rgb, vec3(1.0 / 2.2));
			#elif GI_DEBUG == 10
			color = vec3(giBlockVisibility);
			#else
			color = pow(max(pow(color, vec3(2.2)) + max(giReceptor * receptorWeight * giDelta, 0.0) + giReceptor * (lightWeight - receptorWeight) * giBlockLight(gi, giBlockLuminance), vec3(0.0)), vec3(1.0 / 2.2));
			#endif
		}
		#endif

		Fog(color, viewPos, atmosphereColor, z0);
	}

	//Volumetric Clouds
	#if defined VOLUMETRIC_CLOUDS || defined END_CLOUDY_FOG
	vc.rgb = pow(max(vc.rgb, vec3(0.0)), vec3(1.0 / 2.2));

	color = mix(color, vc.rgb, vc.a);
	#endif

	#ifdef GI
	#if GI_DEBUG == 1
	if (z0 < 1.0) color = texture2D(colortex13, texCoord).rgb;
	#elif GI_DEBUG == 2
	if (z0 < 1.0) color = vec3(texture2D(colortex11, texCoord).g);
	#elif GI_DEBUG == 3
	if (z0 < 1.0) color = vec3(texture2D(colortex11, texCoord).b);
	#elif GI_DEBUG == 12
	if (z0 < 1.0) color = texture2D(colortex14, texCoord).rgb;
	#elif GI_DEBUG == 11
	if (z0 < 1.0) {
		ivec3 giCacheCell = ivec3(worldToVoxel(worldPos) + mat3(gbufferModelViewInverse) * giViewNormal(texCoord, viewPos) * 0.5);
		vec4 giCache = (frameCounter & 1) == 0 ? texelFetch(giCacheSamplerCopy, giCacheCell, 0) : texelFetch(giCacheSampler, giCacheCell, 0);

		color = giCache.a < 0.0 ? vec3(1.0, 0.0, 1.0) : vec3(giCache.a);
	}
	#elif GI_DEBUG == 5 || GI_DEBUG == 6
	if (z0 < 1.0) {
		vec3 giVoxelPos = worldToVoxel(worldPos + normalize(worldPos) * 0.05);
		color = vec3(0.0);

		if (isInsideVoxelVolume(giVoxelPos)) {
			uint giWord = texelFetch(voxelGiSampler, ivec3(giVoxelPos), 0).r;

			#if GI_DEBUG == 5
			color = pow(giVoxelAlbedo(giWord), vec3(1.0 / 2.2));
			#else
			color = vec3(giVoxelNonFull(giWord), giVoxelSeeThrough(giWord), giVoxelPlant(giWord));
			#endif
		}
	}
	#endif
	#endif

    /* DRAWBUFFERS:0456 */
    gl_FragData[0].rgb = color;
	gl_FragData[1].rgb = pow(color.rgb, vec3(0.125)) * 0.5;
	gl_FragData[2] = vc;
	gl_FragData[3].rg = cloudRange;
}

#endif


//**//**//**//**//**//**//**//**//**//**//**//**//**//**//


#ifdef VSH

// VSH Data //
out vec2 texCoord;

// Main //
void main() {
	//Coords
	texCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;

	//Position
	gl_Position = ftransform();
}

#endif
