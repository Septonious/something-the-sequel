#include "/lib/common.glsl"

#ifdef FSH

in vec2 texCoord;

uniform sampler2D colortex0;

void main() {
    float x = min(texCoord.x, 1.0 - 1e-7);
    int tileIndex = int(-log2(1.0 - x));

    if ((tileIndex & 1) == 1) {
        vec3 bloom = texelFetch(
            colortex0,
            ivec2(gl_FragCoord.xy),
            0
        ).rgb;

        /* DRAWBUFFERS:0 */
        gl_FragData[0] = vec4(bloom, 1.0);
    } else {
        discard;
    }
}

#endif

//**//**//**//**//**//**//**//**//**//**//**//**//**//**//

#ifdef VSH

out vec2 texCoord;

void main() {
    texCoord = gl_Vertex.xy * vec2(0.5, 0.25) + vec2(0.5, 0.75);
    gl_Position = vec4(texCoord * 2.0 - 1.0, 0.0, 1.0);
}

#endif
