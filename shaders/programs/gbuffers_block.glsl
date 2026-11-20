#define GBUFFERS_BLOCK

#include "/lib/common.glsl"

#ifdef FSH

// VSH Data //
in vec4 color;
in vec3 normal;
in vec2 texCoord, lmCoord;

// Uniforms //
uniform int isEyeInWater;
uniform int frameCounter;

uniform float viewWidth, viewHeight;
uniform float blindFactor, nightVision;
#if MC_VERSION >= 11900
uniform float darknessFactor;
#endif

#ifdef OVERWORLD
uniform float frameTimeCounter;

uniform float wetness;
uniform float shadowFade;
uniform float timeAngle, timeBrightness;
#endif

uniform ivec2 eyeBrightnessSmooth;
uniform vec3 cameraPosition;
uniform vec4 lightningBoltPosition;

uniform sampler2D texture, noisetex;

#ifdef VX_SUPPORT
uniform sampler3D floodfillSampler, floodfillSamplerCopy;
uniform usampler3D voxelSampler;
#endif

#ifdef GI
uniform int blockEntityId;

uniform sampler3D giCacheSampler, giCacheSamplerCopy;
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
#include "/lib/lighting/gbuffersLighting.glsl"

#ifdef GI
#include "/lib/vx/giApply.glsl"
#endif

// Main //
void main() {
    vec4 albedo = texture2D(texture, texCoord) * color;

    vec2 lightmap = clamp(lmCoord, vec2(0.0), vec2(1.0));
    vec3 newNormal = normal;
    vec3 screenPos = vec3(gl_FragCoord.xy / vec2(viewWidth, viewHeight), gl_FragCoord.z);
    vec3 viewPos = ToNDC(screenPos);
    vec3 worldPos = ToWorld(viewPos);

	float subsurface = 0.0;
    float emission = 0.0;

	float NoU = clamp(dot(newNormal, upVec), -1.0, 1.0);
	float NoL = clamp(dot(newNormal, lightVec), 0.0, 1.0);
	float NoE = clamp(dot(newNormal, eastVec), -1.0, 1.0);

    vec3 shadow = vec3(0.0);
    gbuffersLighting(albedo, screenPos, viewPos, worldPos, newNormal, shadow, lightmap, NoU, NoL, NoE, subsurface, emission, 0.0, 0.0, 0.0, 0.0);

    #ifdef GI
    if (blockEntityId == 10086) {
        vec3 cachePos = worldToVoxel(worldPos) + mat3(gbufferModelViewInverse) * newNormal * 0.5 - 0.5;
        vec3 cacheBlend = fract(cachePos);
        vec4 gi = vec4(0.0);
        float giWeight = 0.0;

        for (int i = 0; i < 8; i++) {
            ivec3 corner = ivec3(i & 1, (i >> 1) & 1, i >> 2);
            ivec3 cell = ivec3(floor(cachePos)) + corner;

            if (clamp(cell, ivec3(0), ivec3(voxelVolumeSize) - 1) != cell) continue;

            vec4 cached = (frameCounter & 1) == 0 ? texelFetch(giCacheSamplerCopy, cell, 0) : texelFetch(giCacheSampler, cell, 0);
            vec3 side = mix(1.0 - cacheBlend, cacheBlend, vec3(corner));

            if (cached.a < 0.0) continue;

            gi += cached * (side.x * side.y * side.z);
            giWeight += side.x * side.y * side.z;
        }

        if (giWeight > 0.01) {
            float giFade = giVolumeFade(worldPos);

            albedo.rgb = pow(max(pow(albedo.rgb, vec3(2.2)) + giReceptor * giReceptor * giFade * (1.0 - giSurface.y) * giAmbientDelta(gi / giWeight, giSurface.x, 1.0, viewPos), vec3(0.0)), vec3(1.0 / 2.2));
        }
    }
    #endif

    /* DRAWBUFFERS:0 */
    gl_FragData[0] = albedo;

    #ifdef SCREEN_SPACE_SHADOWS
    /* DRAWBUFFERS:09 */
    gl_FragData[1] = vec4(directLighting, albedo.a);
    #endif

    #if AO_TYPE > 0
    #ifdef SCREEN_SPACE_SHADOWS
    /* RENDERTARGETS: 0,9,10,11 */
    gl_FragData[2] = vec4(occludableLighting, albedo.a);
    gl_FragData[3] = vec4(0.0, 0.0, 0.0, albedo.a);
    #else
    /* RENDERTARGETS: 0,10,11 */
    gl_FragData[1] = vec4(occludableLighting, albedo.a);
    gl_FragData[2] = vec4(0.0, 0.0, 0.0, albedo.a);
    #endif
    #endif

    #ifdef GI
    /* RENDERTARGETS: 0,9,10,11,13 */
    gl_FragData[1] = vec4(directLighting, albedo.a);
    gl_FragData[2] = vec4(occludableLighting, albedo.a);
    gl_FragData[3] = vec4(0.0, giSurface, albedo.a);
    gl_FragData[4] = vec4(giReceptor, albedo.a);
    #endif

    #ifdef RAIN_PUDDLES
    vec4 puddleData = vec4(0.0, 0.0, 0.0, albedo.a);
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

// Uniforms //
#ifdef TAA
uniform float viewWidth, viewHeight;
#endif

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;

// Includes //
#ifdef TAA
#include "/lib/antialiasing/jitter.glsl"
#endif

// Main //
void main() {
	texCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    
	lmCoord = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
	lmCoord = clamp((lmCoord - 0.03125) * 1.06667, vec2(0.0), vec2(0.9333, 1.0));
	
    color = gl_Color;

    normal = normalize(gl_NormalMatrix * gl_Normal);

	//Position
	vec4 position = gbufferModelViewInverse * gl_ModelViewMatrix * gl_Vertex;

	gl_Position = gl_ProjectionMatrix * gbufferModelView * position;

	//TAA jittering
    #ifdef TAA
	gl_Position.xy = TAAJitter(gl_Position.xy, gl_Position.w);
    #endif
}

#endif
