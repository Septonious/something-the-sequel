#include "/lib/common.glsl"

#ifdef FSH

in vec2 texCoord;

uniform int frameCounter;

uniform float timeAngle, timeBrightness, wetness;
uniform float shadowFade;
uniform float frameTime;

uniform vec3 cameraPosition, previousCameraPosition;

uniform sampler2D depthtex0;
uniform sampler2D colortex11;
uniform sampler2D colortex14;
uniform sampler2D colortex15;
uniform sampler2D shadowtex1;

uniform sampler3D floodfillSampler, floodfillSamplerCopy;
uniform sampler3D giCacheSampler, giCacheSamplerCopy;
uniform usampler3D voxelGiSampler;
uniform usampler3D lightGridSampler;
uniform usampler3D voxelBoxSampler;
uniform usampler3D quadPoolSampler;

uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferPreviousProjection;
uniform mat4 gbufferPreviousModelView;
uniform mat4 shadowProjection;
uniform mat4 shadowModelView;

const bool colortex14Clear = false;
const bool colortex15Clear = false;

const vec2 sunRotationData = vec2(cos(sunPathRotation * 0.01745329251994), -sin(sunPathRotation * 0.01745329251994));
float fractTimeAngle = fract(timeAngle - 0.25);
float ang = (fractTimeAngle + (cos(fractTimeAngle * 3.14159265358979) * -0.5 + 0.5 - fractTimeAngle) / 3.0) * 6.28318530717959;
vec3 sunVec = normalize((gbufferModelView * vec4(vec3(-sin(ang), cos(ang) * sunRotationData) * 2000.0, 1.0)).xyz);
vec3 upVec = normalize(gbufferModelView[1].xyz);
float sunVisibility = clamp((dot( sunVec, upVec) + 0.15) * 3.0, 0.0, 1.0);
vec3 lightVec = sunVec * ((timeAngle < 0.5325 || timeAngle > 0.9675) ? 1.0 : -1.0);

#include "/lib/util/transformMacros.glsl"
#include "/lib/util/ToView.glsl"
#include "/lib/util/ToWorld.glsl"
#include "/lib/util/ToShadow.glsl"
#include "/lib/color/lightColor.glsl"
#include "/lib/vx/voxelization.glsl"
#include "/lib/vx/giVoxel.glsl"

vec4 giCacheFetch(ivec3 cell) {
    if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, ivec3(voxelVolumeSize)))) return vec4(0.0, 0.0, 0.0, -1.0);

    return (frameCounter & 1) == 0 ? texelFetch(giCacheSamplerCopy, cell, 0) : texelFetch(giCacheSampler, cell, 0);
}

#include "/lib/vx/giTrace.glsl"
#include "/lib/vx/giNormal.glsl"

void main() {
    vec2 viewSize = vec2(textureSize(depthtex0, 0));
    vec2 coord = (floor(texCoord * viewSize - 0.5) + 0.5) / viewSize;
    float z0 = texture2D(depthtex0, coord).r;
    vec3 viewPos = ToView(vec3(coord, z0));
    vec3 worldPos = ToWorld(viewPos);
    vec3 voxelPos = worldToVoxel(worldPos);
    vec4 gi = vec4(0.0, 0.0, 0.0, 1.0);
    float blockVisibility = 1.0;
    float inverseHitDistance = 1.0 / 32.25;
    float historyLength = 0.0;

    #if GI_DEBUG == 12
    ivec3 debugCell, debugFace;
    float debugDistance;
    uint debugWord;

    giSeed = 1u;
    gi.rgb = vec3(0.0, 0.0, 0.3);

    if (giTrace(worldToVoxel(gbufferModelViewInverse[3].xyz), normalize(worldPos - gbufferModelViewInverse[3].xyz), ivec3(-1), debugCell, debugFace, debugDistance, debugWord)) gi.rgb = pow(giVoxelAlbedo(debugWord), vec3(1.0 / 2.2)) * (0.6 + 0.4 * dot(vec3(debugFace), vec3(0.3, 0.8, 0.5)));

    gl_FragData[0] = gi;
    gl_FragData[1] = vec4(-viewPos.z, 0.0, 1.0, 1.0);

    return;
    #endif

    if (z0 > 0.56 && z0 < 1.0 && isInsideVoxelVolume(voxelPos)) {
        vec3 worldNormal = mat3(gbufferModelViewInverse) * giViewNormal(coord, viewPos);

        if (texture2D(colortex11, coord).r > 0.5 || any(isnan(worldNormal))) worldNormal = vec3(0.0, 1.0, 0.0);

        giSeed = uint(gl_FragCoord.x) * 1973u + uint(gl_FragCoord.y) * 9277u;
        giRandom();

        float pointX = giRandom();
        float pointY = giRandom();
        vec2 point = fract(vec2(pointX, pointY) + vec2(uvec2(frameCounter) * uvec2(3242174889u, 2447445414u)) / 4294967296.0);

        giSeed = uint(gl_FragCoord.x) * 1973u + uint(gl_FragCoord.y) * 9277u + uint(frameCounter) * 26699u;
        giRandom();

        vec3 origin = voxelPos + worldNormal * 0.05;
        vec3 direction = giCosineDirection(worldNormal, point);
        ivec3 hitCell, hitFace;
        float hitDistance;
        uint hitWord;

        if (giTrace(origin, direction, ivec3(-1), hitCell, hitFace, hitDistance, hitWord)) {
            gi = vec4(giHitRadiance(hitCell, hitFace, origin + direction * hitDistance, hitWord, mat3(gbufferModelViewInverse) * lightVec), 0.0);
            inverseHitDistance = 1.0 / (hitDistance + 0.25);
        }

        #ifdef GI_BLOCK_SHADOWS
        vec3 floodfillPos = (voxelPos + worldNormal) / voxelVolumeSize;
        vec3 floodfill = (frameCounter & 1) == 0 ? texture3D(floodfillSamplerCopy, floodfillPos).rgb : texture3D(floodfillSampler, floodfillPos).rgb;

        if (maxOf(floodfill) > 0.0001) blockVisibility = giBlockVisibility(origin, worldNormal);
        #endif

        vec4 previousView = gbufferPreviousModelView * vec4(worldPos + cameraPosition - previousCameraPosition, 1.0);
        vec4 previousClip = gbufferPreviousProjection * previousView;
        vec2 previousCoord = previousClip.xy / previousClip.w * 0.5 + 0.5 + texCoord - coord;

        if (any(isnan(gi)) || any(isinf(gi))) gi = vec4(0.0, 0.0, 0.0, 1.0);

        if (clamp(previousCoord, 0.0, 1.0) == previousCoord) {
            vec4 history = texture2D(colortex15, previousCoord);
            vec4 historyGi = texture2D(colortex14, previousCoord);

            if (abs(history.r + previousView.z) < 0.1 - previousView.z * 0.05 && !any(isnan(history)) && !any(isnan(historyGi)) && !any(isinf(historyGi))) {
                historyLength = clamp(history.g, 0.0, clamp(0.75 / max(frameTime, 0.001), 31.0, 250.0) * (GI_ACCUMULATION / 0.75));
                gi = mix(historyGi, gi, 1.0 / (historyLength + 1.0));
                blockVisibility = mix(clamp(history.b, 0.0, 1.0), blockVisibility, 1.0 / (historyLength + 1.0));
                inverseHitDistance = mix(clamp(history.a, 1.0 / 32.25, 4.0), inverseHitDistance, 1.0 / (historyLength + 1.0));
            }
        }

        if (historyLength < 0.5) {
            vec4 prior = giCacheFetch(ivec3(floor(origin)));

            if (prior.a >= 0.0) gi = mix(prior, gi, 0.25);
        }

        historyLength += 1.0;
    }

    /* RENDERTARGETS: 14,15 */
    gl_FragData[0] = gi;
    gl_FragData[1] = vec4(-viewPos.z, historyLength, blockVisibility, inverseHitDistance);
}

#endif

#ifdef VSH

out vec2 texCoord;

void main() {
    texCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;

    gl_Position = ftransform();
}

#endif
