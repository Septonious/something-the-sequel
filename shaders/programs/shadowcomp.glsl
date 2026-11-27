#include "/lib/common.glsl"
// Historical seven-point LPV diffusion. Previous-frame read and current-frame
// write use separate images; the camera translation follows integer world cells.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
#if VOXEL_VOLUME_SIZE == 128
const ivec3 workGroups = ivec3(16, 8, 16);
#elif VOXEL_VOLUME_SIZE == 192
const ivec3 workGroups = ivec3(24, 12, 24);
#elif VOXEL_VOLUME_SIZE == 256
const ivec3 workGroups = ivec3(32, 16, 32);
#elif VOXEL_VOLUME_SIZE == 384
const ivec3 workGroups = ivec3(48, 24, 48);
#elif VOXEL_VOLUME_SIZE == 512
const ivec3 workGroups = ivec3(64, 32, 64);
#endif
uniform int frameCounter;
uniform float frameTimeCounter;
#ifdef OVERWORLD
uniform float wetness;
#endif
uniform vec3 cameraPosition, previousCameraPosition;
uniform usampler3D voxelSampler;
layout(rgba16f) writeonly uniform image3D floodfill_img, floodfill_img_copy;
uniform sampler3D floodfillSampler, floodfillSamplerCopy;
#include "/lib/vx/blocklightColor.glsl"
const ivec3 volumeSize = ivec3(VOXEL_VOLUME_SIZE, VOXEL_VOLUME_SIZE / 2, VOXEL_VOLUME_SIZE);
const ivec3 offsets[6] = ivec3[6](ivec3(1,0,0),ivec3(-1,0,0),ivec3(0,1,0),ivec3(0,-1,0),ivec3(0,0,1),ivec3(0,0,-1));
bool validCell(ivec3 p) { return all(greaterThanEqual(p, ivec3(0))) && all(lessThan(p, volumeSize)); }
vec3 readPrevious(sampler3D volume, ivec3 p) { return validCell(p) ? texelFetch(volume, p, 0).rgb : vec3(0.0); }
vec3 propagate(sampler3D volume, ivec3 p) {
    vec3 sum = readPrevious(volume, p);
    for (int i = 0; i < 6; ++i) sum += readPrevious(volume, p + offsets[i]);
    return sum / 7.01;
}
void main() {
    ivec3 p = ivec3(gl_GlobalInvocationID);
    if (!validCell(p)) return;
    ivec3 previousPos = p + ivec3(floor(cameraPosition) - floor(previousCameraPosition));
    uint voxel = texelFetch(voxelSampler, p, 0).r;
    vec3 light = vec3(0.0);
    vec3 emission = getBlocklightColor(int(voxel) + 1);
    bool flower = voxel >= 34u && voxel <= 39u;
    bool transparent = voxel <= 1u || (voxel >= 200u && voxel <= 216u) || (flower && maxOf(emission) <= 0.0);
    if (transparent) {
        // No out-of-bounds fetch at the rectangular volume boundary or on a camera jump.
        if (frameCounter > 0) {
            if ((frameCounter & 1) == 0) light = propagate(floodfillSampler, previousPos);
            else light = propagate(floodfillSamplerCopy, previousPos);
        }
        if (voxel >= 200u && voxel <= 216u) light *= pow(blocklightTintArray[min(voxel - 200u, uint(blocklightTintArray.length() - 1))], vec3(FLOODFILL_RADIUS));
    } else {
        light = pow(max(emission, vec3(0.0)), vec3(FLOODFILL_RADIUS));
        #ifdef OVERWORLD
        if (flower) light *= 1.0 - wetness;
        #endif
    }
    if ((frameCounter & 1) == 0) imageStore(floodfill_img_copy, p, vec4(light, float(voxel)));
    else imageStore(floodfill_img, p, vec4(light, float(voxel)));
}
