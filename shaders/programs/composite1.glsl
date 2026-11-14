#define COMPOSITE_1

// Settings //
#include "/lib/common.glsl"

#ifdef FSH

// Varyings //
in vec2 texCoord;

// Uniforms //
uniform sampler2D colortex0;

#if defined VL || (defined LPV_FOG && defined VX_SUPPORT)
uniform sampler2D depthtex0, noisetex;
uniform int frameCounter, isEyeInWater;
uniform float far, near, frameTimeCounter;
uniform float blindFactor;
#if MC_VERSION >= 11900
uniform float darknessFactor;
#endif
uniform vec3 cameraPosition;
uniform mat4 gbufferProjectionInverse, gbufferModelViewInverse;
uniform ivec2 eyeBrightnessSmooth;
uniform float timeBrightness, wetness;

float eBS = clamp(float(eyeBrightnessSmooth.y) / 240.0, 0.0, 1.0);
float caveFactor = mix(clamp((cameraPosition.y - 56.0) / 16.0, float(sign(isEyeInWater)), 1.0), 1.0, eBS);
#endif

#ifdef VL
uniform float timeAngle, shadowFade;
uniform mat4 gbufferModelView, shadowModelView, shadowProjection;
uniform sampler2D shadowtex0;
uniform vec3 skyColor;

#if defined SHADOW_COLOR && defined VL_COLOR_SHADOWS
uniform sampler2D shadowtex1, shadowcolor0;
#endif

#endif

#if defined LPV_FOG && defined VX_SUPPORT
uniform sampler3D floodfillSampler, floodfillSamplerCopy;
#endif

// Global Variables //
#ifdef VL
const vec2 sunRotationData = vec2(cos(sunPathRotation * 0.01745329251994), -sin(sunPathRotation * 0.01745329251994));
float fractTimeAngle = fract(timeAngle - 0.25);
float ang = (fractTimeAngle + (cos(fractTimeAngle * 3.14159265358979) * -0.5 + 0.5 - fractTimeAngle) / 3.0) * 6.28318530717959;
vec3 sunVec = normalize((gbufferModelView * vec4(vec3(-sin(ang), cos(ang) * sunRotationData) * 2000.0, 1.0)).xyz);
vec3 upVec = normalize(gbufferModelView[1].xyz);
float sunVisibility = clamp((dot(sunVec, upVec) + 0.15) * 3.0, 0.0, 1.0);
vec3 lightVec = sunVec * ((timeAngle < 0.5325 || timeAngle > 0.9675) ? 1.0 : -1.0);
#endif

// Includes //
#if defined VL || (defined LPV_FOG && defined VX_SUPPORT)
#include "/lib/util/transformMacros.glsl"
#include "/lib/util/ToView.glsl"
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

// Main //
void main() {
    texCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    gl_Position = ftransform();
}

#endif
