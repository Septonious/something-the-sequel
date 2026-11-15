#include "/lib/common.glsl"

#ifdef FSH

// VSH Data //
in vec2 texCoord;

// Uniforms //
uniform int frameCounter;

uniform sampler2D depthtex0;
uniform sampler2D noisetex;
uniform sampler2D colortex11;

uniform mat4 gbufferProjectionInverse;

// Pipeline Options //
const bool colortex12Clear = false;

// Includes //
#include "/lib/util/bayerDithering.glsl"
#include "/lib/util/ToView.glsl"
#if AO_TYPE == 1
#include "/lib/lighting/ssao.glsl"
#else
#include "/lib/lighting/gtao.glsl"
#endif

// Main //
void main() {
    vec2 viewSize = vec2(textureSize(depthtex0, 0));
    vec2 coord = (floor(texCoord * viewSize - 0.5) + 0.5) / viewSize;
    float z0 = texture2D(depthtex0, coord).r;
    vec3 viewPos = ToView(vec3(coord, z0));
    float occlusion = 0.0;

    if (z0 > 0.56 && z0 < 1.0) {
        float sliceDither = Bayer4(gl_FragCoord.xy);
        float stepDither = texture2D(noisetex, gl_FragCoord.xy / 512.0).b;
        #ifdef TAA
              sliceDither = fract(sliceDither + 1.61803398875 * mod(float(frameCounter), 3600.0));
              stepDither = fract(stepDither + 0.7548776662 * mod(float(frameCounter), 3600.0));
        #endif
        #if AO_TYPE == 1
        occlusion = 1.0 - getSSAO(viewPos, coord, sliceDither, stepDither);
        #else
        occlusion = 1.0 - getGTAO(viewPos, coord, sliceDither, stepDither);
        #endif
    }

    /* RENDERTARGETS: 12 */
    gl_FragData[0] = vec4(occlusion, -viewPos.z, 0.0, 1.0);
}

#endif


//**//**//**//**//**//**//**//**//**//**//**//**//**//**//


#ifdef VSH

// VSH Data //
out vec2 texCoord;

// Main //
void main() {
    texCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;

    gl_Position = ftransform();
}

#endif
