#ifdef VC_SHADOWS
#if defined OVERWORLD && defined VOLUMETRIC_CLOUDS && (defined GBUFFERS_TERRAIN || defined GBUFFERS_BLOCK || defined GBUFFERS_ENTITIES || defined GBUFFERS_TEXTURED || defined GBUFFERS_WATER)
#include "/lib/lighting/cloudShadows.glsl"
#endif
#endif

#if defined VX_SUPPORT && !defined GBUFFERS_BASIC && !defined GBUFFERS_WATER && !defined GBUFFERS_TEXTURED && !defined DH_TERRAIN && !defined DH_WATER
#include "/lib/vx/hybridLPV.glsl"
#endif
vec3 directLighting = vec3(0.0);
vec3 occludableLighting = vec3(0.0);
#if defined GBUFFERS_TERRAIN && defined DDA_DEFER_ACTIVE
vec4 ddaPositionData = vec4(0.0);
vec4 ddaSurfaceData = vec4(0.0);
#endif

// Material shading entry: keep its energy/emission math when altering occluder IDs.
void gbuffersLighting(inout vec4 albedo, in vec3 screenPos, in vec3 viewPos, in vec3 worldPos, in vec3 newNormal, inout vec3 shadow, in vec2 lightmap, 
                      in float NoU, in float NoL, in float NoE,
                      in float subsurface, in float emission, in float smoothness, in float parallaxShadow, in float metalness, in float f0) {
    //Variables
    float lAlbedo = length(albedo.rgb);
    #if defined GBUFFERS_TERRAIN && AO_TYPE == 0 && defined VX_SUPPORT
    float vanillaAo = pow2(getAoLattice(worldPos));
    #else
    float vanillaAo = color.a * color.a;
    #endif
    float emissionMask = clamp(emission, 0.0, 1.0);
    vec3 worldNormal = normalize(mat3(gbufferModelViewInverse) * newNormal);

    //Vanilla Directional Lighting
    float vanillaDiffuse = (0.25 * NoU + 0.75) + (0.667 - abs(NoE)) * (1.0 - abs(NoU)) * 0.15;
          vanillaDiffuse *= vanillaDiffuse;

    #ifdef GBUFFERS_TERRAIN
    NoL = pow(NoL, 1.0 + float(subsurface > 0.5) * 0.5);
    #endif

    // Vanilla block light remains the fallback outside the DDA domain and on unsupported render paths.
    float blockLightMap = pow6(lightmap.x * lightmap.x) * 2.0 + max(lightmap.x - 0.05, 0.0);
    blockLightMap *= blockLightMap * 0.5;
    vec3 blockLighting = blockLightCol * blockLightMap;
    vec3 tracedBlockLighting = vec3(0.0);
    #ifdef OVERWORLD
    blockLighting *= 1.0 - pow4(lightmap.y) * 0.75;
    #endif

    // Direct lighting is evaluated at the actual interpolated surface, not the
    // jittered depth reconstruction or a filtered voxel lighting texture.
    #if !defined GBUFFERS_BASIC && !defined GBUFFERS_WATER && !defined GBUFFERS_TEXTURED && !defined DH_TERRAIN && !defined DH_WATER && defined VX_SUPPORT && DDA_DEBUG < 5
    #ifdef GBUFFERS_HAND
    vec3 voxelPos = worldToVoxel(worldPos);
    #else
    vec3 voxelPos = worldToVoxel(ddaWorldPosition);
    #endif
    vec3 geometryNormal = normalize(mat3(gbufferModelViewInverse) * normal);
    #if (DDA_DEBUG == 1 || DDA_DEBUG == 2) && defined GBUFFERS_TERRAIN
    // Mode 1: material capture just inside the drawn face. Mode 2: receiver
    // cell outside the face (red = blocked). No lighting or normal maps.
    vec3 diagnosticPos = voxelPos + geometryNormal * (DDA_DEBUG == 1 ? -0.01 : 0.002);
    ivec3 diagnosticCell = ivec3(floor(diagnosticPos));
    vec3 diagnostic = vec3(0.0, 0.0, 0.3);
    if (ddaValid(diagnosticCell)) {
        uint code = texelFetch(voxelSampler, diagnosticCell, 0).r;
        diagnostic = code == 0u ? vec3(1.0, 0.0, 1.0) :
            (ddaBlocked(diagnosticCell) ? vec3(1.0, 0.12, 0.05) :
             (maxOf(ddaEmission(code)) > 0.0 ? vec3(1.0, 0.85, 0.0) : vec3(0.05, 0.8, 0.25)));
    }
    albedo.rgb = diagnostic; directLighting = pow(diagnostic, vec3(2.2)); occludableLighting = vec3(0.0); return;
    #endif
    float domain = ddaDomainWeight(voxelPos);
    #if DDA_DEBUG == 3 && defined GBUFFERS_TERRAIN
    vec3 directOnly = ddaLighting(voxelPos, geometryNormal, subsurface > 0.0 ? 1.0 : 0.0, true) * DDA_BRIGHTNESS;
    albedo.rgb = pow(max(directOnly, vec3(0.0)), vec3(1.0 / 2.2));
    directLighting = directOnly; occludableLighting = vec3(0.0); return;
    #endif
    #if DDA_TRACE_VOLUME < 100
    if (domain < 1.0 && isInsideVoxelVolume(voxelPos) && emissionMask < 0.001) {
        blockLighting = mix(blockLighting, hybridLPV(voxelPos,geometryNormal)*DDA_LPV_BRIGHTNESS,hybridLPVWeight(voxelPos));
    }
    #endif
    if (domain > 0.0) {
        #if defined GBUFFERS_TERRAIN && defined DDA_DEFER_ACTIVE
        // A zero conservative region count proves no emitter can contribute.
        ivec3 region = ivec3(floor(voxelPos + geometryNormal * 0.002)) >> 3;
        if (isInsideVoxelVolume(vec3(region * 8)) && texelFetch(ddaLocalSampler, ivec3(region.x,region.y*33,region.z),0).r != 0u) {
            ddaPositionData = vec4(voxelPos, gl_FragCoord.z);
            ddaSurfaceData = vec4(pow(albedo.rgb, vec3(2.2)) * (1.0-metalness) * vanillaDiffuse * (DDA_BRIGHTNESS * domain), ddaEncodeNormal(geometryNormal, subsurface > 0.0));
        }
        #else
        vec3 directBlock = ddaLighting(voxelPos, geometryNormal, subsurface > 0.0 ? 1.0 : 0.0, true);
        tracedBlockLighting = directBlock * (DDA_BRIGHTNESS * domain);
        #endif
        blockLighting *= 1.0 - domain;
    }
    #endif

    //Shadow Calculations
    //Some code made by Emin and gri573
    float shadowVisibility = maxOf(abs(worldPos) / (vec3(shadowDistance, shadowDistance + 64.0, shadowDistance)));
          shadowVisibility = clamp(shadowVisibility, 0.0, 1.0);
          shadowVisibility = 1.0 - pow3(shadowVisibility);

    float shadowRange = shadowVisibility;

          #ifdef OVERWORLD
          shadowVisibility *= caveFactor;
          #endif

    //Subsurface scattering
    float VoL = clamp(dot(normalize(viewPos), lightVec), 0.0, 1.0);
    float sss = 0.0;

    if (subsurface > 0.0) {
        sss = pow8(VoL) * shadowFade * (1.0 - wetness * 0.5);
        NoL += subsurface * shadowVisibility * (1.0 + sss) * 0.5;
    }

    //Scene Lighting
    #ifndef NETHER
    vec3 fakeShadow = getFakeShadow(lightmap.y);

    if (NoL > 0.0001 && (shadowVisibility > 0.0 || shadowRange * fakeShadow.x > 0.0)) {
        float lightmapS = lightmap.y * lightmap.y * (3.0 - 2.0 * lightmap.y);

        vec3 worldPosM = worldPos;
        vec2 shadowDepthGradient = vec2(0.0);
        float shadowDepthBias = 0.0;

        #ifdef GBUFFERS_TEXTURED
            vec3 centerWorldPos = floor(worldPos + cameraPosition) - cameraPosition + 0.5;
            worldPosM = mix(centerWorldPos, worldPosM + vec3(0.0, 0.02, 0.0), lightmapS);
        #else
            //Shadow bias without peter-panning
            vec3 bias = worldNormal * 0.1 * (2.0 - 0.95 * max(NoL, 0.0));

            if (subsurface <= 0.0) {
                vec3 shadowClip = projMAD(shadowProjection, mat3(shadowModelView) * worldPos + shadowModelView[3].xyz);
                float shadowClipDistance = length(shadowClip.xy);
                float distortFactor = shadowClipDistance * shadowMapBias + (1.0 - shadowMapBias);
                vec3 geometryNormal = normalize(mat3(gbufferModelViewInverse) * normal);
                vec3 shadowNormal = mat3(shadowModelView) * geometryNormal;
                float shadowNormalZ = shadowNormal.z < 0.0 ? min(shadowNormal.z, -0.1) : max(shadowNormal.z, 0.1);
                vec2 depthSlope = -diagonal3(shadowProjection).z * shadowNormal.xy / (diagonal3(shadowProjection).xy * shadowNormalZ);
                vec2 clipDirection = shadowClip.xy / max(shadowClipDistance, 0.000001);
                shadowDepthGradient = 0.2 * distortFactor * (depthSlope + shadowMapBias * shadowClipDistance / (1.0 - shadowMapBias) * dot(depthSlope, clipDirection) * clipDirection);
                shadowDepthBias = (0.0512 + length(shadowDepthGradient) * 1.5) / float(shadowMapResolution) + 2.0 / 65536.0;
                bias = geometryNormal * 2.0 * shadowDistance / float(shadowMapResolution) * distortFactor;
            }

            //Fix light leaking in caves
            if (lightmapS < 0.999) {
                #ifdef GBUFFERS_HAND
                    worldPosM = mix(vec3(0.0), worldPosM, 0.2 + 0.8 * lightmapS);
                #else
                    vec3 edgeFactor = 0.2 * (0.5 - fract(worldPosM + cameraPosition + worldNormal * 0.01));

                    #ifdef GBUFFERS_WATER
                        bias *= 0.7;
                        worldPosM += (1.0 - lightmapS) * edgeFactor;
                    #endif

                    worldPosM += (1.0 - pow2(pow2(max(color.a, lightmapS)))) * edgeFactor;
                #endif
            }

            worldPosM += bias;
        #endif

        vec3 shadowPos = ToShadow(worldPosM);
             shadowPos.z -= shadowDepthBias;
        float fade = clamp(length(viewPos.xz) * 0.01, 0.0, 1.0);
        float offset = 0.00075 - shadowMapResolution * 0.0000001; 
              offset *= 1.0 + subsurface * (3.0 - 3.5 * fade);

        shadow = computeShadow(shadowPos, offset, subsurface, lightmap.y, 1.0 - fade, shadowDepthGradient);
    }
    vec3 realShadow = shadow;

    shadow = min(mix(fakeShadow, shadow, vec3(shadowVisibility)), mix(fakeShadow, shadow, vec3(shadowRange))) * clamp(NoL * 1.01 - 0.01, 0.0, 1.0);

    #ifdef VC_SHADOWS
    #if defined OVERWORLD && defined VOLUMETRIC_CLOUDS && (defined GBUFFERS_TERRAIN || defined GBUFFERS_BLOCK || defined GBUFFERS_ENTITIES || defined GBUFFERS_TEXTURED || defined GBUFFERS_WATER)
    if (NoL > 0.0) {
        vec3 lightDirection = normalize(mat3(gbufferModelViewInverse) * lightVec);
        shadow *= getCloudShadow(worldPos + cameraPosition, lightDirection);
    }
    #endif
    #endif
    #endif

    #ifdef OVERWORLD
    float rainFactor = 1.0 - wetness * 0.5;
    float skyLight = lightmap.y;


    vec3 ambientLighting = ambientCol * skyLight * (1.0 - VoL * 0.5);
    vec3 sceneLighting = mix(ambientLighting, lightCol * (0.15 + lightmap.y * 0.85), shadow * rainFactor * shadowFade);
         sceneLighting *= 1.0 + sss * shadow;
    vec3 directSceneLighting = sceneLighting - ambientLighting;

    #elif defined END
    vec3 sceneLighting = mix(endAmbientCol, endLightCol, shadow) * 0.25;
    vec3 directSceneLighting = sceneLighting - endAmbientCol * 0.25;
    #elif defined NETHER
    vec3 sceneLighting = pow(netherColSqrt, vec3(0.75)) * 0.035;
    vec3 directSceneLighting = vec3(0.0);
    #endif

    //Lightning Flash
    vec3 lightningFlash = vec3(0.0);
    if (lightningBoltPosition.w != 0.0) {
        float lightning = min(lightningFlashEffect(worldPos, lightningBoltPosition.xyz, 256.0) * lightningBoltPosition.w * 4.0, 1.0);
        lightningFlash = vec3(lightning) * (clamp(dot(lightningBoltPosition.xyz, worldNormal), 0.0, 1.0) * 0.9 + 0.1) * lightmap.y;
    }

    //Specular Highlight
    vec3 specularHighlight = vec3(0.0);

    #if (defined GBUFFERS_TERRAIN || defined GBUFFERS_ENTITIES || defined GBUFFERS_BLOCK || defined VOXY_OPAQUE) && !defined NETHER && defined SPECULAR_HIGHLIGHTS
    if (emission < 0.01) {
        float smoothnessF = 0.15 + lAlbedo * 0.25;
        #ifdef END
              smoothness -= 0.10;
        #endif
              smoothnessF = fmix(smoothnessF, 1.0, smoothness);

        float effectiveF0 = (f0 > 0.0) ? f0 : (metalness > 0.5 ? 1.0 : 0.5);

        #ifdef OVERWORLD
        specularHighlight = getSpecularHighlight(
            newNormal, viewPos, smoothnessF, metalness, albedo.rgb,
            effectiveF0, lightColSqrt, shadow / max(NoL + 0.001, 0.001), color.a
        );
        #else
        specularHighlight = getSpecularHighlight(
            newNormal, viewPos, smoothnessF, metalness, albedo.rgb,
            effectiveF0, endLightColSqrt * 0.125, shadow / max(NoL + 0.001, 0.001), color.a
        );
        #endif

        // Metalness hotfix
        if (metalness > 0.5) {
            specularHighlight = max(specularHighlight * 0.5, vec3(0.0));
        } else {
            specularHighlight = max(specularHighlight * 1.1, vec3(0.0));
            specularHighlight *= albedo.rgb;
        }
    }
    #endif

    //Minimal Lighting
    #if defined OVERWORLD || defined END
    sceneLighting += minLightCol * (1.0 - lightmap.y);
    #endif

    //Night vision
    // sceneLighting += nightVision * vec3(0.2, 0.3, 0.2);

    // Traced visibility is already geometric; do not darken direct light a second time.
    vec3 tracedDiffuse = pow(albedo.rgb, vec3(2.2)) * (1.0 - metalness) * tracedBlockLighting * vanillaDiffuse;

    //Vanilla AO
    #if AO_TYPE == 0
    float aoMixer = (1.0 - vanillaAo) * (1.0 - blockLightMap) * (1.0 - emissionMask) * (1.0 - subsurface);
    #if defined OVERWORLD || defined END
          aoMixer *= 1.0 - clamp(maxOf(shadow), 0.0, 1.0) * 0.5;
    #endif

    albedo.rgb = fmix(albedo.rgb, albedo.rgb * pow(vanillaAo, 1.0 + lightmap.y), aoMixer);
    #endif

    albedo.rgb = pow(albedo.rgb, vec3(2.2));


    vec3 diffuseAlbedo = albedo.rgb * (1.0 - metalness);
         diffuseAlbedo *= sceneLighting + blockLighting + emission * EMISSION_STRENGTH + lightningFlash;
         diffuseAlbedo *= vanillaDiffuse;

    vec3 finalColor = diffuseAlbedo + tracedDiffuse + specularHighlight * SPECULAR_HIGHLIGHT_BRIGHTNESS * vanillaDiffuse;
    directLighting = tracedDiffuse + albedo.rgb * (1.0 - metalness) * directSceneLighting * vanillaDiffuse + specularHighlight * SPECULAR_HIGHLIGHT_BRIGHTNESS * vanillaDiffuse;
    occludableLighting = albedo.rgb * (1.0 - metalness) * (sceneLighting - directSceneLighting + blockLighting
    ) * vanillaDiffuse;

    albedo.rgb = pow(max(finalColor, vec3(0.0)), vec3(1.0 / 2.2));
}