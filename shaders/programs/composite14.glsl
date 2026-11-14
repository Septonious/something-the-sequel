#include "/lib/common.glsl"

#define COMPOSITE14

#ifdef FSH

// VSH Data //
in vec2 texCoord;

// Uniforms //
uniform sampler2D colortex0;
uniform sampler2D colortex3;

#ifdef OVERWORLD
uniform int isEyeInWater;
uniform float wetness;
uniform ivec2 eyeBrightnessSmooth;
uniform vec3 cameraPosition;
#endif

// Common Variables //
#ifdef OVERWORLD
float eBS = eyeBrightnessSmooth.y / 240.0;
float caveFactor = mix(clamp((cameraPosition.y - 56.0) / 16.0, float(sign(isEyeInWater)), 1.0), 1.0, eBS);
#endif

// Includes //
#include "/lib/util/bayerDithering.glsl"
#include "/lib/post/tonemap.glsl"

#ifdef BLOOM
#include "/lib/post/getBloom.glsl"
#endif

// Main //
void main() {
    vec3 color = texture2DLod(colortex3, texCoord, 0.0).rgb;

    #ifdef BLOOM
    getBloom(color, texCoord);
    #endif

    color = Uncharted2Tonemap(color * TONEMAP_BRIGHTNESS)
          / Uncharted2Tonemap(vec3(TONEMAP_WHITE_THRESHOLD));
    color = pow(color, vec3(1.0 / 2.2));
    color += (Bayer8(gl_FragCoord.xy) - 0.25) / 128.0;

    /* DRAWBUFFERS:1 */
    gl_FragData[0] = vec4(color, 1.0);
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
