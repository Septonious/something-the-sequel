// CLOUD-SHADOW DOMAIN, independent of the local-light voxelization cube.
// Project a receiver toward the atmospheric cloud layer, sample large-scale
// coverage noise, then fade at the *cloud render domain* edge.
#ifndef CLOUD_SHADOWS_GLSL
#define CLOUD_SHADOWS_GLSL

//Cloud shadows use the same horizontal coverage domain as the volumetric
//clouds, but only one texture sample rather than a density raymarch.
uniform sampler2D cloudNoiseSampler;
uniform float cloudRain;

// Translate the cloud density/coverage field into opaque cloud fraction.
float getCloudShadowCoverage(vec2 noisePos) {
    vec2 coverageUv = noisePos * VC_COVERAGE_SCALE;

    //The prefiltered G channel follows the same R coverage without fine detail samples.
    float coverageNoise = texture2D(cloudNoiseSampler, coverageUv).g;
    float coverageBias = 0.50 - cloudRain * 0.45 - VC_CLOUD_COVERAGE * 0.75;
    float attenuation = smoothstep(0.025, 1.0, 0.35);
    float coverageThreshold = coverageBias + (1.0 - clamp(coverageBias, 0.0, 1.0)) * attenuation;

    return smoothstep(coverageThreshold - VC_SHADOW_SOFTNESS, coverageThreshold + VC_SHADOW_SOFTNESS, coverageNoise);
}

// Project the surface point through the sun vector to the cloud altitude.
float getCloudShadowOcclusion(vec3 worldPos, vec3 lightDirection) {
    float lightHeight = lightDirection.y;
    float cloudHeight = VC_CLOUD_HEIGHT + VC_CLOUD_THICKNESS * VC_CLOUD_BODY_SCALE * 0.35;
    if (worldPos.y >= cloudHeight || lightHeight <= 0.015) return 0.0;

    //Projection from the receiving surface to the occupied cloud layer.
    vec2 shadowPos = worldPos.xz + lightDirection.xz * ((cloudHeight - worldPos.y) / lightHeight);
    float horizontalScale = VC_SOURCE_DEPTH / VC_CLOUD_THICKNESS / max(VC_CLOUD_SIZE, 0.1);
    vec2 windDirection = vec2(cos(radians(VC_WIND_ANGLE)), sin(radians(VC_WIND_ANGLE)));
    vec2 noisePos = shadowPos * horizontalScale * VC_SOURCE_SCALE + windDirection * frameTimeCounter * VC_CLOUD_SPEED * 0.02;

    // Cloud shadows are independent of the terrain shadow-map distance. Fade
    // only at the visible cloud domain boundary, never at the voxel cube.
    float cloudDistance = length(shadowPos - cameraPosition.xz);
    float rangeFade = 1.0 - smoothstep(VC_CLOUD_MAX_DISTANCE * 0.80, VC_CLOUD_MAX_DISTANCE, cloudDistance);
    return getCloudShadowCoverage(noisePos) * rangeFade;
}

// Scale atmospheric occlusion by sun elevation and the user strength control.
float getCloudShadow(vec3 worldPos, vec3 lightDirection) {
    float visibility = smoothstep(0.10, 0.22, lightDirection.y) * shadowFade;
    return 1.0 - getCloudShadowOcclusion(worldPos, lightDirection) * VC_SHADOW_STRENGTH * visibility;
}

#endif
