// LEGACY SCREEN-SPACE AO: eight directions and three depth samples per ray.
// This modulates ambient shading only. Depth discontinuities may affect SSAO
// Horizon estimate with depth-derived view-space surface normals.
float getSSAO(vec3 viewPos, vec2 coord, float angleDither, float stepDither) {
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

    float radius = min(2.0, 0.3 * -viewPos.z / projectionScale.y);
    vec2 sampleStep = projectionScale * radius / -viewPos.z;
    float occlusion = 0.0;

    for (int i = 0; i < 8; i++) {
        float angle = (float(i) + angleDither) * 0.78539816;
        vec2 direction = vec2(cos(angle), sin(angle)) * sampleStep;
        float horizon = 0.0;

        for (int j = 0; j < 3; j++) {
            vec2 sampleCoord = coord + direction * ((float(j) + stepDither) / 3.0);
            if (clamp(sampleCoord, 0.0, 1.0) != sampleCoord) break;

            sampleCoord = (floor(sampleCoord * viewSize) + 0.5) / viewSize;
            vec3 sampleOffset = ToView(vec3(sampleCoord, texture2D(depthtex0, sampleCoord).r)) - viewPos;
            float sampleDistance = length(sampleOffset);
            float sine = clamp(dot(sampleOffset, normal) / max(sampleDistance, 0.001) - 0.05, 0.0, 1.0);
            float occluder = sine * sine * clamp((radius - sampleDistance) / (radius * 0.4), 0.0, 1.0);
            if (occluder > horizon) {
                if (texture2D(colortex11, sampleCoord).r > 0.5) occluder *= 0.3;
                horizon = max(horizon, occluder);
            }
        }

        occlusion += horizon;
    }

    return pow(max(1.0 - occlusion / 8.0, 0.0), AO_STRENGTH * 3.0);
}
