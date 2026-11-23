// VOLUMETRIC DIRECTIONAL LIGHT (SUN/MOON), NOT LPV BLOCK-LIGHT FOG.
// Marches a depth-clipped view ray through the directional shadow map and
// cloud coverage. In this final baseline, local-emitter volumetric fog is
// deliberately not active: do not mistake directional rays for LPV fog.
// One depth-clipped, front-to-back raymarch for directional shafts and voxel fog.
// Both sample grids are independent of scene depth; geometry only clips their intervals.
#ifdef VL

#ifdef VL
// Convert an optical-distance sample into warped shadow-map coordinates.
vec3 getVolumetricShadowPosition(vec3 shadowRayStart, vec3 shadowRayDirection, float sampleDistance) {
    vec3 shadowPos = shadowRayStart + shadowRayDirection * sampleDistance;
    float dist = length(shadowPos.xy);
    float distortion = dist * shadowMapBias + (1.0 - shadowMapBias);

    shadowPos.xy /= distortion;
    shadowPos.z *= 0.2;
    shadowPos = shadowPos * 0.5 + 0.5;
    shadowPos.z += 0.0512 / shadowMapResolution;

    return shadowPos;
}

// Guard outside-shadowmap samples before hardware depth comparison.
float getVolumetricShadow(vec3 shadowPos) {
    if (shadowPos.x <= 0.0 || shadowPos.x >= 1.0 || shadowPos.y <= 0.0 || shadowPos.y >= 1.0 || shadowPos.z <= 0.0 || shadowPos.z >= 1.0) return 1.0;
    return shadow2D(shadowtex0, shadowPos).r;
}
#endif

// Integrate scattering/transmittance front-to-back, clipped by scene depth.
void computeVolumetricLight(inout vec3 color, float dither) {
    float depth = texture2D(depthtex0, texCoord).r;
    float visibility = 1.0 - blindFactor;
    #if MC_VERSION >= 11900
          visibility *= 1.0 - darknessFactor;
    #endif
    if (visibility <= 0.001) return;

    //Ray direction is identical for sky and geometry at the same screen position.
    vec3 nViewPos = normalize(ToView(vec3(texCoord, 1.0)));
    vec3 nWorldPos = normalize(mat3(gbufferModelViewInverse) * nViewPos);
    float sceneDistance = depth >= 0.999999 ? 1.0e10 : length(ToView(vec3(texCoord, depth)));
    if (sceneDistance <= 0.01) return;


    #ifdef VL
    vec3 worldLightVec = normalize(mat3(gbufferModelViewInverse) * lightVec);
    float VoL = clamp(dot(nViewPos, lightVec), 0.0, 1.0);
    float vlIntensity = fmix((VoL * VoL * VL_STRENGTH_RATIO + (1.0 - VL_STRENGTH_RATIO)) * (1.0 - timeBrightness), 1.0 + sunVisibility, wetness);
          vlIntensity += pow(VoL, 1.5) * timeBrightness;
          vlIntensity *= 1.0 + pow8(VoL) * (2.0 + pow16(VoL) * 3.0);
          vlIntensity *= fmix(VL_NIGHT * 4.0, fmix(VL_MORNING_EVENING, VL_DAY, timeBrightness), sunVisibility);
          vlIntensity *= VL_STRENGTH * shadowFade * caveFactor * (1.0 + closedSpaceFactor * 0.60);

    vec3 nSkyColor = normalize(skyColor + vec3(0.000001)) * fmix(vec3(1.0), biomeColor, sunVisibility * isSpecificBiome);
    vec3 vlColor = fmix(lightCol, nSkyColor, timeBrightness * 0.75) * vlIntensity * 0.10;
    bool doVolumetricLight = maxOf(vlColor) > 0.0001;

    if (!doVolumetricLight) return;

    #if defined VC_SHADOWS && defined VOLUMETRIC_CLOUDS
    const float vlMaxDistance = 512.0;
    #else
    const float vlMaxDistance = shadowDistance;
    #endif
    float vlRatio = exp2(log2(vlMaxDistance + 1.0) / VL_SAMPLES);
    float vlSegmentStart = 0.0;
    float vlSegmentEnd = 0.0;
    float vlTransmittance = 1.0;
    vec3 scatteredLight = vec3(0.0);

    vec3 shadowRayStart = diagonal3(shadowProjection) * shadowModelView[3].xyz + shadowProjection[3].xyz;
    vec3 shadowRayDirection = diagonal3(shadowProjection) * (mat3(shadowModelView) * nWorldPos);

    #if defined VC_SHADOWS && defined VOLUMETRIC_CLOUDS
    float cloudHeight = VC_CLOUD_HEIGHT + VC_CLOUD_THICKNESS * VC_CLOUD_BODY_SCALE * 0.35;
    float cloudProjection = 1.0 / max(worldLightVec.y, 0.015);
    float cloudScale = VC_SOURCE_DEPTH / VC_CLOUD_THICKNESS / max(VC_CLOUD_SIZE, 0.1) * VC_SOURCE_SCALE;
    vec2 windDirection = vec2(cos(radians(VC_WIND_ANGLE)), sin(radians(VC_WIND_ANGLE)));
    vec2 cloudRayStart = (cameraPosition.xz + worldLightVec.xz * ((cloudHeight - cameraPosition.y) * cloudProjection)) * cloudScale;
         cloudRayStart += windDirection * frameTimeCounter * VC_CLOUD_SPEED * 0.02;
    vec2 cloudRayDirection = (nWorldPos.xz - worldLightVec.xz * nWorldPos.y * cloudProjection) * cloudScale;
    #endif
    #endif

    //A fixed angular sampling schedule covers distant volumetric light rays.
    //The sampling grid is independent of scene depth; geometry clips the ray interval.
    for (int i = 0; i < VL_SAMPLES; i++) {
        float sampleJitter = clamp(fract(dither + float(i) * 0.61803398875), 0.05, 0.95);

        #ifdef VL
        vlSegmentEnd = (vlSegmentEnd + 1.0) * vlRatio - 1.0;
        float vlEnd = min(vlSegmentEnd, sceneDistance);
        float vlStepLength = max(vlEnd - vlSegmentStart, 0.0);

        if (doVolumetricLight && vlStepLength > 0.0) {
            float sampleDistance = mix(vlSegmentStart, vlEnd, sampleJitter);
            vec3 sampleWorldPos = nWorldPos * sampleDistance;
            vec3 samplePosition = sampleWorldPos + cameraPosition;
            float vlStepTransmittance = exp(-0.0075 * vlStepLength);
            float vlStepWeight = vlTransmittance * (1.0 - vlStepTransmittance);
                  vlTransmittance *= vlStepTransmittance;

            #if defined VC_SHADOWS && defined VOLUMETRIC_CLOUDS
            if (samplePosition.y < cloudHeight) {
            #endif
                float shadowDistanceFade = maxOf(abs(sampleWorldPos) / vec3(shadowDistance, shadowDistance + 64.0, shadowDistance));
                      shadowDistanceFade = 1.0 - pow3(clamp(shadowDistanceFade, 0.0, 1.0));
                vec3 directVisibility = vec3(1.0 - closedSpaceFactor * 0.90 * (1.0 - shadowDistanceFade));
                #if defined SHADOW_COLOR && defined VL_COLOR_SHADOWS
                vec3 coloredLight = vec3(0.0);
                #endif

                if (shadowDistanceFade > 0.001) {
                    vec3 shadowPos = getVolumetricShadowPosition(shadowRayStart, shadowRayDirection, sampleDistance);
                    float terrainVisibility = getVolumetricShadow(shadowPos);
                    directVisibility *= mix(1.0, terrainVisibility, shadowDistanceFade);

                    #if defined SHADOW_COLOR && defined VL_COLOR_SHADOWS
                    if (terrainVisibility < 1.0 && wetness < 0.5 && shadowPos.x > 0.0 && shadowPos.x < 1.0 && shadowPos.y > 0.0 && shadowPos.y < 1.0) {
                        float translucentDepth = texture2D(shadowtex1, shadowPos.xy).r;
                        if (translucentDepth > shadowPos.z) {
                            vec3 shadowColor = texture2D(shadowcolor0, shadowPos.xy).rgb;
                            coloredLight += shadowColor * shadowColor * vlIntensity * 0.25 * (1.0 - terrainVisibility) * shadowDistanceFade * (1.0 - wetness);
                        }
                    }
                    #endif
                }

                vec3 vlSample = directVisibility * vlColor;
                #if defined SHADOW_COLOR && defined VL_COLOR_SHADOWS
                      vlSample += coloredLight;
                #endif

                #if defined VC_SHADOWS && defined VOLUMETRIC_CLOUDS
                if (shadowFade > 0.0) {
                    float cloudShadow = getCloudShadowCoverage(cloudRayStart + cloudRayDirection * sampleDistance);
                    vlSample *= 1.0 - pow4(cloudShadow) * shadowFade;
                }
                vlSample *= 1.0 - clamp(samplePosition.y / cloudHeight, 0.0, 1.0);
                #endif

                scatteredLight += vlSample * vlStepWeight;
            #if defined VC_SHADOWS && defined VOLUMETRIC_CLOUDS
            }
            #endif
        }
        vlSegmentStart = vlSegmentEnd;
        #endif

    }

    #ifdef VL
    color += scatteredLight * visibility;
    #endif
}

#endif
