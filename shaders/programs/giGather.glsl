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

vec4 giScreenTrace(vec3 viewPos, vec3 viewNormal, vec3 viewDirection) {
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
            vec3 radiance = max(pow(max(texture2D(colortex0, rayCoord).rgb, vec3(0.0)), vec3(2.2)) - texture2D(colortex10, rayCoord).rgb / (1.0 - sceneSurface.r * 0.35), vec3(0.0));

            if (clamp(previousCoord, 0.0, 1.0) == previousCoord && abs(abs(texelFetch(colortex15, previousTexel, 0).r) + previousView.z) < 0.1 - previousView.z * 0.05) {
                vec3 receptor = texture2D(colortex13, rayCoord).rgb;
                vec4 previousGi = max(texelFetch(colortex14, previousTexel, 0), vec4(0.0));

                radiance += receptor * receptor * (previousGi.rgb * GI_MULTI_BOUNCE + ambientCol * (previousGi.a * clamp(sceneSurface.g * 8.0, 0.0, 1.0) * (1.0 - sceneSurface.b)));
            }

            return vec4(radiance, length(toScene));
        }
    }
    #endif

    return vec4(0.0, 0.0, 0.0, -1.0);
}

vec4 giSceneRadiance(vec3 viewPos, vec3 worldNormal, vec3 origin, vec3 direction) {
    vec4 screenHit = giScreenTrace(viewPos, mat3(gbufferModelView) * worldNormal, mat3(gbufferModelView) * direction);

    return screenHit.a >= 0.0 ? vec4(screenHit.rgb, 0.0) : giTraceRadiance(origin, direction, mat3(gbufferModelViewInverse) * lightVec);
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

    return dot(vec3(lessThan(origin, low)) + vec3(greaterThan(origin, high)), extent.yzx * extent.zxy);
}

float giGuideDensity(vec3 origin, vec3 direction, vec3 low, vec3 high, float area) {
    vec3 slope = direction + vec3(lessThan(abs(direction), vec3(0.000001))) * 0.000002;
    vec3 planeA = (low - origin) / slope;
    vec3 planeB = (high - origin) / slope;
    vec3 enter = min(planeA, planeB);
    vec3 leave = max(planeA, planeB);
    float reach = max(enter.x, max(enter.y, enter.z));

    if (reach <= 0.0 || reach > min(leave.x, min(leave.y, leave.z))) return 0.0;

    float facing = reach == enter.x ? abs(direction.x) : (reach == enter.y ? abs(direction.y) : abs(direction.z));

    return reach * reach / (max(facing, 0.000001) * area);
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

    if (z0 > 0.56 && z0 < 1.0 && isInsideVoxelVolume(voxelPos)) {
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
        float historyWeight = 0.0;

        face = giFace(worldNormal);

        if (clamp(previousCoord, 0.0, 1.0) == previousCoord) {
            ivec2 historySize = textureSize(colortex14, 0);
            vec2 historyPos = previousCoord * vec2(historySize) - 0.5;
            ivec2 historyBase = ivec2(floor(historyPos));
            vec2 historyBlend = historyPos - vec2(historyBase);

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

                if (giStoredFace(tapSurface) != face || abs(dot(tapPos - previousView.xyz, previousNormal)) >= 0.005 - previousView.z * 0.002 || any(isnan(tapSurface)) || any(isnan(tapGi)) || any(isinf(tapGi))) continue;

                vec4 tapFar = imageLoad(gi_far_img, min(tap, imageSize(gi_far_img) - 1));

                history += abs(tapSurface) * weight;
                historyGi += tapGi * weight;
                historyWeight += weight;

                if (!(any(isnan(tapFar)) || any(isinf(tapFar)))) historyFar += tapFar * weight;
            }
        }

        bool reprojected = historyWeight > 0.0;

        if (reprojected) {
            history /= historyWeight;
            historyGi /= historyWeight;
            historyFar /= historyWeight;
        } else {
            int seeds = clamp(previousCoord, 0.0, 1.0) == previousCoord ? 1 : 2;

            for (int i = 0; i < seeds; i++) {
                vec3 seedDirection, seedLampDirection;
                vec2 seedWeights = giLampedDirections(origin, worldNormal, seedDirection, seedLampDirection);

                historyGi += giSceneRadiance(viewPos, worldNormal, origin, seedDirection) * (seedWeights.x / float(seeds));

                if (seedWeights.y > 0.0) historyGi += giSceneRadiance(viewPos, worldNormal, origin, seedLampDirection) * (seedWeights.y / float(seeds));
            }

            if (any(isnan(historyGi)) || any(isinf(historyGi))) historyGi = vec4(0.0, 0.0, 0.0, 1.0);

            history = vec4(0.0, 4.0, 0.0, 1.0 / 32.25);
            giPassLight = vec3(0.0);
            giHitBlockLuminance = 0.0;
        }

        ivec2 guideSize = imageSize(gi_guide_img);
        ivec2 guidePixel = min(ivec2(gl_FragCoord.xy), guideSize - 1);
        ivec3 cellShift = ivec3(floor(previousCameraPosition) - floor(cameraPosition));
        uvec4 guide = reprojected ? imageLoad(gi_guide_img, min(ivec2(previousCoord * vec2(guideSize)), guideSize - 1)) : uvec4(0u);
        float offsetX = giRandom();
        float offsetY = giRandom();
        ivec2 neighbourPixel = clamp(guidePixel + ivec2((vec2(offsetX, offsetY) - 0.5) * (history.g > 24.0 ? 24.0 : 96.0)), ivec2(0), guideSize - 1);
        uvec4 neighbour = imageLoad(gi_guide_img, neighbourPixel);

        if (!reprojected) {
            vec4 nearFar = imageLoad(gi_far_img, min(neighbourPixel, imageSize(gi_far_img) - 1));

            if (nearFar.a > 8.0 && !any(isnan(nearFar))) historyFar.rgb = historyGi.rgb * clamp(dot(nearFar.rgb, luminance) / max(dot(texelFetch(colortex14, min(neighbourPixel, textureSize(colortex14, 0) - 1), 0).rgb, luminance), 0.000001), 0.0, 0.5);
        }
        float guideLuminance = uintBitsToFloat(guide.a);
        ivec3 slotCells[3];
        float slotWeights[3];
        int weakest = 0;
        int strongest = 0;

        if (isnan(guideLuminance) || isinf(guideLuminance)) guideLuminance = 0.0;

        for (int i = 0; i < 3; i++) {
            slotCells[i] = giGuideCell(guide[i]) + cellShift;
            slotWeights[i] = giGuideWeight(guide[i]) * 0.98;

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
        float boxAreas[3];
        float boxWeights[3];
        float boxTotal = 0.0;
        float guideProbability = 0.0;

        for (int i = 0; i < 3; i++) {
            boxAreas[i] = giGuideBox(slotCells[i], origin, worldNormal, boxLow[i], boxHigh[i]);
            boxWeights[i] = slotWeights[i] > 0.0 && boxAreas[i] > 0.0 ? slotWeights[i] : 0.0;
            boxTotal += boxWeights[i];
        }

        if (boxTotal > 0.0) guideProbability = clamp(guideLuminance / max(dot(historyGi.rgb, luminance) * GI_STRENGTH + historyGi.a * dot(ambientCol, luminance), 0.000001), reprojected && history.g > 32.0 ? 0.015625 : 0.5, 0.5);

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
                vec3 faceAreas = (vec3(lessThan(origin, boxLow[chosen])) + vec3(greaterThan(origin, boxHigh[chosen]))) * extent.yzx * extent.zxy;
                float facePick = giRandom() * boxAreas[chosen];
                int axis = faceAreas.z > 0.0 ? 2 : (faceAreas.y > 0.0 ? 1 : 0);

                if (facePick < faceAreas.x + faceAreas.y && faceAreas.y > 0.0) axis = 1;
                if (facePick < faceAreas.x) axis = 0;

                vec3 target = boxLow[chosen] + extent * (axis == 0 ? vec3(0.0, point) : (axis == 1 ? vec3(point.x, 0.0, point.y) : vec3(point, 0.0)));

                target[axis] = origin[axis] < boxLow[chosen][axis] ? boxLow[chosen][axis] : boxHigh[chosen][axis];

                vec3 toTarget = target - origin;

                direction = normalize(toTarget);
                chosenDensity = dot(toTarget, toTarget) / (max(abs(direction[axis]), 0.000001) * boxAreas[chosen]);
            }

            float facing = max(dot(worldNormal, direction), 0.0);
            float cosinePdf = facing * facing > 0.001999 ? (2.0 * facing * facing - 0.001999) / (6.27690212 * sqrt(facing * facing - 0.001999)) : 0.0;
            float boxDensity = 0.0;

            for (int i = 0; i < 3; i++) {
                if (boxWeights[i] > 0.0) boxDensity += boxWeights[i] * (i == chosen ? chosenDensity : giGuideDensity(origin, direction, boxLow[i], boxHigh[i], boxAreas[i]));
            }

            insideBox = boxDensity > 0.0;
            sampleWeight = cosinePdf > 0.0 ? cosinePdf / mix(cosinePdf, boxDensity / boxTotal, guideProbability) : 0.0;
        }

        ivec3 hitCell, hitFace = ivec3(0);
        float hitDistance;
        uint hitWord;
        vec4 screenHit = sampleWeight > 0.0 ? giScreenTrace(viewPos, mat3(gbufferModelView) * worldNormal, mat3(gbufferModelView) * direction) : vec4(0.0, 0.0, 0.0, -1.0);
        bool hit = screenHit.a >= 0.0;

        if (hit) {
            gi = vec4(screenHit.rgb, 0.0);
            hitDistance = screenHit.a;
            inverseHitDistance = 1.0 / (hitDistance + 0.25);
        } else if (sampleWeight > 0.0 && giTrace(origin, direction, ivec3(-1), hitCell, hitFace, hitDistance, hitWord)) {
            hit = true;
            gi = vec4(giHitRadiance(hitCell, hitFace, origin + direction * hitDistance, hitWord, mat3(gbufferModelViewInverse) * lightVec), 0.0);
            blockLuminance = giHitBlockLuminance;
            inverseHitDistance = 1.0 / (hitDistance + 0.25);
        }

        gi.rgb += giPassLight;
        blockLuminance += dot(giPassLight, luminance);

        if (any(isnan(gi)) || any(isinf(gi))) {
            gi = vec4(0.0, 0.0, 0.0, 1.0);
            blockLuminance = 0.0;
        }

        float radiance = dot(gi.rgb, luminance) * GI_STRENGTH + gi.a * dot(ambientCol, luminance);
        float candidateWeight = radiance * radiance * sampleWeight;
        ivec3 candidateCell = clamp(hit ? ivec3(floor(origin + direction * hitDistance - vec3(hitFace) * 0.01)) : ivec3(origin + direction * 32.0), ivec3(0), ivec3(voxelVolumeSize) - 1);

        if (dot(giPassLight, luminance) * GI_STRENGTH > radiance * 0.5) candidateCell = giPassCell;

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

        float farLength = min(historyFar.a, clamp(0.75 / max(frameTime, 0.001), 31.0, 250.0) * (GI_ACCUMULATION / 0.75) * 8.0);
        bool stray = hit && giHitBlockLuminance > 0.0 && dot(gi.rgb, luminance) > 16.0 * dot(historyGi.rgb, luminance);
        vec3 farLight = mix(historyFar.rgb, stray ? gi.rgb : vec3(0.0), 1.0 / (farLength + 31.0));

        imageStore(gi_far_img, min(ivec2(gl_FragCoord.xy), imageSize(gi_far_img) - 1), vec4(farLight, farLength + 1.0));

        if (stray) {
            gi.rgb = vec3(0.0);
            blockLuminance = 0.0;
        }

        gi.rgb += farLight;
        blockLuminance += dot(farLight, luminance);

        float guideSample = insideBox ? radiance * sampleWeight : 0.0;

        historyLength = clamp(history.g, 0.0, clamp(0.75 / max(frameTime, 0.001), 31.0, 250.0) * (GI_ACCUMULATION / 0.75));
        gi = mix(historyGi, gi, 1.0 / (historyLength + 1.0));
        blockLuminance = mix(max(history.b, 0.0), blockLuminance, 1.0 / (historyLength + 1.0));
        inverseHitDistance = mix(clamp(history.a, 1.0 / 32.25, 4.0), inverseHitDistance, 1.0 / (historyLength + 1.0));
        guideSample = mix(guideLuminance, guideSample, 1.0 / (historyLength + 1.0));

        uvec4 guideState = uvec4(0u, 0u, 0u, floatBitsToUint(guideSample));

        for (int i = 0; i < 3; i++) guideState[i] = giGuidePack(slotCells[i], slotWeights[i], giRandom());

        imageStore(gi_guide_img, guidePixel, guideState);

        historyLength += 1.0;
    } else {
        imageStore(gi_guide_img, min(ivec2(gl_FragCoord.xy), imageSize(gi_guide_img) - 1), uvec4(0u));
        imageStore(gi_far_img, min(ivec2(gl_FragCoord.xy), imageSize(gi_far_img) - 1), vec4(0.0));
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
