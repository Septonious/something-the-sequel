#define COMPOSITE_1

// Settings //
#include "/lib/common.glsl"

#ifdef FSH

// Varyings //
in vec2 texCoord;

#if defined VL || (defined LPV_FOG && defined VX_SUPPORT)
flat in float closedSpaceFactor;
#endif

// Uniforms //
uniform sampler2D colortex0;

#if defined WATER_FOG || defined VL || (defined LPV_FOG && defined VX_SUPPORT)
uniform sampler2D depthtex0;
uniform int isEyeInWater;
uniform float frameTimeCounter;
uniform float blindFactor;
#if MC_VERSION >= 11900
uniform float darknessFactor;
#endif
uniform mat4 gbufferProjectionInverse;
uniform ivec2 eyeBrightnessSmooth;
uniform float timeBrightness, wetness;
#endif

#if defined VL || (defined LPV_FOG && defined VX_SUPPORT)
uniform sampler2D noisetex;
uniform int frameCounter;
uniform vec3 cameraPosition;
uniform mat4 gbufferModelViewInverse;

float eBS = clamp(float(eyeBrightnessSmooth.y) / 240.0, 0.0, 1.0);
float caveFactor = mix(clamp((cameraPosition.y - 56.0) / 16.0, float(sign(isEyeInWater)), 1.0), 1.0, eBS);
#endif

#if defined WATER_FOG || defined VL
uniform float timeAngle, shadowFade;
uniform mat4 gbufferModelView;
#endif

#ifdef WATER_FOG
uniform float eyeAltitude;
#endif

#ifdef VL
uniform mat4 shadowModelView, shadowProjection;
uniform sampler2DShadow shadowtex0;
uniform vec3 skyColor;

#if defined SHADOW_COLOR && defined VL_COLOR_SHADOWS
uniform sampler2D shadowtex1, shadowcolor0;
#endif

#endif

#if defined LPV_FOG && defined VX_SUPPORT
uniform sampler3D floodfillSampler, floodfillSamplerCopy;

#ifdef GI
uniform sampler3D fogVisibilitySampler;
#endif
#endif

// Global Variables //
#if defined WATER_FOG || defined VL
const vec2 sunRotationData = vec2(cos(sunPathRotation * 0.01745329251994), -sin(sunPathRotation * 0.01745329251994));
float fractTimeAngle = fract(timeAngle - 0.25);
float ang = (fractTimeAngle + (cos(fractTimeAngle * 3.14159265358979) * -0.5 + 0.5 - fractTimeAngle) / 3.0) * 6.28318530717959;
vec3 sunVec = normalize((gbufferModelView * vec4(vec3(-sin(ang), cos(ang) * sunRotationData) * 2000.0, 1.0)).xyz);
vec3 upVec = normalize(gbufferModelView[1].xyz);
#endif

#ifdef WATER_FOG
float waterEyeBrightness = eyeBrightnessSmooth.y / 240.0;
float waterCaveFactor = mix(clamp((eyeAltitude - 56.0) / 16.0, float(sign(isEyeInWater)), 1.0), 1.0, sqrt(waterEyeBrightness));
float waterSunVisibility = clamp(dot(sunVec, upVec) + 0.1, 0.0, 0.25) * 4.0;
#endif

#ifdef VL
float sunVisibility = clamp((dot(sunVec, upVec) + 0.15) * 3.0, 0.0, 1.0);
vec3 lightVec = sunVec * ((timeAngle < 0.5325 || timeAngle > 0.9675) ? 1.0 : -1.0);
#endif

// Includes //
#if defined VL || (defined LPV_FOG && defined VX_SUPPORT)
#include "/lib/util/transformMacros.glsl"
#endif

#if defined WATER_FOG || defined VL || (defined LPV_FOG && defined VX_SUPPORT)
#include "/lib/util/ToView.glsl"
#endif

#ifdef WATER_FOG
#define eBS waterEyeBrightness
#define caveFactor waterCaveFactor
#define sunVisibility waterSunVisibility
#include "/lib/water/waterFog.glsl"
#undef eBS
#undef caveFactor
#undef sunVisibility
#endif

#ifdef VL
#include "/lib/color/lightColor.glsl"
#if defined VC_SHADOWS && defined VOLUMETRIC_CLOUDS
#include "/lib/lighting/cloudShadows.glsl"
#endif
#endif

#if defined LPV_FOG && defined VX_SUPPORT
#include "/lib/vx/voxelization.glsl"
#endif

#if defined VL || (defined LPV_FOG && defined VX_SUPPORT)
#include "/lib/atmosphere/volumetrics.glsl"
#endif

// Main //
void main() {
    vec3 color = texture2D(colortex0, texCoord).rgb;
    #ifdef GI
         color = max(color, vec3(0.0));
    #endif
         color = pow(color, vec3(2.2));

    #ifdef WATER_FOG
    if (isEyeInWater == 1) {
        float z0 = texture2D(depthtex0, texCoord).r;
        vec3 viewPos = ToView(vec3(texCoord, z0));

        vec3 colorMult = vec3(1.0);
        vec4 waterFog = getWaterFog(colorMult, viewPos);
        color *= colorMult;
        color = mix(sqrt(color), sqrt(waterFog.rgb), waterFog.a);
        color *= color;
    }
    #endif

    #if defined VL || (defined LPV_FOG && defined VX_SUPPORT)
    if (isEyeInWater != 2) {
        float dither = texture2D(noisetex, gl_FragCoord.xy / 512.0).b;
        #ifdef TAA
              dither = fract(dither + 1.61803398875 * mod(float(frameCounter), 3600.0));
        #endif

        computeVolumetricLight(color, dither);
    }
    #endif

    /* DRAWBUFFERS:0 */
    gl_FragData[0] = vec4(color, 1.0);
}

#endif

//**//**//**//**//**//**//**//**//**//**//**//**//**//**//

#ifdef VSH

// Varyings //
out vec2 texCoord;

#if defined VL || (defined LPV_FOG && defined VX_SUPPORT)
flat out float closedSpaceFactor;

uniform sampler2D depthtex0;
uniform int isEyeInWater;
uniform float far, near;
uniform vec3 cameraPosition;
uniform ivec2 eyeBrightnessSmooth;

float eBS = clamp(float(eyeBrightnessSmooth.y) / 240.0, 0.0, 1.0);
float caveFactor = mix(clamp((cameraPosition.y - 56.0) / 16.0, float(sign(isEyeInWater)), 1.0), 1.0, eBS);

//Five fixed screen-space probes detect a roof or nearby walls without
//changing the fog multiplier at individual sky/geometry pixel boundaries.
float getEnclosedDepth(vec2 uv) {
    float depth = texture2D(depthtex0, uv).r;
    float linearDepth = near * far / max(far - depth * (far - near), 0.0001);
    return 1.0 - smoothstep(12.0, 72.0, linearDepth);
}

float getClosedSpaceFactor() {
    float depthEnclosure = getEnclosedDepth(vec2(0.50, 0.78)) * 0.30;
          depthEnclosure += getEnclosedDepth(vec2(0.25, 0.63)) * 0.19;
          depthEnclosure += getEnclosedDepth(vec2(0.75, 0.63)) * 0.19;
          depthEnclosure += getEnclosedDepth(vec2(0.32, 0.40)) * 0.16;
          depthEnclosure += getEnclosedDepth(vec2(0.68, 0.40)) * 0.16;

    float skyOcclusion = 1.0 - smoothstep(0.25, 0.85, eBS);
    float roofEnclosure = smoothstep(0.30, 0.75, depthEnclosure) * (0.25 + 0.75 * skyOcclusion);
    float caveEnclosure = (1.0 - caveFactor) * (0.50 + 0.50 * skyOcclusion);
    float ambientEnclosure = skyOcclusion * 0.35;
    return clamp(max(max(roofEnclosure, caveEnclosure), ambientEnclosure), 0.0, 1.0);
}
#endif

// Main //
void main() {
    texCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    gl_Position = ftransform();

    #if defined VL || (defined LPV_FOG && defined VX_SUPPORT)
    closedSpaceFactor = getClosedSpaceFactor();
    #endif
}

#endif
