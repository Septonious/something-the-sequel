#include "/lib/common.glsl"

#ifdef FSH

in vec2 texCoord;

uniform int frameCounter;

uniform sampler2D depthtex0;
uniform sampler2D colortex14;
uniform sampler2D colortex15;
uniform sampler2D noisetex;

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
        float pixelSize = -viewPos.z * viewScale.y * 2.0 / float(textureSize(colortex14, 0).y);
        float minRadius = 1.7320508 * mix(3.0, 1.0, clamp(surface.g / 16.0, 0.0, 1.0)) * pixelSize;
        float radius = clamp(0.02 / clamp(surface.a, 1.0 / 32.25, 4.0), minRadius, 16.0 * pixelSize);
        float rotation = fract(texture2D(noisetex, gl_FragCoord.xy / 512.0).b + 1.61803398875 * mod(float(frameCounter), 3600.0)) * 6.28318530718;
        vec3 viewDirection = normalize(viewPos);
        vec3 tangent = normalize(cross(normal, viewDirection + vec3(0.0, 0.001, 0.0)));
        vec3 bitangent = cross(normal, tangent) * max(1.0, minRadius / (radius * max(abs(dot(normal, viewDirection)), 0.1)));
        float blur = clamp(4.0 / max(surface.g, 1.0), 0.05, 1.0) * GI_FILTER;
        float shadowBlur = minRadius * minRadius / (radius * radius);
        float blockVisibility = surface.b;
        float inverseHitDistance = surface.a;
        float weightSum = 1.0;
        float shadowWeightSum = 1.0;

        for (int i = 0; i < 8; i++) {
            float angle = rotation + float(i) * 2.39996323;
            vec3 tapView = viewPos + (tangent * cos(angle) + bitangent * sin(angle)) * (sqrt((float(i) + 0.5) / 8.0) * radius);
            vec2 tapCoord = tapView.xy / (-tapView.z * viewScale) * 0.5 + 0.5 + texCoord - coord;
            vec4 tapSurface = texture2D(colortex15, tapCoord);
            vec4 tapGi = texture2D(colortex14, tapCoord);

            if (any(isnan(tapSurface)) || any(isinf(tapSurface)) || any(isnan(tapGi)) || any(isinf(tapGi))) continue;

            vec3 tapPos = vec3((tapCoord * 2.0 - 1.0) * viewScale * tapSurface.r, -tapSurface.r);
            float weight = clamp(1.0 - abs(dot(tapPos - viewPos, normal)) / (0.05 + tapSurface.r * 0.01), 0.0, 1.0) * blur;

            gi += tapGi * weight;
            blockVisibility += tapSurface.b * weight * shadowBlur;
            inverseHitDistance += tapSurface.a * weight;
            weightSum += weight;
            shadowWeightSum += weight * shadowBlur;
        }

        gi /= weightSum;
        surface.b = blockVisibility / shadowWeightSum;
        surface.a = inverseHitDistance / weightSum;
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
