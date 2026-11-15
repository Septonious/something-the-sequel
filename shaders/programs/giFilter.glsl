#include "/lib/common.glsl"

#ifdef FSH

in vec2 texCoord;

uniform sampler2D depthtex0;
uniform sampler2D colortex14;
uniform sampler2D colortex15;

uniform mat4 gbufferProjectionInverse;

#include "/lib/util/ToView.glsl"
#include "/lib/vx/giNormal.glsl"

void main() {
    vec2 viewSize = vec2(textureSize(depthtex0, 0));
    vec2 coord = (floor(texCoord * viewSize - 0.5) + 0.5) / viewSize;
    float z0 = texture2D(depthtex0, coord).r;
    vec4 gi = texture2D(colortex14, texCoord);
    vec4 surface = texture2D(colortex15, texCoord);

    #if GI_DEBUG == 12
    z0 = 1.0;
    #endif

    if (z0 > 0.56 && z0 < 1.0) {
        vec3 viewPos = ToView(vec3(coord, z0));
        vec3 normal = giViewNormal(coord, viewPos);
        vec2 viewScale = vec2(gbufferProjectionInverse[0].x, gbufferProjectionInverse[1].y);
        vec2 tapStep = mix(3.0, 1.0, clamp(surface.g / 16.0, 0.0, 1.0)) / vec2(textureSize(colortex14, 0));
        float blur = clamp(4.0 / max(surface.g, 1.0), 0.05, 1.0) * GI_FILTER;
        float blockVisibility = surface.b;
        float weightSum = 1.0;

        for (int i = 0; i < 9; i++) {
            if (i == 4) continue;

            vec2 tapCoord = texCoord + (vec2(i % 3, i / 3) - 1.0) * tapStep;
            vec4 tapSurface = texture2D(colortex15, tapCoord);
            vec4 tapGi = texture2D(colortex14, tapCoord);

            if (any(isnan(tapSurface)) || any(isinf(tapSurface)) || any(isnan(tapGi)) || any(isinf(tapGi))) continue;

            vec3 tapPos = vec3((tapCoord * 2.0 - 1.0) * viewScale * tapSurface.r, -tapSurface.r);
            float weight = clamp(1.0 - abs(dot(tapPos - viewPos, normal)) / (0.05 + tapSurface.r * 0.01), 0.0, 1.0) * blur;

            gi += tapGi * weight;
            blockVisibility += tapSurface.b * weight;
            weightSum += weight;
        }

        gi /= weightSum;
        surface.b = blockVisibility / weightSum;
    }

    /* RENDERTARGETS: 14,15 */
    gl_FragData[0] = gi;
    gl_FragData[1] = surface;
}

#endif

#ifdef VSH

out vec2 texCoord;

void main() {
    texCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;

    gl_Position = ftransform();
}

#endif
