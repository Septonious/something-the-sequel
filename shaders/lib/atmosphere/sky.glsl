vec3 getAtmosphere(vec3 viewPos, vec3 worldPos, out float atmosphereHardMixFactor) {
    float spaceFactor = clamp(cameraPosition.y / KARMAN_LINE, 0.0, 1.0);
    float spaceFactorSqrt = sqrt(spaceFactor);
    float horizonSharpness = 1.0 + spaceFactor * 100.0;
    float altitudeFactor = 1.0 - spaceFactor;
    float transitionSmoothness = 0.5 + spaceFactorSqrt;

    vec3 nWorldPos = normalize(worldPos);
    vec3 nViewPos = normalize(viewPos);
    float VoS = dot(nViewPos, sunVec);
    float VoSPositive = max(VoS, 0.0);

    float nWorldPosYMax0 = max(nWorldPos.y, 0.0);
    float atmosphericDensity = pow(clamp(altitudeFactor - nWorldPos.y * transitionSmoothness, 0.0, 1.0), horizonSharpness);

    const vec3 downScatteringColor = vec3(3.15, 0.15, 0.05);
    const vec3 upScatteringColor = vec3(1.0, 1.35, 0.15);

    vec3 skyTint = (0.5 + sunVisibility * 0.20 + timeBrightness * 0.175) * vec3(1.6 - sunVisibility * 0.3 - timeBrightness * 0.3, 1.0 + sunVisibility * 0.15 - timeBrightness * 0.15, 1.15 + timeBrightness * 0.10);
    vec3 daySky = skyTint * normalize(fmix(skyColor.rgb, biomeColor.rgb, isSpecificBiome * 0.35) + 0.00001);
         daySky *= atmosphericDensity;

    //Fake Light Scattering
    float horizonOffset = (-0.05 + VoSPositive * 0.05 + VoSPositive * VoSPositive * 0.05) * (1.0 - sunVisibility) + spaceFactor;
    float VoU = max(nWorldPos.y + horizonOffset, 0.0);
    float mie = pow(VoSPositive, 1.5 + VoSPositive) * 0.5;
    float skyGround = pow(1.0 - nWorldPosYMax0, 2.0 - mie * 2.0);
    float groundScattering = skyGround * (sunVisibility * (0.5 + mie * 0.2 - timeBrightnessSqrt * 0.15));

    float horizonScattering = (10.0 + mie * 10.0) * (1.0 - spaceFactorSqrt) * (1.0 - sunVisibility * 0.825 - timeBrightness * 0.175) * pow(VoU, 1.75 - VoS * 0.25) * sunVisibility;

    daySky.r *= 1.0 + (groundScattering + mie * 0.1) * (1.0 - timeBrightnessSqrt * 0.5);
    daySky.b *= 1.0 - groundScattering - mie * 0.1;
    daySky.g *= 1.0 - skyGround * 0.125 * (1.0 - moonVisibility) * (1.0 - timeBrightnessSqrt);
    daySky *= 1.0 + groundScattering * (0.25 + timeBrightnessSqrt * 0.75);
    daySky = fmix(daySky, upScatteringColor, pow7(1.0 - VoU) * (1.0 - sunVisibility * 0.5) * horizonScattering);
    daySky = fmix(daySky, downScatteringColor, pow12(1.0 - VoU) * (1.0 + moonVisibility - timeBrightness * 0.25) * horizonScattering);
    daySky.rg *= mix(vec2(1.0), vec2(1.5, 0.75), skyGround * mie * sunVisibility * (1.0 - timeBrightnessSqrt) * 0.5);
    daySky *= 1.0 + mie * (0.5 + timeBrightnessSqrt * 0.5);

    vec3 nightSky = lightNight * 0.1 * atmosphericDensity;
    atmosphereHardMixFactor = float(atmosphericDensity > 0.2);

    return fmix(daySky, nightSky, moonVisibility);
}