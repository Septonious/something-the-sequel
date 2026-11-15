uniform sampler2D shadowtex0;

#if defined SHADOW_COLOR || defined VPS
uniform sampler2D shadowtex1;
#endif
#ifdef SHADOW_COLOR
uniform sampler2D shadowcolor0;
#endif

const vec2 shadowOffsets4[4] = vec2[4](
   vec2(0.21848650099008202, -0.09211370200809937),
   vec2(-0.5866112654782878, 0.32153793477769893),
   vec2(-0.06595078555407359, -0.879656059066481),
   vec2(0.43407555004227927, 0.6502318262968816)
);

const vec2 shadowOffsets6[6] = vec2[6](
   vec2(0.2921473492144121, 0.03798942536906266),
   vec2(-0.27714274097351554, 0.3304853027892154),
   vec2(0.09101981507673855, -0.5188871157785563),
   vec2(0.44459182774878003, 0.5629069824170247),
   vec2(-0.6963877647721594, -0.09264703741542105),
   vec2(-0.40412395850181015, -0.8212788214021378)
);

const vec2 shadowOffsets8[8] = vec2[8](
   vec2(0.2921473492144121, 0.03798942536906266),
   vec2(-0.27714274097351554, 0.3304853027892154),
   vec2(0.09101981507673855, -0.5188871157785563),
   vec2(0.44459182774878003, 0.5629069824170247),
   vec2(-0.6963877647721594, -0.09264703741542105),
   vec2(0.7417522811565185, -0.4070419658858473),
   vec2(-0.191856808948964, 0.9084732299066597),
   vec2(-0.40412395850181015, -0.8212788214021378)
);

float texture2DShadow(sampler2D shadowtex, vec3 shadowPos) {
    float shadow = texture2D(shadowtex, shadowPos.xy).r;

    return clamp((shadow - shadowPos.z) * 65536.0, 0.0, 1.0);
}

#ifdef VPS
//Variable Penumbra Shadows based on Tech's Lux Shader (https://github.com/TechDevOnGitHub)
void findBlockerDistance(vec3 shadowPos, mat2 ditherMatrix, inout float offset, float skyLightMap, float vpsFade) {
    float blockerDistance = 0.0;
        
    for (int i = 0; i < 4; i++){
        vec2 pixelOffset = ditherMatrix * 0.015 * shadowOffsets4[i];
        blockerDistance += shadowPos.z - texture2D(shadowtex1, shadowPos.xy + pixelOffset).r;
    }
    blockerDistance *= 0.25;
    
    offset = mix(offset, clamp(blockerDistance * VPS_BLUR_STRENGTH, offset, offset * 6.0), skyLightMap * vpsFade);
}
#endif

vec3 computeShadow(vec3 shadowPos, float offset, float subsurface, float skyLightMap, float vpsFade, vec2 depthGradient) {
    float shadow0 = 0.0;
    vec3 shadowCol = vec3(0.0);    

    float dither = texture2D(noisetex, gl_FragCoord.xy / 512.0).b;
    #ifdef TAA
         dither = fract(dither + 1.61803398875 * mod(float(frameCounter), 3600.0));
    #endif
    dither *= TAU;

	float cosTheta = cos(dither);
	float sinTheta = sin(dither);
	mat2 ditherMatrix = mat2(cosTheta, -sinTheta, sinTheta, cosTheta);

    #ifdef VPS
    if (subsurface < 0.1 && vpsFade > 0.0 && skyLightMap > 0.05) findBlockerDistance(shadowPos, ditherMatrix, offset, skyLightMap, vpsFade);
    #endif

    for (int i = 0; i < SHADOW_FILTER_SAMPLES; i++) {
        #if SHADOW_FILTER_SAMPLES == 6
        vec2 shadowOffset = ditherMatrix * offset * shadowOffsets6[i];
        #else
        vec2 shadowOffset = ditherMatrix * offset * shadowOffsets8[i];
        #endif
        shadow0 += texture2DShadow(shadowtex0, vec3(shadowPos.st + shadowOffset, shadowPos.z + dot(depthGradient, shadowOffset)));
    }
    shadow0 *= 1.0 / float(SHADOW_FILTER_SAMPLES);

    #ifdef SHADOW_COLOR
    if (wetness < 0.5 && shadow0 < 1.0) {
        for (int i = 0; i < 4; i++) {
            vec2 shadowOffset = ditherMatrix * offset * 2.0 * shadowOffsets4[i];

            float translucentVisibility = texture2DShadow(shadowtex1, vec3(shadowPos.st + shadowOffset, shadowPos.z + dot(depthGradient, shadowOffset)));
            if (translucentVisibility > 0.0) shadowCol += texture2DLod(shadowcolor0, shadowPos.st + shadowOffset, 0.0).rgb * translucentVisibility;
        }
    }
    shadowCol *= 0.25 - wetness * 0.25;
    #endif
   
    shadow0 *= mix(shadow0, 1.0, subsurface);
    shadowCol *= shadowCol;

    return clamp(shadowCol * (1.0 - shadow0) + shadow0, vec3(0.0), vec3(16.0));
}

vec3 getFakeShadow(float skyLight) {
    #ifdef END
    return vec3(1.0);
    #elif defined OVERWORLD
    float fakeShadow = pow32(skyLight * skyLight) * float(isEyeInWater == 0);
    return vec3(fakeShadow);
    #else
    return vec3(1.0);
    #endif
}
