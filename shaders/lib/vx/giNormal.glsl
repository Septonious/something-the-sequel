vec3 giViewNormal(vec2 coord, vec3 viewPos) {
    vec2 pixelSize = 1.0 / vec2(textureSize(depthtex0, 0));
    vec2 rightCoord = coord + vec2(pixelSize.x, 0.0);
    vec2 leftCoord = coord - vec2(pixelSize.x, 0.0);
    vec2 upCoord = coord + vec2(0.0, pixelSize.y);
    vec2 downCoord = coord - vec2(0.0, pixelSize.y);
    vec3 rightOffset = ToView(vec3(rightCoord, texture2D(depthtex0, rightCoord).r)) - viewPos;
    vec3 leftOffset = viewPos - ToView(vec3(leftCoord, texture2D(depthtex0, leftCoord).r));
    vec3 upOffset = ToView(vec3(upCoord, texture2D(depthtex0, upCoord).r)) - viewPos;
    vec3 downOffset = viewPos - ToView(vec3(downCoord, texture2D(depthtex0, downCoord).r));
    vec3 normal = normalize(cross(abs(rightOffset.z) < abs(leftOffset.z) ? rightOffset : leftOffset, abs(upOffset.z) < abs(downOffset.z) ? upOffset : downOffset));

    return faceforward(normal, viewPos, normal);
}
