#include "/lib/common.glsl"

#define COMPOSITE4

#ifdef FSH

// VSH Data //
in vec2 texCoord;

// Uniforms //
uniform float viewWidth, viewHeight;

uniform sampler2D colortex0;
uniform sampler2D colortex2;
uniform sampler2D depthtex1;

#ifdef TAA
uniform sampler2D colortex7;
uniform sampler2D depthtex0;

uniform vec3 cameraPosition, previousCameraPosition;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferPreviousProjection;
uniform mat4 gbufferPreviousModelView, gbufferModelViewInverse;
#endif

// Pipeline Options //
const bool colortex2Clear = false;

// Includes //
#ifdef TAA
#include "/lib/antialiasing/jitter.glsl"
#include "/lib/util/reprojection.glsl"

#define colortex1 colortex0
#include "/lib/antialiasing/taa.glsl"
#undef colortex1
#endif

// Main //
void main() {
    vec3 color = texture2DLod(colortex0, texCoord, 0.0).rgb;
    vec4 temporalHistory = vec4(0.0, color);

    #ifdef TAA
    float depth = texture2D(depthtex1, texCoord).r;
    float depth0 = texture2D(depthtex0, texCoord).r;

    if (depth0 > 0.56 && texture2D(colortex7, texCoord).b < 0.2) depth = depth0;

    temporalHistory = TemporalAA(color, 0.0, depth);
    color = temporalHistory.gba;
    #endif

    // colortex3: stable HDR scene used by bloom and later color processing.
    // colortex2: HDR TAA history.
    /* DRAWBUFFERS:32 */
    gl_FragData[0] = vec4(color, 1.0);
    gl_FragData[1] = temporalHistory;
}

#endif

//**//**//**//**//**//**//**//**//**//**//**//**//**//**//

#ifdef VSH

out vec2 texCoord;

void main() {
    texCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    gl_Position = ftransform();
}

#endif
