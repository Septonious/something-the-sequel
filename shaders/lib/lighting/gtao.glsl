// GTAO (screen-space horizon integration), entirely separate from voxel occupancy.
// Reconstructs view normals from depth derivatives; samples three angular
// slices, each with twelve depth taps and a 32-sector occlusion bit mask.
// Cost scales with shaded pixels, not with nearby block-light emitters.
// Exact GLSL 1.30-compatible 32-bit population count (SWAR).
// SWAR population count; name is historical, not evidence LPV fog is active.
int lpvPopcount32(uint bits) {
    bits -= (bits >> 1u) & 0x55555555u;
    bits = (bits & 0x33333333u) + ((bits >> 2u) & 0x33333333u);
    bits = (bits + (bits >> 4u)) & 0x0F0F0F0Fu;
    bits += bits >> 8u;
    bits += bits >> 16u;
    return int(bits & 63u);
}

// Return approximate ambient visibility; never use this as a DDA hard-shadow test.
float getGTAO(vec3 viewPos, vec2 coord, float sliceDither, float stepDither) {
    vec2 viewSize = vec2(textureSize(depthtex0, 0));
    vec2 pixelSize = 1.0 / viewSize;
    vec2 projectionScale = 0.5 / vec2(gbufferProjectionInverse[0].x, gbufferProjectionInverse[1].y);

    vec2 rightCoord = coord + vec2(pixelSize.x, 0.0);
    vec2 leftCoord = coord - vec2(pixelSize.x, 0.0);
    vec2 upCoord = coord + vec2(0.0, pixelSize.y);
    vec2 downCoord = coord - vec2(0.0, pixelSize.y);
    vec3 rightOffset = ToView(vec3(rightCoord, texture2D(depthtex0, rightCoord).r)) - viewPos;
    vec3 leftOffset = viewPos - ToView(vec3(leftCoord, texture2D(depthtex0, leftCoord).r));
    vec3 upOffset = ToView(vec3(upCoord, texture2D(depthtex0, upCoord).r)) - viewPos;
    vec3 downOffset = viewPos - ToView(vec3(downCoord, texture2D(depthtex0, downCoord).r));
    vec3 normal = normalize(cross(abs(rightOffset.z) < abs(leftOffset.z) ? rightOffset : leftOffset, abs(upOffset.z) < abs(downOffset.z) ? upOffset : downOffset));
         normal = faceforward(normal, viewPos, normal);
    vec3 viewDir = normalize(-viewPos);

    float radius = min(2.0, 0.3 * -viewPos.z / projectionScale.y);
    float visibility = 0.0;

    for (int i = 0; i < 3; i++) {
        float sliceAngle = (float(i) + sliceDither) * 1.04719755;
        vec3 sliceDirection = vec3(cos(sliceAngle), sin(sliceAngle), 0.0);
        vec3 sliceTangent = normalize(sliceDirection - dot(sliceDirection, viewDir) * viewDir);
        vec3 sliceAxis = cross(viewDir, sliceTangent);
        vec3 projectedNormal = normal - sliceAxis * dot(normal, sliceAxis);
        float normalAngle = atan(dot(projectedNormal, sliceTangent), max(dot(projectedNormal, viewDir), 0.000001));
        float sinNormal = sin(normalAngle);
        float cosNormal = cos(normalAngle);
        float lowerWeight = 0.5 * (cosNormal + (normalAngle - 1.57079633) * sinNormal);
        float sliceWeight = cosNormal + normalAngle * sinNormal;

        vec2 sliceStep = sliceDirection.xy * projectionScale * radius / -viewPos.z;
        float minStepScale = 1.5 / length(sliceStep * viewSize);
        uint occludedSectors = 0u;

        for (int j = 0; j < 12; j++) {
            float stepScale = (float(j / 2) + stepDither) / 6.0;
            vec2 sampleCoord = coord + sliceStep * (max(stepScale * stepScale, minStepScale) * float(j % 2 * 2 - 1));
            if (clamp(sampleCoord, 0.0, 1.0) != sampleCoord) continue;

            sampleCoord = (floor(sampleCoord * viewSize) + 0.5) / viewSize;
            vec3 sampleOffset = ToView(vec3(sampleCoord, texture2D(depthtex0, sampleCoord).r)) - viewPos;
            float sampleDistance = length(sampleOffset);
            float weight = clamp((radius - sampleDistance) / (radius * 0.4), 0.0, 1.0) * clamp(dot(sampleOffset, normal) * 16.0 / sampleDistance, 0.0, 1.0);
            if (weight <= 0.0) continue;

            float tangentOffset = dot(sampleOffset, sliceTangent);
            float viewOffset = dot(sampleOffset, viewDir);
            float backAngle = texture2D(colortex11, sampleCoord).r > 0.5 ? atan(tangentOffset, viewOffset - 0.1) : sign(tangentOffset) * 3.14159265;
            vec2 angles = clamp(vec2(atan(tangentOffset, viewOffset), backAngle), normalAngle - 1.57079633, normalAngle + 1.57079633);
            vec2 sectors = (lowerWeight + sign(angles) * 0.25 * (cosNormal - cos(2.0 * angles - normalAngle) + 2.0 * angles * sinNormal)) / sliceWeight;
                 sectors.y = mix(sectors.x, sectors.y, weight);

            uint sectorStart = uint(round(min(sectors.x, sectors.y) * 32.0));
            uint sectorCount = uint(round(max(sectors.x, sectors.y) * 32.0)) - sectorStart;
            if (sectorCount > 0u) occludedSectors |= (0xFFFFFFFFu >> (32u - sectorCount)) << sectorStart;
        }

        visibility += length(projectedNormal) * sliceWeight * (1.0 - float(lpvPopcount32(occludedSectors)) / 32.0);
    }

    return pow(max(visibility / 3.0, 0.0), AO_STRENGTH * 2.0);
}
