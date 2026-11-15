float getCirrusDensity(vec2 coord, vec2 detail) {
    vec2 coverage = texture2D(colortex8, coord * vec2(0.44, 0.20)).rg;
    float amount = 1.0 - CIRRUS_AMOUNT + moonVisibility * 0.05;
    float sheet = smoothstep(amount, amount + 0.45, coverage.g);
    if (sheet <= 0.0) return 0.0;

    vec2 fibreCoord = vec2(coord.x * 0.966 - coord.y * 0.259, coord.x * 0.259 + coord.y * 0.966 + coverage.r * 0.15);
    float drift = frameTimeCounter * 0.01;
    float fibre = mix(0.5, CloudValue3D(vec3(fibreCoord * vec2(6.0, 10.0), drift)), detail.x) * 0.6;
          fibre += mix(0.5, CloudValue3D(vec3(fibreCoord * vec2(12.0, 28.0) + vec2(31.0, 17.0), drift + 7.5)), detail.y) * 0.4;

    return pow(sheet * smoothstep(0.15, 0.85, fibre), 1.3);
}

void drawCirrusClouds(inout vec4 cirrus, in vec3 atmosphereColor, in vec3 worldPos, in vec3 nViewPos, in float caveFactor, inout float occlusion) {
    float spaceFactor = min(max(cameraPosition.y, 0.0) / KARMAN_LINE, 1.0);
    float spaceFactor10k = min(max(cameraPosition.y, 0.0) * 0.0001, 1.0);
    float cloudHeightFactor = 0.125 + pow2(clamp(1.0 - 0.001 * cameraPosition.y * (0.5 - spaceFactor), 0.0, 3.5));

    vec3 planeCoord = worldPos * (cloudHeightFactor / worldPos.y) * CIRRUS_HEIGHT * 0.001;
    float coordLength = length(planeCoord.xz);
    float distanceFactor = clamp(1.0 - coordLength * max(0.15 - spaceFactor * 0.085 - spaceFactor10k * (1.0 - spaceFactor) * 0.25, 0.005), 0.0, 1.0);
    planeCoord *= 2.0 - distanceFactor;

    vec2 warp = vec2(sin(planeCoord.z * 0.5 - frameTimeCounter * 0.001), cos(planeCoord.x * 0.3 - frameTimeCounter * 0.002));
    planeCoord.xz += warp * 0.5;

    vec2 windDirection = vec2(cos(radians(VC_WIND_ANGLE)), sin(radians(VC_WIND_ANGLE)));
    vec2 coord = cameraPosition.xz * 0.00025 * (0.5 - spaceFactor10k) + planeCoord.xz * 1.25 + windDirection * frameTimeCounter * VC_CLOUD_SPEED * 0.007;
         coord = vec2(coord.x * 1.25 + coord.y * 0.5, coord.y * 0.65);
    vec2 footprint = fwidth(vec2(coord.x * 0.966 - coord.y * 0.259, coord.x * 0.259 + coord.y * 0.966));
    vec2 detail = clamp(2.0 - 2.0 * max(footprint.x * vec2(6.0, 12.0), footprint.y * vec2(10.0, 28.0)), 0.0, 1.0);

    vec3 nWorldPos = normalize(worldPos);
    float fade = pow(max(nWorldPos.y, 0.0), 0.025);
          fade = mix(fade, (1.0 - fade) * float(nWorldPos.y < 0.0), spaceFactor10k);
          fade *= pow3(fade);
          fade *= distanceFactor * caveFactor;
    if (!(fade > 0.001)) return;

    float density = getCirrusDensity(coord, detail);
    if (density <= 0.0) return;

    vec3 lightDirection = normalize(mat3(gbufferModelViewInverse) * lightVec);
    vec2 lightStep = vec2(lightDirection.x * 1.25 + lightDirection.z * 0.5, lightDirection.z * 0.65) * 0.025;
    float lightDensity = getCirrusDensity(coord + lightStep, detail);

    vec3 skyLight = pow(atmosphereColor, vec3(2.2)) * 2.2;
    float forwardPhase = pow12(clamp(dot(nViewPos, lightVec) * 0.5 + 0.5, 0.0, 1.0)) * shadowFade;
    vec3 lightColor = fmix(lightCol, skyLight, sunVisibility * 0.5) * (3.0 + forwardPhase * 5.0);
    vec3 ambientColor = fmix(ambientCol, skyLight * 0.25, sunVisibility * 0.5);

    float powder = 1.0 - exp(-density * 4.0);
    float transmission = exp(-lightDensity * 1.2);
    vec3 color = fmix(ambientColor * (0.6 + 0.4 * powder), lightColor * (0.1 + 0.9 * powder) * shadowFade, 0.01 + 0.99 * transmission * (0.25 + clamp(lightDirection.y, 0.0, 1.0) * 0.75));

    cirrus = vec4(pow(color * CIRRUS_BRIGHTNESS, vec3(1.0 / 2.2)), density * fade * fade);
    occlusion += sqrt(density) * fade;
}
