#include "/lib/common.glsl"

#ifdef FSH

// VSH Data //
in vec2 texCoord;

// Uniforms //
uniform float viewWidth, viewHeight;

#if BLOOM_TILE_INDEX == 0
uniform sampler2D colortex3;
#else
uniform sampler2D colortex0;
#endif

float BloomTileScale(int index) {
    return 0.5 * exp2(-float(index));
}

vec2 BloomTileOffset(int index) {
    float a = exp2(-float(index));
    return vec2(1.0 - a, float(index & 1) * (1.0 - 0.5 * a));
}

void main() {
    vec2 viewPixelSize = 1.0 / vec2(viewWidth, viewHeight);

    #if BLOOM_TILE_INDEX == 0
    float sourceScale = 1.0;
    vec2 sourceOffset = vec2(0.0);
    #else
    float sourceScale = BloomTileScale(BLOOM_TILE_INDEX - 1);
    vec2 sourceOffset = BloomTileOffset(BLOOM_TILE_INDEX - 1);
    #endif

    vec2 padding = 3.0 * viewPixelSize / sourceScale;
    vec2 sourceCoord =
        clamp(texCoord, padding, 1.0 - padding) * sourceScale
        + sourceOffset;

    vec3 bloom = vec3(0.0);

    #if BLOOM_TILE_INDEX == 0
        #define BLOOM_SAMPLE(coord) texture2DLod(colortex3, coord, 0.0).rgb
    #else
        #define BLOOM_SAMPLE(coord) texture2DLod(colortex0, coord, 0.0).rgb
    #endif

    bloom += BLOOM_SAMPLE(sourceCoord) * 0.125;

    bloom += BLOOM_SAMPLE(sourceCoord + vec2( 1.0,  1.0) * viewPixelSize) * 0.125;
    bloom += BLOOM_SAMPLE(sourceCoord + vec2(-1.0,  1.0) * viewPixelSize) * 0.125;
    bloom += BLOOM_SAMPLE(sourceCoord + vec2( 1.0, -1.0) * viewPixelSize) * 0.125;
    bloom += BLOOM_SAMPLE(sourceCoord + vec2(-1.0, -1.0) * viewPixelSize) * 0.125;

    #if BLOOM_FILTER_QUALITY == 1
    const float outerWeight = 0.0625;
    #else
    const float outerWeight = 0.09375;
    #endif

    bloom += BLOOM_SAMPLE(sourceCoord + vec2( 2.0,  0.0) * viewPixelSize) * outerWeight;
    bloom += BLOOM_SAMPLE(sourceCoord + vec2(-2.0,  0.0) * viewPixelSize) * outerWeight;
    bloom += BLOOM_SAMPLE(sourceCoord + vec2( 0.0,  2.0) * viewPixelSize) * outerWeight;
    bloom += BLOOM_SAMPLE(sourceCoord + vec2( 0.0, -2.0) * viewPixelSize) * outerWeight;

    #if BLOOM_FILTER_QUALITY == 1
    bloom += BLOOM_SAMPLE(sourceCoord + vec2( 2.0,  2.0) * viewPixelSize) * 0.03125;
    bloom += BLOOM_SAMPLE(sourceCoord + vec2(-2.0,  2.0) * viewPixelSize) * 0.03125;
    bloom += BLOOM_SAMPLE(sourceCoord + vec2( 2.0, -2.0) * viewPixelSize) * 0.03125;
    bloom += BLOOM_SAMPLE(sourceCoord + vec2(-2.0, -2.0) * viewPixelSize) * 0.03125;
    #endif

    #undef BLOOM_SAMPLE

    /* DRAWBUFFERS:0 */
    gl_FragData[0] = vec4(bloom, 1.0);
}

#endif

//**//**//**//**//**//**//**//**//**//**//**//**//**//**//

#ifdef VSH

out vec2 texCoord;

float BloomTileScale(int index) {
    return 0.5 * exp2(-float(index));
}

vec2 BloomTileOffset(int index) {
    float a = exp2(-float(index));
    return vec2(
        1.0 - a,
        float(index & 1) * (1.0 - 0.5 * a)
    );
}

void main() {
    texCoord = gl_MultiTexCoord0.xy;

    float tileScale = BloomTileScale(BLOOM_TILE_INDEX);
    vec2 tileOffset = BloomTileOffset(BLOOM_TILE_INDEX);

    // Render only the current packed bloom tile.
    vec2 position = gl_Vertex.xy * tileScale + tileOffset;
    gl_Position = vec4(position * 2.0 - 1.0, 0.0, 1.0);
}

#endif
