float getScreenSpaceShadow(vec3 viewPos, float dither) {
    vec2 projectionScale = vec2(gbufferProjection[0].x, gbufferProjection[1].y) * 0.5;
    vec4 inverseDepth = vec4(gbufferProjectionInverse[2].zw, gbufferProjectionInverse[3].zw);
    vec3 rayStep = lightVec * ((0.5 + length(viewPos) * 0.04) / 12.0);
    vec3 rayPos = viewPos + rayStep * dither;

    for (int i = 0; i < 12; i++) {
        if (rayPos.z > -near) break;

        vec2 rayUv = projectionScale * rayPos.xy / -rayPos.z + 0.5;
        if (rayUv.x < 0.0 || rayUv.x > 1.0 || rayUv.y < 0.0 || rayUv.y > 1.0) break;

        float sceneDepth = texture2D(depthtex0, rayUv).r;
        if (sceneDepth > 0.56 && sceneDepth < 1.0) {
            float ndcDepth = sceneDepth * 2.0 - 1.0;
            float depthDifference = (inverseDepth.x * ndcDepth + inverseDepth.z) / (inverseDepth.y * ndcDepth + inverseDepth.w) - rayPos.z;
            if (depthDifference > 0.02 - rayPos.z * 0.004 && depthDifference < 0.5 - rayPos.z * 0.05) return 0.0;
        }

        rayPos += rayStep;
    }

    return 1.0;
}
