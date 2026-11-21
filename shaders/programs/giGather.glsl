#include "/lib/common.glsl"

#ifdef FSH

in vec2 texCoord;

uniform int frameCounter;

uniform float timeAngle, timeBrightness, wetness;
uniform float shadowFade;
uniform float frameTime;

uniform vec3 cameraPosition, previousCameraPosition;

uniform sampler2D depthtex0;
uniform sampler2D colortex0;
uniform sampler2D colortex10;
uniform sampler2D colortex11;
uniform sampler2D colortex13;
uniform sampler2D colortex14;
uniform sampler2D colortex15;
uniform sampler2D shadowtex1;

uniform sampler3D floodfillSampler, floodfillSamplerCopy;
uniform sampler3D giCacheSampler, giCacheSamplerCopy;
uniform usampler3D voxelGiSampler;
uniform usampler3D lightGridSampler;
uniform usampler3D voxelBoxSampler;
uniform usampler3D quadPoolSampler;

layout(rgba32ui) uniform uimage2D gi_guide_img;
layout(rgba32f) uniform image2D gi_far_img;

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

ivec3 giGuideCell(uint code) {
    return ivec3(code & 255u, (code >> 8u) & 127u, (code >> 15u) & 255u);
}

float giGuideWeight(uint code) {
    return (code >> 23u) == 0u ? 0.0 : exp2((float(code >> 23u) - 256.0) / 8.0);
}

uint giGuidePack(ivec3 cell, float weight, float dither) {
    if (!(weight > 0.0) || clamp(cell, ivec3(0), ivec3(255, 127, 255)) != cell) return 0u;

    return uint(cell.x) | (uint(cell.y) << 8u) | (uint(cell.z) << 15u) | (uint(clamp(floor(log2(weight) * 8.0 + 256.0 + dither), 1.0, 511.0)) << 23u);
}

const float giFloodBand = 0.8;
const float giFloodFloor = 0.00001;

float giFloodfillNearby(vec3 position) {
    vec3 base = floor(position - 0.5);
    vec3 blend = position - 0.5 - base;
    float total = 0.0;
    float weight = 0.0;

    for (int i = 0; i < 8; i++) {
        ivec3 offset = ivec3(i & 1, (i >> 1) & 1, i >> 2);
        ivec3 cell = ivec3(base) + offset;

        if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, ivec3(voxelVolumeSize)))) continue;

        vec4 light = (frameCounter & 1) == 0 ? texelFetch(floodfillSamplerCopy, cell, 0) : texelFetch(floodfillSampler, cell, 0);
        vec3 weights = mix(1.0 - blend, blend, vec3(offset));

        if ((light.a > 1.5 && (light.a < 199.5 || light.a > 216.5) && maxOf(light.rgb) <= 0.0) || any(isnan(light))) continue;

        total += dot(light.rgb, vec3(0.2126, 0.7152, 0.0722)) * weights.x * weights.y * weights.z;
        weight += weights.x * weights.y * weights.z;
    }

    return weight > 0.001 ? total / weight : -1.0;
}

bool giCellEmits(ivec3 cell) {
    if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, ivec3(voxelVolumeSize)))) return false;

    vec4 light = (frameCounter & 1) == 0 ? texelFetch(floodfillSamplerCopy, cell, 0) : texelFetch(floodfillSampler, cell, 0);

    return light.a > 1.5 && (light.a < 199.5 || light.a > 216.5) && maxOf(light.rgb) > 0.0;
}

#ifdef GI_REUSE
const float giReuseSpread = 0.3;
const float giReuseRadius = 16.0;
const int giReuseTaps = 3;
const float giReuseOwn = 0.25;
const float giReuseStretch = 2.0;

vec3 giReuseDirection(vec4 point, vec3 receiver) {
    return point.a > 6.5 ? point.xyz : normalize(point.xyz - receiver);
}

float giReuseDensity(vec4 point, vec3 receiver, vec3 normal) {
    if (point.a > 6.5) return giCosinePdf(normal, point.xyz);

    vec3 toPoint = point.xyz - receiver;
    float range = max(dot(toPoint, toPoint), 0.000001);
    vec3 direction = toPoint * inversesqrt(range);
    float density = giCosinePdf(normal, direction) / range;

    if (point.a < 5.5) {
        int pointFace = int(point.a + 0.5);

        density *= max(-dot(vec3(equal(ivec3(pointFace >> 1), ivec3(0, 1, 2))) * (1.0 - 2.0 * float(pointFace & 1)), direction), 0.0);
    }

    return density;
}

#endif

vec4 giScreenTrace(vec3 viewPos, vec3 viewNormal, vec3 viewDirection, float fade) {
    #ifdef GI_SCREEN_TRACE
    vec2 viewScale = vec2(gbufferProjectionInverse[0].x, gbufferProjectionInverse[1].y);
    float reach = min(0.025 - viewPos.z * 0.0005, -viewPos.z * 0.015);
    float jitter = giRandom();
    bool found = false;
    vec2 rayCoord = vec2(0.0);
    vec3 scenePos = vec3(0.0);
    vec3 toScene = vec3(0.0);

    for (int i = 0; i < 6; i++) {
        float travel = (float(i) + jitter) * (float(i) + jitter) * reach;
        vec3 rayPos = viewPos + viewDirection * travel;

        if (rayPos.z > -0.05) break;

        rayCoord = rayPos.xy / (-rayPos.z * viewScale) * 0.5 + 0.5;

        if (clamp(rayCoord, 0.0, 1.0) != rayCoord) break;

        float sceneDepth = texture2D(depthtex0, rayCoord).r;

        if (sceneDepth < 0.56 || sceneDepth >= 1.0) continue;

        scenePos = ToView(vec3(rayCoord, sceneDepth));
        toScene = scenePos - viewPos;

        float behind = scenePos.z - rayPos.z;

        if (dot(toScene, viewNormal) < 0.005 - viewPos.z * 0.002 || (dot(normalize(toScene), viewDirection) < 0.99 && (behind < 0.0 || behind > reach * 13.0))) continue;

        found = true;

        break;
    }

    if (found) {
        ivec3 sceneCell = ivec3(floor(worldToVoxel(ToWorld(scenePos + viewDirection * 0.02))));
        bool lamp = false;

        if (all(greaterThanEqual(sceneCell, ivec3(0))) && all(lessThan(sceneCell, ivec3(voxelVolumeSize)))) {
            vec4 sceneLight = (frameCounter & 1) == 0 ? texelFetch(floodfillSamplerCopy, sceneCell, 0) : texelFetch(floodfillSampler, sceneCell, 0);

            lamp = sceneLight.a > 1.5 && (sceneLight.a < 199.5 || sceneLight.a > 216.5) && maxOf(sceneLight.rgb) > 0.0;
        }

        if (!lamp) {
            vec4 previousView = gbufferPreviousModelView * vec4(ToWorld(scenePos) + cameraPosition - previousCameraPosition, 1.0);
            vec4 previousClip = gbufferPreviousProjection * previousView;
            vec2 previousCoord = previousClip.xy / previousClip.w * 0.5 + 0.5;
            ivec2 previousTexel = min(ivec2(previousCoord * vec2(textureSize(colortex14, 0))), textureSize(colortex14, 0) - 1);
            vec3 sceneSurface = texture2D(colortex11, rayCoord).rgb;
            vec3 radiance = max(pow(max(texture2D(colortex0, rayCoord).rgb, vec3(0.0)), vec3(2.2)) - texture2D(colortex10, rayCoord).rgb / (1.0 - sceneSurface.r * 0.35), vec3(0.0)) * (sceneSurface.b > 0.0 ? GI_SUN_BOUNCE : 1.0);

            if (clamp(previousCoord, 0.0, 1.0) == previousCoord && abs(abs(texelFetch(colortex15, previousTexel, 0).r) + previousView.z) < 0.1 - previousView.z * 0.05) {
                vec3 receptor = texture2D(colortex13, rayCoord).rgb;
                vec4 previousGi = max(texelFetch(colortex14, previousTexel, 0), vec4(0.0));

                radiance += receptor * receptor * (previousGi.rgb * GI_MULTI_BOUNCE + ambientCol * (previousGi.a * mix(sceneSurface.g, clamp(sceneSurface.g * 8.0, 0.0, 1.0), fade) * (1.0 - sceneSurface.b)));
            }

            return vec4(radiance, length(toScene));
        }
    }
    #endif

    return vec4(0.0, 0.0, 0.0, -1.0);
}

vec4 giSceneRadiance(vec3 viewPos, vec3 worldNormal, vec3 origin, vec3 direction, float fade) {
    vec4 screenHit = giScreenTrace(viewPos, mat3(gbufferModelView) * worldNormal, mat3(gbufferModelView) * direction, fade);

    return screenHit.a >= 0.0 ? vec4(screenHit.rgb, 0.0) : mix(vec4(0.0, 0.0, 0.0, 1.0), giTraceRadiance(origin, direction, mat3(gbufferModelViewInverse) * lightVec), fade);
}

vec3 giGuideFaces(vec3 origin, vec3 low, vec3 high) {
    vec3 side = (low + high) * 0.5 - origin;
    vec3 gap = max(low - origin, 0.0) + max(origin - high, 0.0);
    vec3 range = gap * gap + dot(side, side) - side * side;

    return gap / max(range * sqrt(range), 0.000001);
}

float giGuideBox(ivec3 cell, vec3 origin, vec3 normal, out vec3 low, out vec3 high) {
    low = vec3(cell);
    high = low + 1.0;

    if (all(greaterThanEqual(cell, ivec3(0))) && all(lessThan(cell, ivec3(voxelVolumeSize)))) {
        uint bounds = texelFetch(voxelBoxSampler, ivec3(cell.x * 2 + 1, cell.yz), 0).r;

        if (bounds != 0u) {
            uvec3 boundBits = uvec3(bounds & 511u, (bounds >> 9u) & 511u, bounds >> 18u);

            high = low + vec3(findMSB(boundBits)) * 0.125;
            low += vec3(findLSB(boundBits)) * 0.125;
        }
    }

    vec3 extent = high - low;

    if (dot(normal, (low + high) * 0.5 - origin) + dot(abs(normal), extent) * 0.5 <= 0.0) return 0.0;

    return dot(giGuideFaces(origin, low, high), extent.yzx * extent.zxy);
}

float giGuideDensity(vec3 origin, vec3 direction, vec3 low, vec3 high, float total) {
    vec3 slope = direction + vec3(lessThan(abs(direction), vec3(0.000001))) * 0.000002;
    vec3 planeA = (low - origin) / slope;
    vec3 planeB = (high - origin) / slope;
    vec3 enter = min(planeA, planeB);
    vec3 leave = max(planeA, planeB);
    float reach = max(enter.x, max(enter.y, enter.z));

    if (reach <= 0.0 || reach > min(leave.x, min(leave.y, leave.z))) return 0.0;

    int axis = reach == enter.x ? 0 : (reach == enter.y ? 1 : 2);

    return reach * reach * giGuideFaces(origin, low, high)[axis] / (max(abs(direction[axis]), 0.000001) * total);
}

void main() {
    vec2 viewSize = vec2(textureSize(depthtex0, 0));
    vec2 coord = (floor(texCoord * viewSize - 0.5) + 0.5) / viewSize;
    float z0 = texture2D(depthtex0, coord).r;
    vec3 viewPos = ToView(vec3(coord, z0));
    vec3 worldPos = ToWorld(viewPos);
    vec3 voxelPos = worldToVoxel(worldPos);
    vec4 gi = vec4(0.0, 0.0, 0.0, 1.0);
    float blockLuminance = 0.0;
    float inverseHitDistance = 1.0 / 32.25;
    float historyLength = 0.0;
    int face = 0;

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

    #ifdef GI_REUSE
    ivec2 farSize = imageSize(gi_far_img) / ivec2(4, 3);
    ivec2 trackColumn = ivec2(farSize.x * 3, 0);
    #else
    ivec2 farSize = imageSize(gi_far_img) / ivec2(2, 2);
    ivec2 trackColumn = ivec2(farSize.x, 0);
    #endif
    ivec2 farWrite = ivec2(0, (frameCounter & 1) * farSize.y);
    ivec2 farRead = ivec2(0, farSize.y) - farWrite;
    bool inVolume = isInsideVoxelVolume(voxelPos);
    bool traced = z0 > 0.56 && z0 < 1.0;
    float giFade = giVolumeFade(worldPos);

    #ifndef GI_SCREEN_TRACE
    traced = traced && inVolume;
    #endif

    if (traced) {
        vec3 worldNormal = mat3(gbufferModelViewInverse) * giViewNormal(coord, viewPos);
        bool foliage = texture2D(colortex11, coord).r > 0.5;

        if (foliage || any(isnan(worldNormal))) worldNormal = vec3(0.0, 1.0, 0.0);

        giSeed = uint(gl_FragCoord.x) * 1973u + uint(gl_FragCoord.y) * 9277u;
        giRandom();

        float pointX = giRandom();
        float pointY = giRandom();
        vec2 point = fract(vec2(pointX, pointY) + vec2(uvec2(frameCounter) * uvec2(3242174889u, 2447445414u)) / 4294967296.0);

        giSeed = uint(gl_FragCoord.x) * 1973u + uint(gl_FragCoord.y) * 9277u + uint(frameCounter) * 26699u;
        giRandom();

        vec3 origin = voxelPos + worldNormal * 0.05;
        vec3 luminance = vec3(0.2126, 0.7152, 0.0722);

        vec4 previousView = gbufferPreviousModelView * vec4(worldPos + cameraPosition - previousCameraPosition, 1.0);
        vec4 previousClip = gbufferPreviousProjection * previousView;
        vec2 previousCoord = previousClip.xy / previousClip.w * 0.5 + 0.5 + texCoord - coord;
        vec2 previousScale = 1.0 / vec2(gbufferPreviousProjection[0].x, gbufferPreviousProjection[1].y);
        vec3 previousNormal = foliage ? vec3(0.0, 0.0, 1.0) : mat3(gbufferPreviousModelView) * worldNormal;
        vec4 history = vec4(0.0);
        vec4 historyGi = vec4(0.0);
        vec4 historyFar = vec4(0.0);
        vec4 farSpread = vec4(0.0);
        vec4 historyTrack = vec4(0.0);
        float floodNow = giFloodfillNearby(voxelPos + worldNormal * 0.5);
        float trackWeight = 0.0;
        float historyCut = 0.0;
        float historyWeight = 0.0;
        float historyTolerance = foliage ? 0.5 - previousView.z * 0.02 : 0.005 - previousView.z * 0.002;

        face = giFace(worldNormal);

        #ifdef GI_REUSE
        float storeScale = exp2(-clamp(round(log2(-viewPos.z * gbufferProjectionInverse[1].y * 8.0 / float(textureSize(colortex14, 0).y))), -4.0, 0.0));
        ivec3 storeCell = ivec3(floor(cameraPosition)) * int(storeScale) + ivec3(floor((worldPos + fract(cameraPosition) - worldNormal * 0.01) * storeScale));
        uint storeHash = (uint(storeCell.x) * 73856093u) ^ (uint(storeCell.y) * 19349663u) ^ (uint(storeCell.z) * 83492791u) ^ (uint(face) * 2654435761u) ^ (uint(storeScale) * 668265263u);
        int storeWidth = farSize.x * 3 / 2;
        int storeSlot = int(storeHash % uint(storeWidth * farSize.y));
        ivec2 storeTexel = ivec2((storeSlot % storeWidth) * 2, farSize.y * 2 + storeSlot / storeWidth);
        float storeCheck = float((storeHash * 2246822519u) >> 8u);
        #endif

        ivec2 historySize = textureSize(colortex14, 0);
        vec2 historyPos = previousCoord * vec2(historySize) - 0.5;
        ivec2 historyBase = ivec2(floor(historyPos));
        vec2 historyBlend = historyPos - vec2(historyBase);

        #ifdef GI_REUSE
        ivec2 reuseTap = ivec2(0);
        #endif

        if (clamp(previousCoord, 0.0, 1.0) == previousCoord) {
            for (int i = 0; i < 13; i++) {
                if (i == 4 && historyWeight > 0.0) break;

                ivec2 offset = i < 4 ? ivec2(i & 1, i >> 1) : ivec2((i - 4) % 3, (i - 4) / 3) - 1 + ivec2(round(historyBlend));
                ivec2 tap = clamp(historyBase + offset, ivec2(0), historySize - 1);
                vec4 tapSurface = texelFetch(colortex15, tap, 0);
                vec4 tapGi = texelFetch(colortex14, tap, 0);
                vec2 blend = mix(1.0 - historyBlend, historyBlend, vec2(offset));
                float weight = i < 4 ? blend.x * blend.y : 1.0;
                vec2 tapCoord = (vec2(tap) + 0.5) / vec2(historySize) - texCoord + coord;
                vec3 tapPos = vec3((tapCoord * 2.0 - 1.0) * previousScale * abs(tapSurface.r), -abs(tapSurface.r));

                if (giStoredFace(tapSurface) != face || abs(dot(tapPos - previousView.xyz, previousNormal)) >= historyTolerance || any(isnan(tapSurface)) || any(isnan(tapGi)) || any(isinf(tapGi))) continue;

                vec4 tapFar = imageLoad(gi_far_img, min(tap, farSize - 1) + farRead);
                vec4 tapTrack = imageLoad(gi_far_img, min(tap, farSize - 1) + farRead + trackColumn);

                history += abs(tapSurface) * weight;
                historyGi += tapGi * weight;
                historyWeight += weight;

                if (tapTrack.a >= 0.0 && !(any(isnan(tapTrack)) || any(isinf(tapTrack)))) {
                    historyTrack += tapTrack * weight;
                    trackWeight += weight;
                }

                #ifdef GI_REUSE
                if (giRandom() * historyWeight < weight) reuseTap = tap;
                #endif

                if (!(any(isnan(tapFar)) || any(isinf(tapFar)))) historyFar += tapFar * weight;
            }

            float spreadAngle = giRandom() * 6.28318530718;

            for (int i = 0; i < 8; i++) {
                float angle = spreadAngle + float(i) * 2.39996323;
                ivec2 tap = clamp(historyBase + ivec2(round(historyBlend + vec2(cos(angle), sin(angle)) * (sqrt((float(i) + 0.5) / 8.0) * 6.0))), ivec2(0), historySize - 1);
                vec4 tapSurface = texelFetch(colortex15, tap, 0);
                vec2 tapCoord = (vec2(tap) + 0.5) / vec2(historySize) - texCoord + coord;
                vec3 tapPos = vec3((tapCoord * 2.0 - 1.0) * previousScale * abs(tapSurface.r), -abs(tapSurface.r));

                if (giStoredFace(tapSurface) != face || abs(dot(tapPos - previousView.xyz, previousNormal)) >= historyTolerance || any(isnan(tapSurface))) continue;

                vec4 tapFar = imageLoad(gi_far_img, min(tap, farSize - 1) + farRead);

                if (!(any(isnan(tapFar)) || any(isinf(tapFar)))) farSpread += vec4(tapFar.rgb, 1.0);
            }
        }

        bool reprojected = historyWeight > 0.0;

        if (reprojected) {
            history /= historyWeight;
            historyGi /= historyWeight;
            historyFar /= historyWeight;
            historyTrack = trackWeight > 0.0 ? historyTrack / trackWeight : vec4(0.0, 0.0, 0.0, -1.0);

            vec3 viewNormal = foliage ? vec3(0.0, 0.0, 1.0) : mat3(gbufferModelView) * worldNormal;
            float range = length(viewPos);
            float previousRange = length(previousView.xyz);
            float tilt = max(abs(dot(viewNormal, viewPos)) / range, 0.02);
            float previousTilt = max(abs(dot(previousNormal, previousView.xyz)) / previousRange, 0.02);

            history.g *= min(range * range * previousTilt / (previousRange * previousRange * tilt), 1.0);

            if (floodNow >= 0.0 && historyTrack.a >= 0.0) {
                if (historyTrack.r > giFloodFloor && floodNow < historyTrack.r * giFloodBand) {
                    float blockScale = floodNow / (historyTrack.r * giFloodBand);
                    float historyLight = dot(historyGi.rgb, luminance);
                    float blockShare = historyLight > 0.000001 ? clamp(max(history.b, 0.0) / historyLight, 0.0, 1.0) : 0.0;
                    float lightScale = 1.0 - blockShare * (1.0 - blockScale);

                    historyGi.rgb *= lightScale;
                    history.b *= blockScale;
                    historyFar.rgb *= blockScale;
                    historyCut = 1.0 - lightScale;
                    historyTrack.r = floodNow / giFloodBand;

                    if (history.g > 32.0) {
                        historyCut = max(historyCut, 1.0 - 32.0 / history.g);
                        history.g = 32.0;
                    }
                } else if (floodNow > historyTrack.r / giFloodBand + giFloodFloor) {
                    if (history.g > 32.0) {
                        historyCut = 1.0 - 32.0 / history.g;
                        history.g = 32.0;
                    }

                    historyTrack.r = floodNow * giFloodBand;
                }
            }
        } else {
            #ifdef GI_REUSE
            vec4 storedGi = imageLoad(gi_far_img, storeTexel);
            vec4 storedSurface = imageLoad(gi_far_img, storeTexel + ivec2(1, 0));
            bool stored = storedSurface.r == storeCheck && !any(isnan(storedGi)) && !any(isinf(storedGi)) && !any(isnan(storedSurface)) && !any(isinf(storedSurface)) && (floodNow < 0.0 || (storedSurface.a > 0.0 && floodNow >= storedSurface.a * giFloodBand - giFloodFloor && floodNow <= storedSurface.a / giFloodBand + giFloodFloor && !(storedSurface.a <= giFloodFloor * 2.0 && storedSurface.g > 0.25 * dot(storedGi.rgb, luminance))));
            int seeds = stored ? 0 : (clamp(previousCoord, 0.0, 1.0) == previousCoord ? 1 : 2);
            #else
            int seeds = clamp(previousCoord, 0.0, 1.0) == previousCoord ? 1 : 2;
            #endif

            for (int i = 0; i < seeds; i++) {
                vec3 seedDirection, seedLampDirection;
                vec2 seedWeights = giLampedDirections(origin, worldNormal, seedDirection, seedLampDirection);

                giPassLight = vec3(0.0);
                giHitBlockLuminance = 0.0;

                vec4 seedRadiance = giSceneRadiance(viewPos, worldNormal, origin, seedDirection, giFade) * (seedWeights.x / float(seeds));

                if (seedWeights.x == 1.0 && giHitBlockLuminance + dot(giPassLight, luminance) > 0.0) {
                    historyFar.rgb += seedRadiance.rgb / 31.0;
                    seedRadiance.rgb = vec3(0.0);
                }

                historyGi += seedRadiance;

                if (seedWeights.y > 0.0) historyGi += giSceneRadiance(viewPos, worldNormal, origin, seedLampDirection, giFade) * (seedWeights.y / float(seeds));
            }

            if (any(isnan(historyGi)) || any(isinf(historyGi))) historyGi = vec4(0.0, 0.0, 0.0, 1.0);

            history = vec4(0.0, 4.0, 0.0, 1.0 / 32.25);

            historyTrack = vec4(floodNow, 0.0, 0.0, floodNow >= 0.0 ? 1.0 : -1.0);

            #ifdef GI_REUSE
            if (stored) {
                historyGi = storedGi;
                history = vec4(0.0, 64.0, storedSurface.g, storedSurface.b);

                if (storedSurface.a > 0.0 && floodNow >= 0.0) historyTrack.r = storedSurface.a;
            }
            #endif
            giPassLight = vec3(0.0);
            giHitBlockLuminance = 0.0;
        }

        ivec2 guideSize = imageSize(gi_guide_img);
        ivec2 guidePixel = min(ivec2(gl_FragCoord.xy), guideSize - 1);
        ivec3 cellShift = ivec3(floor(previousCameraPosition) - floor(cameraPosition));
        ivec2 guidePrevious = min(ivec2(previousCoord * vec2(guideSize)), guideSize - 1);
        uvec4 guide = reprojected ? imageLoad(gi_guide_img, guidePrevious) : uvec4(0u);
        float accumulationLength = clamp(0.75 / max(frameTime, 0.001), 31.0, 250.0) * (GI_ACCUMULATION / 0.75);

        if (reprojected) {
            uint emitterSlots = guide.a & 7u;
            float slotTotal = 0.0;
            float vanished = 0.0;

            for (int i = 0; i < 3; i++) {
                float slotWeight = giGuideWeight(guide[i]);

                slotTotal += slotWeight;

                if (((emitterSlots >> uint(i)) & 1u) != 0u && !giCellEmits(giGuideCell(guide[i]) + cellShift)) vanished += slotWeight;
            }

            if (vanished > 0.25 * slotTotal) {
                float blockScale = 1.0 - vanished / slotTotal;
                float historyLight = dot(historyGi.rgb, luminance);
                float blockShare = historyLight > 0.000001 ? clamp(max(history.b, 0.0) / historyLight, 0.0, 1.0) : 0.0;

                historyGi.rgb *= 1.0 - blockShare * (1.0 - blockScale);
                history.b *= blockScale;
                historyFar.rgb *= blockScale;

                if (history.g > 16.0) {
                    historyCut = max(historyCut, 1.0 - 16.0 / history.g);
                    history.g = 16.0;
                }
            }
        }

        #ifdef GI_REUSE
        float historyCap = 250.0;
        #else
        float historyCap = accumulationLength;
        #endif

        #ifdef GI_REUSE
        ivec2 reusePixel = min(ivec2(gl_FragCoord.xy), farSize - 1) + farWrite;
        vec4 ownPoint = vec4(0.0);
        vec4 ownState = vec4(0.0);
        vec3 ownDirection = vec3(0.0);
        float ownShare = 0.0;

        if (reprojected) {
            ownPoint = imageLoad(gi_far_img, min(reuseTap, farSize - 1) + farRead + ivec2(farSize.x, 0));
            ownState = imageLoad(gi_far_img, min(reuseTap, farSize - 1) + farRead + ivec2(farSize.x * 2, 0));

            if (any(isnan(ownPoint)) || any(isinf(ownPoint)) || any(isnan(ownState)) || any(isinf(ownState))) {
                ownPoint = vec4(0.0);
                ownState = vec4(0.0);
            }

            if (ownPoint.a < 6.5) ownPoint.xyz += vec3(cellShift);

            ownState.b = min(ownState.b, clamp(accumulationLength * 0.5, 8.0, 40.0) - 1.0);
            ownState.b = max(ownState.b * (1.0 - historyCut), min(ownState.b, 1.0));
            ownDirection = giReuseDirection(ownPoint, origin);
            ownShare = giCosinePdf(worldNormal, ownDirection);
        }
        #endif

        #if GI_RAY_RATE > 1
        ivec2 rayTile = ivec2(gl_FragCoord.xy) >> 3;

        #if GI_RAY_RATE == 2
        bool rayTurn = ((rayTile.x + rayTile.y + frameCounter) & 1) == 0;
        #else
        bool rayTurn = (rayTile.x & 1) + (rayTile.y & 1) * 2 == (frameCounter & 3);
        #endif

        if (reprojected && !rayTurn && history.g > accumulationLength * 0.5) {
            uvec4 keptGuide = uvec4(0u, 0u, 0u, guide.a & ~7u);

            for (int i = 0; i < 3; i++) {
                keptGuide[i] = giGuidePack(giGuideCell(guide[i]) + cellShift, giGuideWeight(guide[i]), 0.5);

                if (inVolume && keptGuide[i] != 0u && giCellEmits(giGuideCell(keptGuide[i]))) keptGuide.a |= 1u << uint(i);
            }

            imageStore(gi_guide_img, guidePixel, inVolume ? keptGuide : uvec4(0u));
            imageStore(gi_far_img, min(ivec2(gl_FragCoord.xy), farSize - 1) + farWrite, vec4(historyFar.rgb, min(historyFar.a, accumulationLength * 8.0) + 1.0));
            imageStore(gi_far_img, min(ivec2(gl_FragCoord.xy), farSize - 1) + farWrite + trackColumn, historyTrack.a >= 0.0 ? vec4(historyTrack.r, 0.0, 0.0, historyTrack.a) : vec4(floodNow, 0.0, 0.0, floodNow >= 0.0 ? 1.0 : -1.0));

            #ifdef GI_REUSE
            imageStore(gi_far_img, reusePixel + ivec2(farSize.x, 0), ownPoint);
            imageStore(gi_far_img, reusePixel + ivec2(farSize.x * 2, 0), ownState);
            #endif

            gl_FragData[0] = historyGi;
            gl_FragData[1] = vec4(-viewPos.z, min(history.g, historyCap) + 1.0, max(history.b, 0.0), clamp(history.a, 1.0 / 32.25, 4.0)) * (1.0 - 2.0 * vec4(face & 1, (face >> 1) & 1, 0, face >> 2));

            return;
        }
        #endif

        #ifdef GI_REUSE
        vec4 reusePoint = ownPoint;
        vec3 reuseDirection = ownDirection;
        float reuseRadiance = ownState.r;
        float ownWeight = ownState.r * ownShare * ownState.g * ownState.b;
        float reuseSum = 0.0;
        float reuseCount = 0.0;
        bool reuseParity = (((int(gl_FragCoord.x) >> 3) + (int(gl_FragCoord.y) >> 3) + (frameCounter >> (GI_RAY_RATE / 2))) & 1) == 1;
        bool reuseTurn = reprojected && reuseParity;
        bool darkTurn = false;

        if (reuseTurn) {
            vec4 tapPoints[giReuseTaps + 1];
            vec4 tapStates[giReuseTaps + 1];
            vec3 tapReceivers[giReuseTaps + 1];
            int tapCount = 1;
            float reusePixelSize = -viewPos.z * gbufferProjectionInverse[1].y * 2.0 / float(historySize.y);
            float reuseReach = clamp(giReuseSpread / (clamp(history.a, 1.0 / 32.25, 4.0) * reusePixelSize), 1.5, giReuseRadius);

            tapPoints[0] = ownPoint;
            tapStates[0] = ownState;
            tapStates[0].b *= giReuseOwn;
            tapReceivers[0] = origin;

            for (int i = 0; i < giReuseTaps; i++) {
                float angle = giRandom() * 6.28318530718;
                float reach = sqrt(giRandom()) * reuseReach;
                ivec2 tap = clamp(historyBase + ivec2(round(historyBlend + vec2(cos(angle), sin(angle)) * reach)), ivec2(0), historySize - 1);
                vec4 tapSurface = texelFetch(colortex15, tap, 0);
                vec2 tapCoord = (vec2(tap) + 0.5) / vec2(historySize) - texCoord + coord;
                vec3 tapPos = vec3((tapCoord * 2.0 - 1.0) * previousScale * abs(tapSurface.r), -abs(tapSurface.r));

                if (tap == reuseTap || giStoredFace(tapSurface) != face || abs(dot(tapPos - previousView.xyz, previousNormal)) >= historyTolerance || any(isnan(tapSurface))) continue;

                vec4 tapPoint = imageLoad(gi_far_img, min(tap, farSize - 1) + farRead + ivec2(farSize.x, 0));
                vec4 tapState = imageLoad(gi_far_img, min(tap, farSize - 1) + farRead + ivec2(farSize.x * 2, 0));

                if (any(isnan(tapPoint)) || any(isinf(tapPoint)) || any(isnan(tapState)) || any(isinf(tapState)) || tapState.b <= 0.0) continue;

                if (tapPoint.a < 6.5) tapPoint.xyz += vec3(cellShift);

                tapPoints[tapCount] = tapPoint;
                tapStates[tapCount] = tapState;
                tapReceivers[tapCount] = worldToVoxel(transpose(mat3(gbufferPreviousModelView)) * (tapPos - gbufferPreviousModelView[3].xyz) + previousCameraPosition - cameraPosition) + worldNormal * 0.05;
                tapCount++;
            }

            for (int i = 0; i < tapCount; i++) {
                float densitySum = 0.0;
                float ownDensity = 0.0;
                float tapDensity = 0.0;

                for (int j = 0; j < tapCount; j++) {
                    float density = giReuseDensity(tapPoints[i], tapReceivers[j], worldNormal);

                    densitySum += tapStates[j].b * density;

                    if (j == 0) ownDensity = density;
                    if (j == i) tapDensity = density;
                }

                float tapWeight = densitySum > 0.0 ? tapStates[i].r * tapStates[i].g * giCosinePdf(worldNormal, giReuseDirection(tapPoints[i], tapReceivers[i])) * tapStates[i].b * min(ownDensity, tapDensity * giReuseStretch) / densitySum : 0.0;

                reuseSum += tapWeight;
                reuseCount += tapStates[i].b;

                if (tapWeight > 0.0 && giRandom() * reuseSum < tapWeight) {
                    reusePoint = tapPoints[i];
                    reuseDirection = giReuseDirection(tapPoints[i], origin);
                    reuseRadiance = tapStates[i].r;
                }
            }

            if (!(reuseSum > 0.0) || !(reuseRadiance > 0.0)) {
                reuseTurn = false;
                darkTurn = reuseCount > 0.0;
            }
        }
        #endif

        float offsetX = giRandom();

        float offsetY = giRandom();
        ivec2 neighbourPixel = clamp(guidePixel + ivec2((vec2(offsetX, offsetY) - 0.5) * (history.g > 24.0 ? 24.0 : 96.0)), ivec2(0), guideSize - 1);
        uvec4 neighbour = imageLoad(gi_guide_img, neighbourPixel);

        if (!reprojected) {
            vec4 nearFar = imageLoad(gi_far_img, min(neighbourPixel, farSize - 1) + farRead);

            if (nearFar.a > 8.0 && !any(isnan(nearFar))) historyFar.rgb += historyGi.rgb * clamp(dot(nearFar.rgb, luminance) / max(dot(texelFetch(colortex14, min(neighbourPixel, textureSize(colortex14, 0) - 1), 0).rgb, luminance), 0.000001), 0.0, 0.5);
        }
        float guideLuminance = uintBitsToFloat(guide.a);
        ivec3 slotCells[3];
        float slotWeights[3];
        int weakest = 0;
        int strongest = 0;

        if (isnan(guideLuminance) || isinf(guideLuminance)) guideLuminance = 0.0;

        for (int i = 0; i < 3; i++) {
            slotCells[i] = giGuideCell(guide[i]) + cellShift;
            #ifdef GI_REUSE
            slotWeights[i] = giGuideWeight(guide[i]) * (reuseTurn ? 1.0 : 0.98);
            #else
            slotWeights[i] = giGuideWeight(guide[i]) * 0.98;
            #endif

            if (slotWeights[i] < slotWeights[weakest]) weakest = i;
            if (giGuideWeight(neighbour[i]) > giGuideWeight(neighbour[strongest])) strongest = i;
        }

        ivec3 strongestCell = giGuideCell(neighbour[strongest]) + cellShift;

        if (giGuideWeight(neighbour[strongest]) > slotWeights[weakest] * 2.0 && strongestCell != slotCells[0] && strongestCell != slotCells[1] && strongestCell != slotCells[2]) {
            slotCells[weakest] = strongestCell;
            slotWeights[weakest] = giGuideWeight(neighbour[strongest]) * 0.25;
        }

        vec3 boxLow[3];
        vec3 boxHigh[3];
        float boxTotals[3];
        float boxWeights[3];
        float boxTotal = 0.0;
        float guideProbability = 0.0;

        for (int i = 0; i < 3; i++) {
            boxTotals[i] = giGuideBox(slotCells[i], origin, worldNormal, boxLow[i], boxHigh[i]);
            boxWeights[i] = slotWeights[i] > 0.0 && boxTotals[i] > 0.0 ? slotWeights[i] : 0.0;
            boxTotal += boxWeights[i];
        }

        if (inVolume && boxTotal > 0.0) guideProbability = clamp(guideLuminance / max(dot(historyGi.rgb, luminance) * GI_STRENGTH + historyGi.a * dot(ambientCol, luminance), 0.000001), reprojected && history.g > 32.0 ? 0.015625 : 0.5, 0.5);

        vec3 direction = giCosineDirection(worldNormal, point);
        float sampleWeight = 1.0;
        bool insideBox = false;

        if (guideProbability > 0.0) {
            int chosen = -1;
            float chosenDensity = 0.0;

            if (giRandom() < guideProbability) {
                float pick = giRandom() * boxTotal;

                for (int i = 0; i < 3; i++) {
                    if (boxWeights[i] <= 0.0) continue;

                    chosen = i;

                    if (pick < boxWeights[i]) break;

                    pick -= boxWeights[i];
                }

                vec3 extent = boxHigh[chosen] - boxLow[chosen];
                vec3 faceShares = giGuideFaces(origin, boxLow[chosen], boxHigh[chosen]);
                vec3 faceWeights = faceShares * extent.yzx * extent.zxy;
                float facePick = giRandom() * boxTotals[chosen];
                int axis = faceWeights.z > 0.0 ? 2 : (faceWeights.y > 0.0 ? 1 : 0);

                if (facePick < faceWeights.x + faceWeights.y && faceWeights.y > 0.0) axis = 1;
                if (facePick < faceWeights.x) axis = 0;

                vec3 target = boxLow[chosen] + extent * (axis == 0 ? vec3(0.0, point) : (axis == 1 ? vec3(point.x, 0.0, point.y) : vec3(point, 0.0)));

                target[axis] = origin[axis] < boxLow[chosen][axis] ? boxLow[chosen][axis] : boxHigh[chosen][axis];

                vec3 toTarget = target - origin;

                direction = normalize(toTarget);
                chosenDensity = dot(toTarget, toTarget) * faceShares[axis] / (max(abs(direction[axis]), 0.000001) * boxTotals[chosen]);
            }

            float facing = max(dot(worldNormal, direction), 0.0);
            float cosinePdf = facing * facing > 0.001999 ? (2.0 * facing * facing - 0.001999) / (6.27690212 * sqrt(facing * facing - 0.001999)) : 0.0;
            float boxDensity = 0.0;

            for (int i = 0; i < 3; i++) {
                if (boxWeights[i] > 0.0) boxDensity += boxWeights[i] * (i == chosen ? chosenDensity : giGuideDensity(origin, direction, boxLow[i], boxHigh[i], boxTotals[i]));
            }

            insideBox = boxDensity > 0.0;
            sampleWeight = cosinePdf > 0.0 ? cosinePdf / mix(cosinePdf, boxDensity / boxTotal, guideProbability) : 0.0;
        }

        #ifdef GI_REUSE
        if (reuseTurn) {
            direction = reuseDirection;
            sampleWeight = reuseSum / reuseRadiance;
            insideBox = false;
        }
        #endif

        ivec3 hitCell, hitFace = ivec3(0);
        float hitDistance;
        uint hitWord;
        vec4 screenHit = sampleWeight > 0.0 ? giScreenTrace(viewPos, mat3(gbufferModelView) * worldNormal, mat3(gbufferModelView) * direction, giFade) : vec4(0.0, 0.0, 0.0, -1.0);
        bool hit = screenHit.a >= 0.0;

        if (hit) {
            gi = vec4(screenHit.rgb, 0.0);
            hitDistance = screenHit.a;
            inverseHitDistance = 1.0 / (hitDistance + 0.25);
        } else if (sampleWeight > 0.0 && giTrace(origin, direction, ivec3(-1), hitCell, hitFace, hitDistance, hitWord)) {
            hit = true;
            gi = vec4(giHitRadiance(hitCell, hitFace, origin + direction * hitDistance, hitWord, mat3(gbufferModelViewInverse) * lightVec, GI_SUN_BOUNCE) * giFade, 1.0 - giFade);
            blockLuminance = giHitBlockLuminance * giFade;
            inverseHitDistance = mix(1.0 / 32.25, 1.0 / (hitDistance + 0.25), giFade);
        }

        giPassLight *= giFade;
        gi.rgb += giPassLight;
        blockLuminance += dot(giPassLight, luminance);

        if (any(isnan(gi)) || any(isinf(gi))) {
            gi = vec4(0.0, 0.0, 0.0, 1.0);
            blockLuminance = 0.0;
        }

        #ifdef GI_REUSE
        if (reuseTurn && (reusePoint.a > 6.5 ? hit : !hit || abs(hitDistance - distance(reusePoint.xyz, origin)) > (reusePoint.a > 5.5 ? 0.15 + 0.1 * hitDistance : 0.02 + 0.01 * hitDistance) || (reusePoint.a < 5.5 && (hitFace == ivec3(0) || giFace(vec3(hitFace)) != int(reusePoint.a + 0.5))))) {
            gi = vec4(0.0);
            blockLuminance = 0.0;
        }
        #endif

        float radiance = dot(gi.rgb, luminance) * GI_STRENGTH + gi.a * dot(ambientCol, luminance);
        float candidateWeight = radiance * radiance * sampleWeight;
        ivec3 candidateCell = clamp(hit ? ivec3(floor(origin + direction * hitDistance - vec3(hitFace) * 0.01)) : ivec3(origin + direction * 32.0), ivec3(0), ivec3(voxelVolumeSize) - 1);

        if (dot(giPassLight, luminance) * GI_STRENGTH > radiance * 0.5) candidateCell = giPassCell;

        #ifdef GI_REUSE
        vec4 keptPoint = hit ? vec4(origin + direction * hitDistance, hitFace == ivec3(0) ? 6.0 : float(giFace(vec3(hitFace)))) : vec4(direction, 7.0);
        vec4 keptState = vec4(0.0);
        float tracedShare = giCosinePdf(worldNormal, direction);

        if (reuseTurn) {
            if (radiance > 2.0 * reuseRadiance) sampleWeight *= 2.0 * reuseRadiance / radiance;

            candidateWeight = 0.0;
            keptPoint = ownPoint;
            keptState = ownState;

            if (reusePoint == ownPoint) {
                if (radiance > 2.0 * ownState.r) keptState.g *= 2.0 * ownState.r / radiance;

                keptState.r = radiance;
            }
        } else {
            float tracedWeight = radiance * sampleWeight;
            float mergedSum = tracedWeight + ownWeight;

            keptState.b = ownState.b + 1.0;

            if (tracedWeight > 0.0 && giRandom() * mergedSum < tracedWeight) {
                if (tracedShare > 0.0) keptState.rg = vec2(radiance, mergedSum / (keptState.b * radiance * tracedShare));
            } else {
                keptPoint = ownPoint;

                if (ownState.r * ownShare > 0.0) keptState.rg = vec2(ownState.r, mergedSum / (keptState.b * ownState.r * ownShare));
            }
        }

        if (any(isnan(keptPoint)) || any(isinf(keptPoint)) || any(isnan(keptState)) || any(isinf(keptState))) {
            keptPoint = vec4(0.0);
            keptState = vec4(0.0);
        }

        imageStore(gi_far_img, reusePixel + ivec2(farSize.x, 0), keptPoint);
        imageStore(gi_far_img, reusePixel + ivec2(farSize.x * 2, 0), keptState);

        if (darkTurn) {
            gi = vec4(0.0);
            blockLuminance = 0.0;
        }

        float blendStep = reprojected ? (reuseParity ? 2.0 : 0.0) : 1.0;
        float traceStep = reuseTurn ? 0.0 : (reprojected ? 2.0 : 1.0);
        #else
        const float blendStep = 1.0;
        const float traceStep = 1.0;
        #endif

        weakest = slotWeights[1] < slotWeights[0] ? 1 : 0;
        weakest = slotWeights[2] < slotWeights[weakest] ? 2 : weakest;

        if (candidateWeight > 0.0) {
            if (slotWeights[0] > 0.0 && candidateCell == slotCells[0]) {
                slotWeights[0] += candidateWeight;
            } else if (slotWeights[1] > 0.0 && candidateCell == slotCells[1]) {
                slotWeights[1] += candidateWeight;
            } else if (slotWeights[2] > 0.0 && candidateCell == slotCells[2]) {
                slotWeights[2] += candidateWeight;
            } else if (giRandom() * (slotWeights[weakest] + candidateWeight) < candidateWeight) {
                slotCells[weakest] = candidateCell;
                slotWeights[weakest] = candidateWeight;
            }
        }

        gi *= sampleWeight;
        blockLuminance *= sampleWeight;
        inverseHitDistance *= sampleWeight;

        float farLength = min(historyFar.a, accumulationLength * 8.0);
        bool stray = blockLuminance > 0.0 && dot(gi.rgb, luminance) > 16.0 * dot(historyGi.rgb, luminance);
        vec3 farLight = mix(historyFar.rgb, stray ? gi.rgb : vec3(0.0), min(blendStep / min(farLength + 31.0, clamp(history.g, 0.0, accumulationLength) + 1.0), 1.0));

        imageStore(gi_far_img, min(ivec2(gl_FragCoord.xy), farSize - 1) + farWrite, vec4(farLight, farLength + blendStep));

        if (stray) {
            gi.rgb = vec3(0.0);
            blockLuminance = 0.0;
        }

        vec3 farShown = (farLight + farSpread.rgb) / (1.0 + farSpread.a);

        gi.rgb += farShown;
        blockLuminance += dot(farShown, luminance);

        float guideSample = insideBox ? radiance * sampleWeight : 0.0;

        historyLength = clamp(history.g, 0.0, accumulationLength);
        gi = mix(historyGi, gi, min(blendStep / (historyLength + 1.0), 1.0));
        blockLuminance = mix(max(history.b, 0.0), blockLuminance, min(blendStep / (historyLength + 1.0), 1.0));
        inverseHitDistance = mix(clamp(history.a, 1.0 / 32.25, 4.0), inverseHitDistance, min(traceStep / (historyLength + 1.0), 1.0));
        guideSample = mix(guideLuminance, guideSample, min(traceStep / (historyLength + 1.0), 1.0));

        vec4 trackState = floodNow < 0.0 ? vec4(0.0, 0.0, 0.0, -1.0) : vec4(historyTrack.a < 0.0 ? floodNow : mix(historyTrack.r, floodNow, min(blendStep / (historyLength + 1.0), 1.0)), 0.0, 0.0, 1.0);
        uvec4 guideState = uvec4(0u, 0u, 0u, floatBitsToUint(guideSample) & ~7u);

        for (int i = 0; i < 3; i++) {
            guideState[i] = giGuidePack(slotCells[i], slotWeights[i], giRandom());

            if (inVolume && guideState[i] != 0u && giCellEmits(giGuideCell(guideState[i]))) guideState.a |= 1u << uint(i);
        }

        imageStore(gi_guide_img, guidePixel, inVolume ? guideState : uvec4(0u));
        imageStore(gi_far_img, min(ivec2(gl_FragCoord.xy), farSize - 1) + farWrite + trackColumn, trackState);

        #ifdef GI_REUSE
        if (history.g > 32.0 && ((int(gl_FragCoord.x) + int(gl_FragCoord.y) + frameCounter) & 7) == 0) {
            imageStore(gi_far_img, storeTexel, gi);
            imageStore(gi_far_img, storeTexel + ivec2(1, 0), vec4(storeCheck, blockLuminance, inverseHitDistance, trackState.a < 0.0 ? 0.0 : trackState.r + 0.000001));
        }
        #endif

        historyLength = clamp(history.g, 0.0, historyCap) + 1.0;
    } else {
        imageStore(gi_guide_img, min(ivec2(gl_FragCoord.xy), imageSize(gi_guide_img) - 1), uvec4(0u));
        imageStore(gi_far_img, min(ivec2(gl_FragCoord.xy), farSize - 1) + farWrite, vec4(0.0));
        imageStore(gi_far_img, min(ivec2(gl_FragCoord.xy), farSize - 1) + farWrite + trackColumn, vec4(0.0, 0.0, 0.0, -1.0));

        #ifdef GI_REUSE
        imageStore(gi_far_img, min(ivec2(gl_FragCoord.xy), farSize - 1) + farWrite + ivec2(farSize.x, 0), vec4(0.0));
        imageStore(gi_far_img, min(ivec2(gl_FragCoord.xy), farSize - 1) + farWrite + ivec2(farSize.x * 2, 0), vec4(0.0));
        #endif
    }

    /* RENDERTARGETS: 14,15 */
    gl_FragData[0] = gi;
    gl_FragData[1] = vec4(-viewPos.z, historyLength, blockLuminance, max(inverseHitDistance, 0.001)) * (1.0 - 2.0 * vec4(face & 1, (face >> 1) & 1, 0, face >> 2));
}

#endif

#ifdef VSH

out vec2 texCoord;

void main() {
    texCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;

    gl_Position = ftransform();
}

#endif
