#ifndef VOLUMETRIC_CLOUDS_GLSL
#define VOLUMETRIC_CLOUDS_GLSL

const float cloudSourceBottom = 1000.0;
const float cloudSourceDepth = VC_SOURCE_DEPTH;
const float cloudSourceTop = cloudSourceBottom + cloudSourceDepth;
const float cloudSourceScale = VC_SOURCE_SCALE;

struct CloudWeather {
    float height;
    float thickness;
    float size;
    float coverageOffset;
    float densityScale;
    float windScale;
    float broadStrength;
    float detailStrength;
    float cellularStrength;
};

float CloudSaturate(float x) {
    return clamp(x, 0.0, 1.0);
}

float CloudStep(float x, float low, float high) {
    return smoothstep(low, high, x);
}

float CloudCubeSmooth(float x) {
    return x * x * (3.0 - 2.0 * x);
}

float CloudHash11(float x) {
    x = fract(x * 0.1031);
    x *= x + 33.33;
    x *= x + x;
    return fract(x);
}

vec4 CloudHash41(float x) {
    return vec4(
        CloudHash11(x + 0.0),
        CloudHash11(x + 19.19),
        CloudHash11(x + 47.47),
        CloudHash11(x + 83.83)
    );
}

CloudWeather CloudWeatherState(float index) {
    vec4 a = CloudHash41(index + float(VC_WEATHER_SEED) * 13.17);
    vec4 b = CloudHash41(index + float(VC_WEATHER_SEED) * 29.31 + 101.7);

    float variation = VC_WEATHER_VARIATION;
    float humidity = a.x;
    float convection = a.y;
    float sizeRandom = a.z;
    float heightRandom = a.w;
    float windRandom = b.x;
    float thicknessRandom = b.y;
    float shapeRandom = b.z;

    CloudWeather weather;
    weather.height = VC_CLOUD_HEIGHT
        + (heightRandom * 2.0 - 1.0) * VC_WEATHER_HEIGHT_VARIATION * variation;
    weather.thickness = VC_CLOUD_THICKNESS * max(
        0.55,
        1.0 + (thicknessRandom * 2.0 - 1.0)
            * VC_WEATHER_THICKNESS_VARIATION * variation
    );
    weather.size = VC_CLOUD_SIZE * max(
        0.45,
        1.0 + (sizeRandom * 2.0 - 1.0)
            * VC_WEATHER_SIZE_VARIATION * variation
    );
    weather.coverageOffset = (humidity * 2.0 - 1.0)
        * VC_WEATHER_COVERAGE_VARIATION * variation;
    weather.densityScale = max(
        0.70,
        1.0 + (humidity * 2.0 - 1.0) * 0.16 * variation
    );
    weather.windScale = max(
        0.20,
        1.0 + (windRandom * 2.0 - 1.0)
            * VC_WEATHER_WIND_VARIATION * variation
    );
    weather.broadStrength = max(
        0.55,
        1.0 + (shapeRandom * 2.0 - 1.0)
            * VC_WEATHER_SHAPE_VARIATION * variation
    );
    weather.detailStrength = max(
        0.50,
        1.0 + (convection * 2.0 - 1.0)
            * VC_WEATHER_SHAPE_VARIATION * variation
    );
    weather.cellularStrength = max(
        0.50,
        1.0 + ((shapeRandom + convection) - 1.0)
            * VC_WEATHER_SHAPE_VARIATION * variation
    );

    return weather;
}

CloudWeather CloudMixWeather(CloudWeather a, CloudWeather b, float t) {
    CloudWeather weather;
    weather.height = mix(a.height, b.height, t);
    weather.thickness = mix(a.thickness, b.thickness, t);
    weather.size = mix(a.size, b.size, t);
    weather.coverageOffset = mix(a.coverageOffset, b.coverageOffset, t);
    weather.densityScale = mix(a.densityScale, b.densityScale, t);
    weather.windScale = mix(a.windScale, b.windScale, t);
    weather.broadStrength = mix(a.broadStrength, b.broadStrength, t);
    weather.detailStrength = mix(a.detailStrength, b.detailStrength, t);
    weather.cellularStrength = mix(a.cellularStrength, b.cellularStrength, t);
    return weather;
}

CloudWeather CloudGetWeather() {
    CloudWeather weather;
    weather.height = VC_CLOUD_HEIGHT;
    weather.thickness = VC_CLOUD_THICKNESS;
    weather.size = VC_CLOUD_SIZE;
    weather.coverageOffset = 0.0;
    weather.densityScale = 1.0;
    weather.windScale = 1.0;
    weather.broadStrength = 1.0;
    weather.detailStrength = 1.0;
    weather.cellularStrength = 1.0;
    return weather;
}

float CloudHorizontalScale(CloudWeather weather) {
    //Decoupled from cloud thickness. This is the important change that lets
    //clouds become taller/shorter without also becoming huge in XZ.
    return cloudSourceDepth / VC_CLOUD_THICKNESS / max(weather.size, 0.1);
}

float CloudBodyThickness(CloudWeather weather) {
    return max(weather.thickness * VC_CLOUD_BODY_SCALE, 1.0);
}

float CloudVerticalScale(CloudWeather weather) {
    return cloudSourceDepth / CloudBodyThickness(weather);
}

vec3 CloudToSourceSpace(vec3 worldPos, CloudWeather weather) {
    float horizontalScale = CloudHorizontalScale(weather);
    float verticalScale = CloudVerticalScale(weather);

    return vec3(
        worldPos.x * horizontalScale,
        cloudSourceBottom + (worldPos.y - weather.height) * verticalScale,
        worldPos.z * horizontalScale
    );
}

float CloudValue3D(vec3 pos) {
    float zCell = floor(pos.z);
    float zFraction = fract(pos.z);
    vec2 uv = pos.xy - vec2(97.0 * zCell);
    vec2 rg = texture2D(colortex8, uv / 512.0).ba;
    return CloudCubeSmooth(mix(rg.x, rg.y, zFraction));
}

vec2 CloudWindOffset(CloudWeather weather) {
    float angle = radians(VC_WIND_ANGLE);
    vec2 direction = vec2(cos(angle), sin(angle));
    float speed = VC_CLOUD_SPEED * weather.windScale;
    return direction * frameTimeCounter * speed * 0.02;
}

float CloudShapeBase(
    vec3 sourcePos,
    CloudWeather weather,
    vec2 windOffset,
    out vec3 noisePos,
    out float slope,
    out float densityFade
) {
    float altitude = sourcePos.y;
    if (altitude < cloudSourceBottom || altitude > cloudSourceTop) return 0.0;

    float attenuation = CloudStep(
        altitude,
        cloudSourceBottom + cloudSourceDepth * 0.025,
        cloudSourceTop
    );

    noisePos = sourcePos * cloudSourceScale;
    noisePos.xz += windOffset;

    //One packed RGBA lookup provides the coverage and its low-pass shadow field.
    vec2 coverageUv = noisePos.xz * VC_COVERAGE_SCALE;
    vec2 coverageData = texture2D(colortex8, coverageUv).rg;

    float coverageNoise = coverageData.r + (coverageData.r - coverageData.g) * VC_CELLULAR_SHAPING * weather.cellularStrength;
          coverageNoise = CloudSaturate(coverageNoise);

    float coverageBias = 0.50 - cloudRain * 0.45 - VC_CLOUD_COVERAGE * 0.75 - weather.coverageOffset;
    float coverage = ((coverageNoise - coverageBias) / max(1.0 - CloudSaturate(coverageBias), 1e-4)) - attenuation;

    if (coverage <= 0.0) return 0.0;

    float wFade = CloudStep(
        altitude,
        cloudSourceBottom,
        cloudSourceBottom + cloudSourceDepth * 0.33
    ) * 0.5 + 0.5;

    float h = CloudSaturate((altitude - cloudSourceBottom) / cloudSourceDepth);
    float baseGrowth = CloudStep(h, 0.00, 0.16);
    float liquidWater = fmix(0.14, 1.0, CloudStep(h, 0.12, 0.72));
    float topEntrainment = 1.0 - 0.38 * CloudStep(h, 0.74, 1.00);

    densityFade = 4.0 * VC_CLOUD_DENSITY * baseGrowth * liquidWater * topEntrainment * (1.0 + cloudRain);

    float shape = coverage;
    slope = sqrt(1.0 - CloudSaturate(shape));

    noisePos.xy += shape * 0.5;
    float broadNoise = CloudValue3D(noisePos * VC_BROAD_NOISE_SCALE) * VC_BROAD_NOISE_STRENGTH * weather.broadStrength * wFade;

    shape -= broadNoise * slope;
    noisePos -= broadNoise * 0.5;

    if (shape <= 0.0) return 0.0;

    slope = sqrt(1.0 - CloudSaturate(shape));
    return shape;
}

float getCloudShape(vec3 sourcePos, CloudWeather weather, vec2 windOffset, bool isDetailed) {
    vec3 noisePos;
    float slope;
    float densityFade;
    float shape = CloudShapeBase(
        sourcePos,
        weather,
        windOffset,
        noisePos,
        slope,
        densityFade
    );

    if (shape <= 0.0) return 0.0;

    if (isDetailed) {
        shape -= CloudValue3D(noisePos * VC_DETAIL_NOISE_SCALE)
            * VC_DETAIL_NOISE_STRENGTH
            * weather.detailStrength
            * slope;
    }

    return shape * densityFade * weather.densityScale;
}

// Expensive lighting inputs are invariant over an entire camera ray.
// Compute them once, then reuse them for every occupied cloud sample.
struct CloudLightingData {
    vec3 lightStepSource;
    vec3 lightColor;
    vec3 ambientColor;
    float lightStepLength;
    float lightHeight;
    float phase;
    float extinction;
};

CloudLightingData CloudPrepareLighting(vec3 rayDir, vec3 atmosphereColor, CloudWeather weather, float horizontalScale, float verticalScale) {
    CloudLightingData lighting;
    atmosphereColor = pow(atmosphereColor, vec3(2.2)) * 2.2;
    vec3 sunDirection = normalize(mat3(gbufferModelViewInverse) * lightVec);
    lighting.lightHeight = clamp(sunDirection.y, 0.0, 1.0);
    float sunAngle = clamp(dot(rayDir, sunDirection), -1.0, 1.0);
    float forwardPhase = pow12(clamp(sunAngle * 0.5 + 0.5, 0.0, 1.0)) * shadowFade;
    lighting.phase = 1.5 + forwardPhase * 2.5;
    lighting.extinction = 0.5 - forwardPhase * 0.25;
    lighting.lightColor = fmix(lightCol, atmosphereColor, sunVisibility * 0.5) * max(1.0 / VC_CLOUD_DENSITY, 2.0);
    lighting.ambientColor = fmix(ambientCol, atmosphereColor * 0.25, sunVisibility * 0.5);
    lighting.lightStepLength = max(weather.thickness * VC_CLOUD_BODY_SCALE, 1.0) / float(VC_LIGHT_STEPS);
    lighting.lightStepLength *= 0.25 + sunDirection.y * 0.25 * sunVisibility;
    lighting.lightStepSource = vec3(sunDirection.x * horizontalScale, sunDirection.y * verticalScale, sunDirection.z * horizontalScale) * lighting.lightStepLength;
    return lighting;
}

float calculateCloudTransmission(vec3 sourcePos, CloudWeather weather, vec2 windOffset, CloudLightingData lighting) {
    float depth = 0.0;
    for (int i = 0; i < VC_LIGHT_STEPS; i++) {
        sourcePos += lighting.lightStepSource;
        depth += getCloudShape(sourcePos, weather, windOffset, false) * lighting.lightStepLength;
    }
    return exp(-depth * lighting.extinction);
}

vec3 CloudLighting(vec3 sourcePos, float density, CloudWeather weather, vec2 windOffset, CloudLightingData lighting) {
    float powder = 1.0 - exp(-density * 4.0);
    float transmission = calculateCloudTransmission(sourcePos, weather, windOffset, lighting);
    return fmix(lighting.ambientColor * (0.6 + 0.4 * powder), lighting.lightColor * lighting.phase * (0.1 + 0.9 * powder) * shadowFade, 0.01 + 0.99 * transmission * (0.25 + lighting.lightHeight * 0.75));
}

// Source-model raymarch, weather, optical transmittance, distance fading and geometry clipping.
// The incompatible PhysicalSL lighting/exposure are deliberately not used.
void computeVolumetricClouds(inout vec4 vc, in vec3 atmosphereColor, float z0, float dither, inout vec2 cloudRange) {
    float visibility = caveFactor * (1.0 - blindFactor);
    #if MC_VERSION >= 11900
          visibility *= 1.0 - darknessFactor;
    #endif

    if (visibility <= 0.0) return;

    vec3 viewRay = normalize(ToView(vec3(texCoord, 1.0)));
    vec3 rayDir = normalize(mat3(gbufferModelViewInverse) * viewRay);
    CloudWeather weather = CloudGetWeather();
    float bottom = weather.height;
    float top = weather.height + weather.thickness;
    float cameraBodyHeight = (cameraPosition.y - bottom) / CloudBodyThickness(weather);
    float insideCloudLayer = smoothstep(0.0, 0.1, cameraBodyHeight) * (1.0 - smoothstep(0.9, 1.0, cameraBodyHeight));
    float sceneDistance = VC_CLOUD_MAX_DISTANCE;
    if (z0 < 0.999999) sceneDistance = min(sceneDistance, length(ToView(vec3(texCoord, z0))));

    float rayStart;
    float rayEnd;
    if (abs(rayDir.y) < 0.00001) {
        if (cameraPosition.y < bottom || cameraPosition.y > top) return;
        rayStart = 0.0;
        rayEnd = sceneDistance;
    } else {
        float tBottom = (bottom - cameraPosition.y) / rayDir.y;
        float tTop = (top - cameraPosition.y) / rayDir.y;
        rayStart = max(min(tBottom, tTop), 0.0);
        rayEnd = min(max(tBottom, tTop), sceneDistance);
    }
    if (rayEnd <= rayStart) return;

    float rayLength = rayEnd - rayStart;
    float verticalScale = CloudVerticalScale(weather);
    float baseSourceStep = cloudSourceDepth / float(VC_CLOUD_STEPS);
    float sourceStepAtBase = rayLength * verticalScale / float(VC_CLOUD_STEPS);
    float stepCoeff = 0.45 + clamp(sourceStepAtBase / baseSourceStep - 1.1, 0.0, 2.6) * 0.5;
    int steps = clamp(int(float(VC_CLOUD_STEPS) * stepCoeff), 12, VC_CLOUD_MAX_STEPS);
        steps = clamp(int(rayLength * insideCloudLayer / 16.0), steps, 256);
    float stepLength = rayLength / float(steps);
    float horizontalScale = CloudHorizontalScale(weather);
    float sourceVerticalScale = CloudVerticalScale(weather);
    vec3 sourceRay = vec3(rayDir.x * horizontalScale, rayDir.y * sourceVerticalScale, rayDir.z * horizontalScale);
    vec3 sourceCamera = vec3(cameraPosition.x * horizontalScale, cloudSourceBottom + (cameraPosition.y - weather.height) * sourceVerticalScale, cameraPosition.z * horizontalScale);
    float sourceStepLength = stepLength * length(sourceRay);
    float sampleDistance = rayStart + stepLength * clamp(dither, 0.0, 0.999999);
    vec2 windOffset = CloudWindOffset(weather);
    vec3 skyFogColor = pow(atmosphereColor, vec3(2.2));
    CloudLightingData lighting;
    bool lightingReady = false;

    vec3 scattering = vec3(0.0);
    float transmittance = 1.0;
    float firstCloudDistance = VC_CLOUD_MAX_DISTANCE;
    float lastCloudDistance = 0.0;

    for (int i = 0; i < 256; i++) {
        if (i >= steps || sampleDistance > rayEnd || transmittance < VC_MIN_TRANSMITTANCE) break;
        float distanceFade = 1.0 - smoothstep(VC_CLOUD_MAX_DISTANCE * 0.25, VC_CLOUD_MAX_DISTANCE, sampleDistance);
        if (distanceFade == 0.0) break;
        vec3 sourcePos = sourceCamera + sourceRay * sampleDistance;
        float density = getCloudShape(sourcePos, weather, windOffset, true);
        if (density > 0.0) {
            float stepTransmission = exp(-density * VC_SIGMA_T * sourceStepLength);
            float stepOpacity = (1.0 - stepTransmission) * distanceFade;
            if (stepOpacity > 0.0001) {
                if (firstCloudDistance == VC_CLOUD_MAX_DISTANCE) firstCloudDistance = sampleDistance;
                lastCloudDistance = sampleDistance;
                if (!lightingReady) {
                    lighting = CloudPrepareLighting(rayDir, atmosphereColor, weather, horizontalScale, sourceVerticalScale);
                    lightingReady = true;
                }
                vec3 sampleColor = CloudLighting(sourcePos, density, weather, windOffset, lighting);
                     sampleColor = mix(skyFogColor, sampleColor, exp(-pow2(sampleDistance * VC_SKY_FOG / 1800.0)));
                scattering += sampleColor * stepOpacity * transmittance;
            }
            transmittance *= 1.0 - stepOpacity;
        }
        sampleDistance += stepLength;
    }

    float opacity = clamp((1.0 - transmittance) / (1.0 - VC_MIN_TRANSMITTANCE), 0.0, 1.0) * visibility * mix(VC_OPACITY, 1.0, clamp(cameraPosition.y / VC_CLOUD_HEIGHT, 0.0, 1.0));
    vc.a = clamp(opacity, 0.0, 1.0);
    vc.rgb = scattering / max(1.0 - transmittance, 0.0001);
    cloudRange = vec2(firstCloudDistance, lastCloudDistance);
}

#endif
