float getScreenSpaceShadow(vec3 viewPos, float dither) {
    vec3 rayStep = lightVec * ((0.5 + length(viewPos) * 0.04) / 12.0);
    vec3 rayPos = viewPos + rayStep * dither;

    for (int i = 0; i < 12; i++) {
        if (rayPos.z > -near) break;

        vec3 rayScreenPos = ToScreen(rayPos);
        if (rayScreenPos.x < 0.0 || rayScreenPos.x > 1.0 || rayScreenPos.y < 0.0 || rayScreenPos.y > 1.0) break;

        float sceneDepth = texture2D(depthtex0, rayScreenPos.xy).r;
        if (sceneDepth > 0.56 && sceneDepth < 1.0) {
            float depthDifference = ToView(vec3(rayScreenPos.xy, sceneDepth)).z - rayPos.z;
            if (depthDifference > 0.02 - rayPos.z * 0.004 && depthDifference < 0.5 - rayPos.z * 0.05) return 0.0;
        }

        rayPos += rayStep;
    }

    return 1.0;
}
