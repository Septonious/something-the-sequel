// PER-FRAME EMITTER SELECTION COMPUTE SHADER.
// Each invocation covers one 4x4x4 receiver region and selects four source
// words from nearby 16-block emitter bricks. This is intentionally separate
// from ray marching: selecting a light never proves that it is visible.
// Candidate bounds must not be shrunk past LOCAL_LIGHT_RADIUS + padding.
#include "/lib/common.glsl"
layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;
const ivec3 coarseCells = ivec3(VOXEL_VOLUME_SIZE / 4 + 1, VOXEL_VOLUME_SIZE / 8 + 1, VOXEL_VOLUME_SIZE / 4 + 1);
#if VOXEL_VOLUME_SIZE == 128
const ivec3 workGroups = ivec3(9, 5, 9);
#elif VOXEL_VOLUME_SIZE == 192
const ivec3 workGroups = ivec3(13, 7, 13);
#elif VOXEL_VOLUME_SIZE == 256
const ivec3 workGroups = ivec3(17, 9, 17);
#elif VOXEL_VOLUME_SIZE == 384
const ivec3 workGroups = ivec3(25, 13, 25);
#elif VOXEL_VOLUME_SIZE == 512
const ivec3 workGroups = ivec3(33, 17, 33);
#endif
uniform usampler3D directLightsSampler;
layout(r32ui) writeonly uniform uimage3D direct_nearest_img;
uniform vec3 cameraPosition;

// The output is a 4-word reservoir; no extra tracing rays are performed here.
void main() {
    ivec3 cell = ivec3(gl_GlobalInvocationID);
    if (any(greaterThanEqual(cell, coarseCells))) return;
    ivec3 origin = ivec3(floor(cameraPosition)) - ivec3(VOXEL_VOLUME_SIZE, VOXEL_VOLUME_SIZE / 2, VOXEL_VOLUME_SIZE) / 2;
    ivec3 worldCell = (origin >> 2) + cell;
    vec3 worldReceiver = vec3(worldCell * 4 + 2);
    ivec3 brick = (worldCell * 4 + 2) >> 4;
    ivec3 firstBrick = origin >> 4;
    ivec3 count = ivec3(VOXEL_VOLUME_SIZE / 16 + 1, VOXEL_VOLUME_SIZE / 32 + 1, VOXEL_VOLUME_SIZE / 16 + 1);
    uint found[4] = uint[4](0u, 0u, 0u, 0u);
    float weights[4] = float[4](0.0, 0.0, 0.0, 0.0);
    // Every candidate cube intersecting the light radius must lie in this
    // brick range. Avoid the unconditional 125-iteration cube search.
    float searchRadius = LOCAL_LIGHT_RADIUS + 3.0;
    ivec3 firstCandidate = ivec3(floor((worldReceiver - searchRadius) / 16.0));
    ivec3 lastCandidate = ivec3(floor((worldReceiver + searchRadius) / 16.0));
    for (int z = firstCandidate.z; z <= lastCandidate.z; z++) {
    for (int y = firstCandidate.y; y <= lastCandidate.y; y++) {
    for (int x = firstCandidate.x; x <= lastCandidate.x; x++) {
        ivec3 candidate = ivec3(x, y, z);
        // Reject bricks which cannot contain a light within the configured reach.
        vec3 boxMin = vec3(candidate * 16);
        vec3 nearest = clamp(worldReceiver, boxMin, boxMin + 16.0);
        vec3 separation = nearest - worldReceiver;
        if (dot(separation, separation) > (LOCAL_LIGHT_RADIUS + 3.0) * (LOCAL_LIGHT_RADIUS + 3.0)) continue;
        ivec3 slot = candidate - firstBrick;
        if (any(lessThan(slot, ivec3(0))) || any(greaterThanEqual(slot, count))) continue;
        for (int j = 0; j < 4; j++) {
            uint word = texelFetch(directLightsSampler, ivec3(slot.x * 4 + j, slot.yz), 0).r;
            if (word == 0u) continue;
            ivec3 source = ivec3(int(word & 511u), int((word >> 9u) & 255u), int((word >> 17u) & 511u));
            if ((source + origin) >> 4 != candidate) continue;
            vec3 difference = vec3(source + origin) + 0.5 - worldReceiver;
            float dist2 = dot(difference, difference);
            if (dist2 > (LOCAL_LIGHT_RADIUS + 4.0) * (LOCAL_LIGHT_RADIUS + 4.0)) continue;
            float score = float(word >> 26u) / (dist2 + 16.0);
            for (int rank = 0; rank < 4; rank++) {
                if (score > weights[rank] || (score == weights[rank] && word > found[rank])) {
                    for (int move = 3; move > rank; move--) { weights[move] = weights[move - 1]; found[move] = found[move - 1]; }
                    weights[rank] = score; found[rank] = word;
                    break;
                }
            }
        }
    } } }
    for (int rank = 0; rank < 4; rank++) imageStore(direct_nearest_img, ivec3(cell.x * 4 + rank, cell.yz), uvec4(found[rank]));
    #if LOCAL_LIGHT_DEBUG == 5
    if (cell == ivec3(0)) imageStore(direct_nearest_img, ivec3(0), uvec4(0xFFFFFFFFu));
    #endif
}
