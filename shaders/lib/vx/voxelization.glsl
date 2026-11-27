// World-aligned 8-block lattice, rebuilt every frame.
uniform vec3 cameraPositionFract;
uniform ivec3 cameraPositionInt;
const vec3 voxelVolumeSize = vec3(VOXEL_VOLUME_SIZE, VOXEL_VOLUME_SIZE * 0.5, VOXEL_VOLUME_SIZE);
vec3 ddaCameraOffset() {
    // Iris integer part is truncated; account for a negative fractional part.
    ivec3 floorCamera = cameraPositionInt + ivec3(floor(cameraPositionFract));
    ivec3 phase = ((floorCamera + ivec3(4)) & 7) - 4;
    return vec3(phase) + fract(cameraPositionFract);
}
vec3 worldToVoxel(vec3 worldPos) { return worldPos + ddaCameraOffset() + voxelVolumeSize * 0.5; }
vec3 voxelToWorld(vec3 voxelPos) { return voxelPos - ddaCameraOffset() - voxelVolumeSize * 0.5; }
bool isInsideVoxelVolume(vec3 voxelPos) {
    return all(greaterThanEqual(voxelPos, vec3(0.0))) && all(lessThan(voxelPos, voxelVolumeSize));
}
#ifndef DDA_DOMAIN_INCLUDED
#define DDA_DOMAIN_INCLUDED
float ddaDomainWeight(vec3 p) {
    vec3 margin = min(p, voxelVolumeSize - p);
    float safe = smoothstep(float(DDA_LIGHT_RANGE), float(DDA_LIGHT_RANGE) + 8.0, min(margin.x, min(margin.y, margin.z)));
    #if defined DDA_TRACE_VOLUME && DDA_TRACE_VOLUME < 100
    vec3 nearHalf = voxelVolumeSize * (0.5 * pow(float(DDA_TRACE_VOLUME)*0.01, 1.0/3.0));
    vec3 nearMargin = nearHalf - abs(voxelToWorld(p));
    return min(safe, smoothstep(0.0, 8.0, min(nearMargin.x,min(nearMargin.y,nearMargin.z))));
    #else
    return safe;
    #endif
}
#endif

#ifdef SHADOW
#if DDA_CAPTURE_INDEX == 1
layout(r32ui) uniform uimage3D ddaCaptureIndex_img;
#endif
#include "/lib/vx/ddaShapeIds.glsl"
// Codes: 0 air (cleared), 1 pass-through, 2..199 emitters/opaque palette,
// 200..215 stained glass, 255 opaque. Preserve high-ID flower emission aliases.
uint ddaMaterialCode(uint id) {
    // Dirt path and farmland have a top at 15/16; remain opaque to other rays.
    uint shape = ddaShapeFromBlock(id);
    if (shape != 0u) return shape;
    if (id == 10310u) return 254u;
    if (id == 305u || id == 306u || id == 311u || id == 312u) return 35u;
    if (id == 307u || id == 308u) return 36u;
    if (id == 309u || id == 310u) return 34u;
    if (id >= 304u && id <= 319u) return 1u;
    if (id >= 2u && id <= 216u) return id - 1u;
    return 255u;
}
void updateVoxelMap(uint id) {
    #if DDA_DEBUG == 7
    return;
    #endif
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
    if (isInsideVoxelVolume(voxelPos)) {
        ivec3 p=ivec3(voxelPos);uint code=ddaMaterialCode(id);
        #if DDA_CAPTURE_INDEX == 1
        uint previous=imageAtomicMax(voxel_img,p,code);
        // Only the first nonzero material write marks this brick. Later
        // conflicts still resolve through atomicMax; the index reads the final code.
        if(previous==0u && code!=0u){ivec3 b=(p>>2)&1;imageAtomicOr(ddaCaptureIndex_img,p>>3,1u<<(b.x+2*b.y+4*b.z));}
        #else
        imageAtomicMax(voxel_img,p,code);
        #endif
    }
}
#endif
