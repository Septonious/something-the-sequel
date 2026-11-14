#include "/lib/common.glsl"

#define COMPOSITE12

#ifdef FSH

in vec2 texCoord;

uniform float viewWidth, viewHeight;
uniform sampler2D colortex0;

#if BLOOM_FILTER_QUALITY == 1
const float bloomWeight[5] = float[5](
    0.2734375,
    0.21875,
    0.109375,
    0.03125,
    0.00390625
);
const int bloomRadius = 4;
#else
const float bloomWeight[4] = float[4](
    0.2734375,
    0.21875,
    0.109375,
    0.03515625
);
const int bloomRadius = 3;
#endif

float BloomTileScale(int index) {
    return 0.5 * exp2(-float(index));
}

vec2 BloomTileOffset(int index) {
    float a = exp2(-float(index));
    return vec2(1.0 - a, float(index & 1) * (1.0 - 0.5 * a));
}

void main() {
    ivec2 texel = ivec2(gl_FragCoord.xy);
    ivec2 viewSize = ivec2(viewWidth, viewHeight);

    float x = min(texCoord.x, 1.0 - 1e-7);
    int tileIndex = int(-log2(1.0 - x));

    float tileScale = BloomTileScale(tileIndex);
    vec2 tileOffset = BloomTileOffset(tileIndex);

    ivec2 boundsMin = ivec2(vec2(viewSize) * tileOffset);
    ivec2 boundsMax = ivec2(
        vec2(viewSize) * (tileOffset + vec2(tileScale))
    );

    if (clamp(texel.y, boundsMin.y, boundsMax.y) != texel.y ||
        tileIndex > 5) {
        discard;
        return;
    }

    vec3 bloom = vec3(0.0);
    float weightSum = 0.0;

    for (int i = -bloomRadius; i <= bloomRadius; ++i) {
        ivec2 position = texel + ivec2(i, 0);

        float weight =
            bloomWeight[abs(i)]
            * float(
                clamp(
                    position.x,
                    boundsMin.x + 2,
                    boundsMax.x - 2
                ) == position.x
            );

        ivec2 safePosition = clamp(
            position,
            ivec2(0),
            viewSize - ivec2(1)
        );

        bloom += texelFetch(colortex0, safePosition, 0).rgb * weight;
        weightSum += weight;
    }

    bloom /= max(weightSum, 1e-6);

    /* DRAWBUFFERS:0 */
    gl_FragData[0] = vec4(bloom, 1.0);
}

#endif

//**//**//**//**//**//**//**//**//**//**//**//**//**//**//

#ifdef VSH

out vec2 texCoord;

void main() {
    texCoord = gl_MultiTexCoord0.xy;
    gl_Position = vec4(gl_Vertex.xy * 2.0 - 1.0, 0.0, 1.0);
}

#endif
