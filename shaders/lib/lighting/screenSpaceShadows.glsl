vec3 getScreenSpaceShadowViewPos(vec2 uv, vec2 projectionScale, vec4 inverseDepth) {
    float ndcDepth = texture2D(depthtex0, uv).r * 2.0 - 1.0;
    float viewZ = (inverseDepth.x * ndcDepth + inverseDepth.z) / (inverseDepth.y * ndcDepth + inverseDepth.w);

    return vec3((uv - 0.5) / projectionScale * -viewZ, viewZ);
}

vec4 getScreenSpaceShadowScenePos(vec3 rayPos, vec2 projectionScale, vec4 inverseDepth, vec2 viewSize) {
    vec2 sampleUv = (floor((projectionScale * rayPos.xy / -rayPos.z + 0.5) * viewSize) + 0.5) / viewSize;
    float sceneDepth = texture2D(depthtex0, sampleUv).r;
    float ndcDepth = sceneDepth * 2.0 - 1.0;
    float sceneZ = (inverseDepth.x * ndcDepth + inverseDepth.z) / (inverseDepth.y * ndcDepth + inverseDepth.w);

    return vec4((sampleUv - 0.5) / projectionScale * -sceneZ, sceneZ, float(sceneDepth > 0.56 && sceneDepth < 1.0));
}

bool isScreenSpaceShadowSceneInFront(vec4 scenePos, vec3 rayPos, vec3 receiverPos, vec3 receiverNormal) {
    return scenePos.w > 0.5 && scenePos.z > rayPos.z && abs(dot(receiverNormal, scenePos.xyz - receiverPos)) > -rayPos.z * 0.002;
}

float getScreenSpaceShadow(vec3 viewPos, float dither) {
    vec2 projectionScale = vec2(gbufferProjection[0].x, gbufferProjection[1].y) * 0.5;
    vec4 inverseDepth = vec4(gbufferProjectionInverse[2].zw, gbufferProjectionInverse[3].zw);
    vec3 rayVector = lightVec * (0.5 + length(viewPos) * 0.04);
    vec3 previousRayPos = viewPos;
    bool previousSceneInFront = false;

    vec2 viewSize = vec2(textureSize(depthtex0, 0));
    vec2 pixelSize = 1.0 / viewSize;
    vec3 receiverPos = getScreenSpaceShadowViewPos(texCoord, projectionScale, inverseDepth);
    vec3 rightOffset = getScreenSpaceShadowViewPos(texCoord + vec2(pixelSize.x, 0.0), projectionScale, inverseDepth) - receiverPos;
    vec3 leftOffset = receiverPos - getScreenSpaceShadowViewPos(texCoord - vec2(pixelSize.x, 0.0), projectionScale, inverseDepth);
    vec3 upOffset = getScreenSpaceShadowViewPos(texCoord + vec2(0.0, pixelSize.y), projectionScale, inverseDepth) - receiverPos;
    vec3 downOffset = receiverPos - getScreenSpaceShadowViewPos(texCoord - vec2(0.0, pixelSize.y), projectionScale, inverseDepth);
    vec3 receiverNormal = normalize(cross(abs(rightOffset.z) < abs(leftOffset.z) ? rightOffset : leftOffset, abs(upOffset.z) < abs(downOffset.z) ? upOffset : downOffset));

    for (int i = 0; i < 16; i++) {
        float rayScale = (float(i) + dither) / 16.0;
        vec3 rayPos = viewPos + rayVector * (rayScale * rayScale);
        if (rayPos.z > -near) break;

        vec2 rayUv = projectionScale * rayPos.xy / -rayPos.z + 0.5;
        if (rayUv.x < 0.0 || rayUv.x > 1.0 || rayUv.y < 0.0 || rayUv.y > 1.0) break;

        vec4 scenePos = getScreenSpaceShadowScenePos(rayPos, projectionScale, inverseDepth, viewSize);
        bool sceneInFront = isScreenSpaceShadowSceneInFront(scenePos, rayPos, receiverPos, receiverNormal);
        if (sceneInFront) {
            if (scenePos.z < max(previousRayPos.z, rayPos.z) + 0.02 - rayPos.z * 0.004) return 0.0;

            if (!previousSceneInFront) {
                vec3 behindRayPos = previousRayPos;
                vec3 frontRayPos = rayPos;
                for (int j = 0; j < 4; j++) {
                    vec3 middleRayPos = (behindRayPos + frontRayPos) * 0.5;
                    vec4 middleScenePos = getScreenSpaceShadowScenePos(middleRayPos, projectionScale, inverseDepth, viewSize);
                    if (middleScenePos.w > 0.5 && middleScenePos.z > middleRayPos.z) frontRayPos = middleRayPos;
                    else behindRayPos = middleRayPos;
                }

                vec4 frontScenePos = getScreenSpaceShadowScenePos(frontRayPos, projectionScale, inverseDepth, viewSize);
                if (isScreenSpaceShadowSceneInFront(frontScenePos, frontRayPos, receiverPos, receiverNormal) && frontScenePos.z < max(behindRayPos.z, frontRayPos.z) + 0.02 - frontRayPos.z * 0.004) return 0.0;
            }
        }

        previousSceneInFront = sceneInFront;
        previousRayPos = rayPos;
    }

    return 1.0;
}
