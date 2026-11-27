// Camera-relative LPV lattice. Integer camera motion is compensated in shadowcomp.
const vec3 voxelVolumeSize = vec3(VOXEL_VOLUME_SIZE, VOXEL_VOLUME_SIZE * 0.5, VOXEL_VOLUME_SIZE);
vec3 worldToVoxel(vec3 worldPos) { return worldPos + fract(cameraPosition) + voxelVolumeSize * 0.5; }
vec3 voxelToWorld(vec3 voxelPos) { return voxelPos - fract(cameraPosition) - voxelVolumeSize * 0.5; }
bool isInsideVoxelVolume(vec3 voxelPos) {
    return all(greaterThanEqual(voxelPos, vec3(0.0))) && all(lessThan(voxelPos, voxelVolumeSize));
}
#ifdef SHADOW
// Codes: 0 air (cleared), 1 pass-through, 2..199 emitters/opaque palette,
// 200..215 stained glass, 255 opaque. Preserve high-ID flower emission aliases.
uint lpvMaterialCode(uint id) {
    if (id == 305u || id == 306u || id == 311u || id == 312u) return 35u;
    if (id == 307u || id == 308u) return 36u;
    if (id == 309u || id == 310u) return 34u;
    if (id >= 304u && id <= 319u) return 1u;
    if (id >= 2u && id <= 216u) return id - 1u;
    return 255u;
}
void updateVoxelMap(uint id) {
    #ifndef SHADOW_COLORWHEEL
    bool doVoxelization = id != 1u && any(equal(ivec4(renderStage), ivec4(MC_RENDER_STAGE_TERRAIN_SOLID, MC_RENDER_STAGE_TERRAIN_TRANSLUCENT, MC_RENDER_STAGE_TERRAIN_CUTOUT, MC_RENDER_STAGE_TERRAIN_CUTOUT_MIPPED)));
    #else
    bool doVoxelization = true;
    #endif
    if (!doVoxelization) return;
    vec3 modelPos = gl_Vertex.xyz + at_midBlock / 64.0;
    vec3 viewPos = mat3(gl_ModelViewMatrix) * modelPos + gl_ModelViewMatrix[3].xyz;
    vec3 shadowPos = mat3(shadowModelViewInverse) * viewPos + shadowModelViewInverse[3].xyz;
    vec3 voxelPos = worldToVoxel(shadowPos);
    if (isInsideVoxelVolume(voxelPos)) imageStore(voxel_img, ivec3(voxelPos), uvec4(lpvMaterialCode(id), 0u, 0u, 0u));
}
#endif
