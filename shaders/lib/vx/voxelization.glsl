// SHADOW-PASS WORLD VOXEL CAPTURE.
// This pass sees ONLY geometry Iris submits to shadow rendering; neither the
// occupancy texture nor DDA tracing can infer blocks that were culled entirely.
// Always distinguish block MATERIAL ID from the separate geometry-state bits.
// Vertex-stage writes happen BEFORE alpha-test/discard in shadow.fsh; thus
// texture alpha is approximated explicitly for perforated panel families.
// Foliage, carpets, buttons and other decorations never cast DDA occlusion.
const vec3 voxelVolumeSize = vec3(VOXEL_VOLUME_SIZE, VOXEL_VOLUME_SIZE * 0.5, VOXEL_VOLUME_SIZE);

// Translate camera-relative view-space world coordinates into integer-grid voxels.
vec3 worldToVoxel(vec3 worldPos) {
	return worldPos + fract(cameraPosition) + voxelVolumeSize * 0.5;
}

// Reverse the camera-centered voxel transformation.
vec3 voxelToWorld(vec3 voxelPos) {
	return voxelPos - fract(cameraPosition) - voxelVolumeSize * 0.5;
}

#if defined SHADOW && defined LOCAL_DIRECT_LIGHTING && defined VX_SUPPORT
// Emissive blocks must contribute light, not obstruct other emitted rays.
// Share this exact classification with source capture so neighboring light blocks
// cannot self-shadow each other. Do not classify disabled emitters as transparent.
float localSourceStrength(uint id) {
    if (id < 3u || (id > 85u && id < 194u) || id > 200u) return 0.0;
    vec3 color = getBlocklightColor(int(id));
    return max(color.r, max(color.g, color.b));
}
#endif

#ifdef SHADOW
// 0 empty / emitter; 1 full cube; 2 unknown partial model;
// 16..31 fence with north/east/south/west connection bits.
// SHAPE ENCODING — ONE MATERIAL ID PER VANILLA DOOR / TRAPDOOR TYPE.
// Low 9 state bits: three position bins per axis, accumulated over ALL
// submitted panel vertices. Each vertex belongs to the same canonical block.
// For a rotated door, the unique narrow axis is x or z. Closed trapdoors
// have a narrow y axis; opening them rotates that thin axis to x or z.
// Thickness and side are then read from the actual rendered model, including
// its facing, hinge, open/closed state and upper/lower half.
const uint DIRECT_PANEL_SOLID_DOOR = 50u;
const uint DIRECT_PANEL_SOLID_TRAP = 51u;
const uint DIRECT_PANEL_PERFORATED_TRAP = 52u;

// Classify materials into non-occluding, solid, and analytic shape families.
uint directShapeId(uint id, int stage, float sourceStrength) {
    // Avoid treating source meshes and nonstructural vegetation/decoration as blockers.
    if (sourceStrength > 0.025 || id == 400u || (id >= 304u && id <= 319u) || (id >= 35u && id <= 40u)) return 0u;
    if (id == 410u) return DIRECT_PANEL_SOLID_DOOR;
    if (id == 411u) return DIRECT_PANEL_SOLID_TRAP;
    if (id == 412u) return DIRECT_PANEL_PERFORATED_TRAP;
    if (id == 413u) return 53u; // all orientations of fence gates
    if (id == 414u) return 54u; // connected walls
    if (id == 415u) return 55u; // iron-bar lattice
    if (id == 402u) return 40u;
    if (id == 403u) return 41u;
    if (id >= 100u && id < 116u) return 16u + id - 100u;
    if (id >= 120u && id <= 123u) return 32u + id - 120u;
    if (id == 2u || id == 3u || id == 4u || id == 5u || id == 6u || id == 7u || id == 13u) return 2u;
    // Remaining unknown cutout materials must not turn into opaque cubes.
    return stage == MC_RENDER_STAGE_TERRAIN_SOLID ? 1u : 0u;
}

// at_midBlock measures the offset of a vertex from its 16x16x16 block
// center in 1/64-block units (Iris). Reconstruct the local vertex *without*
// an extra world-space matrix multiplication. The threshold bins distinguish
// [0, 3/16] from [13/16, 1] as used in vanilla panel model JSON.
uint directPanelVertexBits() {
    vec3 v = vec3(0.5) - at_midBlock / 64.0;
    uvec3 low = uvec3(lessThan(v, vec3(0.28)));
    uvec3 middle = uvec3(greaterThanEqual(v, vec3(0.28))) * uvec3(lessThanEqual(v, vec3(0.72)));
    uvec3 high = uvec3(greaterThan(v, vec3(0.72)));
    return (low.x | middle.x << 1u | high.x << 2u) |
           ((low.y | middle.y << 1u | high.y << 2u) << 3u) |
           ((low.z | middle.z << 1u | high.z << 2u) << 6u);
}

// Connection flags for walls / bars / gates: north,east,south,west.
// Only a vertex touching the block's outer edge can set a connection bit;
// center posts never set these bits. The model itself resolves adjacency.
uint directConnectionVertexBits() {
    vec3 v = vec3(0.5) - at_midBlock / 64.0;
    return (uint(v.z < 0.13) << 9u) | (uint(v.x > 0.87) << 10u) |
           (uint(v.z > 0.87) << 11u) | (uint(v.x < 0.13) << 12u);
}
#endif

bool isInsideVoxelVolume(vec3 voxelPos) {
    // Strict upper bounds prevent imageStore at x/y/z == imageSize.
    // Componentwise comparison also avoids three unnecessary divisions.
    return all(greaterThanEqual(voxelPos, vec3(0.0))) && all(lessThan(voxelPos, voxelVolumeSize));
}

#if defined SHADOW && defined LOCAL_DIRECT_LIGHTING && defined VX_SUPPORT
// Atomically reserve the top four captured emitter candidates per 16-block brick.
void captureLocalLight(uint id, ivec3 pos, float strength) {
    if (strength <= 0.025) return;

    uint priority = uint(clamp(strength * 32.0 + 0.5, 1.0, 63.0));
    if (id == 5u || id == 6u || id == 15u || id == 16u) priority = 32u;
    uint value = uint(pos.x) | (uint(pos.y) << 9u) | (uint(pos.z) << 17u) | (priority << 26u);
    ivec3 volumeOrigin = ivec3(floor(cameraPosition)) - ivec3(voxelVolumeSize) / 2;
    ivec3 firstBrick = volumeOrigin >> 4;
    ivec3 brick = ((pos + volumeOrigin) >> 4) - firstBrick;
    const ivec3 brickCount = ivec3(VOXEL_VOLUME_SIZE / 16 + 1, VOXEL_VOLUME_SIZE / 32 + 1, VOXEL_VOLUME_SIZE / 16 + 1);
    if (any(lessThan(brick, ivec3(0))) || any(greaterThanEqual(brick, brickCount))) return;
    for (int i = 0; i < 4; i++) {
        uint previous = imageAtomicMax(direct_lights_img, ivec3(brick.x * 4 + i, brick.yz), value);
        if (previous == value || previous == 0u) break;
        value = min(value, previous);
    }
}
#endif

#ifdef SHADOW
// Store material and occupancy independently; only panel/connection models
// require atomic OR from all four vertices for orientation-state recovery.
void updateVoxelMap(uint id, bool quadSample) {
    #ifdef LOCAL_DIRECT_LIGHTING
    if (!quadSample && (id == 400u || (id >= 304u && id <= 319u) || (id >= 35u && id <= 40u) ||
        (renderStage != MC_RENDER_STAGE_TERRAIN_SOLID && renderStage != MC_RENDER_STAGE_TERRAIN_CUTOUT && renderStage != MC_RENDER_STAGE_TERRAIN_CUTOUT_MIPPED))) return;
    #endif
	vec3 modelPos = gl_Vertex.xyz + at_midBlock / 64.0;
	vec3 viewPos  = mat3(gl_ModelViewMatrix) * modelPos + gl_ModelViewMatrix[3].xyz;
	vec3 shadowPos = mat3(shadowModelViewInverse) * viewPos + shadowModelViewInverse[3].xyz;
	vec3 voxelPos = worldToVoxel(shadowPos);

	#ifndef SHADOW_COLORWHEEL
		bool doVoxelization = id != 1 && any(equal(ivec4(renderStage), ivec4(MC_RENDER_STAGE_TERRAIN_SOLID, MC_RENDER_STAGE_TERRAIN_TRANSLUCENT, MC_RENDER_STAGE_TERRAIN_CUTOUT, MC_RENDER_STAGE_TERRAIN_CUTOUT_MIPPED)));
	#else
		bool doVoxelization = true;
	#endif

	if (doVoxelization && isInsideVoxelVolume(voxelPos)) {
        if (quadSample) imageStore(voxel_img, ivec3(voxelPos), uvec4(max(id - 1, 1), uvec3(0u)));
        #ifdef LOCAL_DIRECT_LIGHTING
        float sourceStrength = localSourceStrength(id);
        if (renderStage == MC_RENDER_STAGE_TERRAIN_SOLID || renderStage == MC_RENDER_STAGE_TERRAIN_CUTOUT || renderStage == MC_RENDER_STAGE_TERRAIN_CUTOUT_MIPPED) {
            uint shape = directShapeId(id, renderStage, sourceStrength);
            if (shape != 0u) {
                uint packedShape = shape << 24u;
                if (shape >= DIRECT_PANEL_SOLID_DOOR && shape <= 55u) {
                    // All door/trapdoor quad vertices contribute to the same state.
                    uint features = shape <= DIRECT_PANEL_PERFORATED_TRAP ? directPanelVertexBits() :
                                    (directPanelVertexBits() | directConnectionVertexBits());
                    imageAtomicOr(direct_occ_img, ivec3(voxelPos), packedShape | features);
                } else {
                    imageStore(direct_occ_img, ivec3(voxelPos), uvec4(packedShape));
                }
            }
        }
        if (quadSample) captureLocalLight(id, ivec3(voxelPos), sourceStrength);
        #endif
	}
}
#endif