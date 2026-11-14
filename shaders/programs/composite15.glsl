#include "/lib/common.glsl"

#define COMPOSITE15

#ifdef FSH

// VSH Data //
in vec2 texCoord;

// Uniforms //
uniform int frameCounter;

#if defined FXAA || defined MOTION_BLUR
uniform float viewWidth, viewHeight;
uniform float aspectRatio;
#endif

uniform sampler2D depthtex1;
uniform sampler2D colortex1;

#ifdef MOTION_BLUR
uniform float frameTimeCounter;
uniform vec3 cameraPosition, previousCameraPosition;
uniform mat4 gbufferPreviousProjection;
uniform mat4 gbufferPreviousModelView, gbufferModelViewInverse;
uniform mat4 gbufferProjectionInverse;
#endif

// Includes //
#ifdef MOTION_BLUR
#include "/lib/util/bayerDithering.glsl"
#include "/lib/post/motionBlur.glsl"
#endif

#ifdef FXAA
#include "/lib/antialiasing/fxaa.glsl"
#endif

// Main //
void main() {
    vec3 color = texture2DLod(colortex1, texCoord, 0.0).rgb;

    #ifdef FXAA
    color = FXAA311(color);
    #endif

    #ifdef MOTION_BLUR
    float z1 = texture2D(depthtex1, texCoord).r;
    color = getMotionBlur(color, z1);
    #endif

    /* DRAWBUFFERS:1 */
    gl_FragData[0] = vec4(color, 1.0);
}

#endif

//**//**//**//**//**//**//**//**//**//**//**//**//**//**//

#ifdef VSH

// VSH Data //
out vec2 texCoord;

void main() {
    texCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    gl_Position = ftransform();
}

#endif
