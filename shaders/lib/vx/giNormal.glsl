vec3 giViewNormal(vec2 coord, vec3 viewPos) {
    vec2 pixelSize = 1.0 / vec2(textureSize(depthtex0, 0));
    vec2 stepX = vec2(pixelSize.x, 0.0);
    vec2 stepY = vec2(0.0, pixelSize.y);
    float depth = texture2D(depthtex0, coord).r;
    float depthRight = texture2D(depthtex0, coord + stepX).r;
    float depthLeft = texture2D(depthtex0, coord - stepX).r;
    float depthUp = texture2D(depthtex0, coord + stepY).r;
    float depthDown = texture2D(depthtex0, coord - stepY).r;
    bool useRight = abs(depthRight * 2.0 - texture2D(depthtex0, coord + stepX * 2.0).r - depth) < abs(depthLeft * 2.0 - texture2D(depthtex0, coord - stepX * 2.0).r - depth);
    bool useUp = abs(depthUp * 2.0 - texture2D(depthtex0, coord + stepY * 2.0).r - depth) < abs(depthDown * 2.0 - texture2D(depthtex0, coord - stepY * 2.0).r - depth);
    vec3 horizontal = useRight ? ToView(vec3(coord + stepX, depthRight)) - viewPos : viewPos - ToView(vec3(coord - stepX, depthLeft));
    vec3 vertical = useUp ? ToView(vec3(coord + stepY, depthUp)) - viewPos : viewPos - ToView(vec3(coord - stepY, depthDown));
    vec3 normal = normalize(cross(horizontal, vertical));

    return faceforward(normal, viewPos, normal);
}

int giFace(vec3 normal) {
    vec3 extent = abs(normal);
    int axis = extent.x > extent.y ? (extent.x > extent.z ? 0 : 2) : (extent.y > extent.z ? 1 : 2);

    return axis * 2 + int(normal[axis] < 0.0);
}

int giStoredFace(vec4 surface) {
    return int(surface.r < 0.0) + int(surface.g < 0.0) * 2 + int(surface.a < 0.0) * 4;
}
