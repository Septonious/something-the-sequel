// WORLD-SPACE DIRECT BLOCK LIGHTING / DDA — final experiment baseline.
// CONTRACT: source selection reads directNearestSampler; ray traversal reads
// directOccSampler (R32UI); voxelSampler supplies emitter material color.
// R32UI high byte is the canonical SHAPE class; 0..12 low bits contain
// face-vertex geometric state accumulated atomically in the shadow pass.
// Geometry here is model-based, NOT Minecraft collision bounding boxes.
// This file does not modify ambient AO, sun shadows or the material PBR.
// Known limitation: max of projected blocker coverages is not an exact union
// of area-light shadows; the long-standing full-cube seam leak remains.
#if defined LOCAL_DIRECT_LIGHTING && defined VX_SUPPORT && (defined GBUFFERS_TERRAIN || defined GBUFFERS_BLOCK || defined GBUFFERS_ENTITIES)
const float localReceiverBias = 0.025;
const float localGrazingThreshold = 0.008;
const float localOverlapThreshold = 0.001;
uniform usampler3D directOccSampler, directNearestSampler;
#if LOCAL_LIGHT_DEBUG == 4
uniform usampler3D directLightsSampler;
#endif
#if LOCAL_LIGHT_DEBUG > 0
vec3 localLightDebugColor = vec3(0.0);
#endif

// Analytic projected blocker silhouette. A box projected along a ray is a 2D
// zonotope: its six possible boundary edges are parallel to the projected
// block axes. Three pairs of projected edge normals bound that silhouette.
// Unlike post-process blur, this operates in world space per source and does
// not mix differently coloured emitters or depend on camera orientation.
// Finite ray/box slab hit plus single-source projected silhouette penumbra.
// The projected estimate is approximate near silhouette vertices; no second
// independent binary seam penalty is applied (avoids hard+soft double shadows).
float localBoxCoverage(vec3 origin, vec3 direction, vec3 inverseRay, mat3 edgeNormals, vec3 validEdges, vec3 boxMin, vec3 boxMax, float start, float finish, float radiusSlope) {
    vec3 a = (boxMin - origin) * inverseRay, b = (boxMax - origin) * inverseRay;
    vec3 low = min(a, b), high = max(a, b);
    float entry = max(max(low.x, low.y), low.z), exit = min(min(high.x, high.y), high.z);
    bool hardHit = entry <= finish && exit >= start && min(finish, exit) - max(start, entry) > localOverlapThreshold;
    if (radiusSlope < 0.00001) return float(hardHit);

    vec3 centre = (boxMin + boxMax) * 0.5, extent = (boxMax - boxMin) * 0.5;
    vec3 relative = centre - origin;
    float along = dot(relative, direction);
    float halfLength = dot(extent, abs(direction));
    if (along + halfLength < start || along - halfLength > finish) return 0.0;

    // Support-plane distance to the six edges of the projected silhouette.
    // For points inside, the maximum signed edge distance is exact; for points
    // outside it is a conservative approximation near polygon vertices.
    vec3 gap = abs(vec3(dot(relative, edgeNormals[0]), dot(relative, edgeNormals[1]), dot(relative, edgeNormals[2])))
             - vec3(dot(extent, abs(edgeNormals[0])), dot(extent, abs(edgeNormals[1])), dot(extent, abs(edgeNormals[2])));
    gap = mix(vec3(-1000.0), gap, validEdges);
    float clearance = max(gap.x, max(gap.y, gap.z));
    float penumbra = radiusSlope * clamp(along, start, finish);
    if (penumbra < localOverlapThreshold) return float(hardHit);
    return 1.0 - smoothstep(-penumbra, penumbra, clearance);
}


// Captured R32UI occupancy word: high byte is a unique geometry family; low
// nine bits encode observed vertex positions in three bins on each axis.
// The fallback supports older CPU/GPU reference tests using raw byte shapes.
uint localShapeId(uint occWord) { return occWord > 255u ? occWord >> 24u : occWord; }

// Recover the thin axis and whether the panel lies on the near/far boundary.
// Actual vanilla panel models use a 3/16 block thickness. For unusual or
// incompatible texture-pack geometry, an unresolved state produces NO fake
// midpoint panel: this avoids the notorious premature door shadow.
bool localPanelBounds(uint occWord, ivec3 cell, out vec3 low, out vec3 high, out int thinAxis) {
    low = vec3(cell); high = low + vec3(1.0); thinAxis = -1;
    uint bits = occWord & 511u;
    for (int axis = 0; axis < 3; axis++) {
        uint flags = (bits >> uint(axis * 3)) & 7u;
        bool lo = (flags & 1u) != 0u, hi = (flags & 4u) != 0u;
        if (lo == hi) continue;
        if (thinAxis >= 0) return false; // a panel must have exactly one thin axis
        thinAxis = axis;
        if (lo) high[axis] = low[axis] + 0.1875;
        else low[axis] = high[axis] - 0.1875;
    }
    return thinAxis >= 0;
}

// Four openings approximate the perforation in iron/copper/oak trapdoor
// textures. They are not claimed to reproduce individual alpha texels. The
// panel's outer frame plus two crossing bars are analytic AABBs so there is
// never a one-block-wide fake cross occluder in place of an open trapdoor.
float localPerforatedPanelCoverage(vec3 origin, vec3 direction, vec3 inverseRay, mat3 edgeNormals, vec3 validEdges, vec3 low, vec3 high, int axis, float start, float finish, float slope) {
    vec3 sideLength = high - low;
    float coverage = 0.0;
    int u = axis == 0 ? 1 : 0, v = axis == 2 ? 1 : 2;
    for (int k = 0; k < 2; k++) {
        vec3 a = low, b = high;
        int side = k == 0 ? u : v;
        b[side] = low[side] + sideLength[side] * 0.1875;
        coverage = max(coverage, localBoxCoverage(origin, direction, inverseRay, edgeNormals, validEdges, a, b, start, finish, slope));
        a[side] = high[side] - sideLength[side] * 0.1875;
        b[side] = high[side];
        coverage = max(coverage, localBoxCoverage(origin, direction, inverseRay, edgeNormals, validEdges, a, b, start, finish, slope));
        a = low; b = high;
        a[side] = low[side] + sideLength[side] * 0.4375;
        b[side] = low[side] + sideLength[side] * 0.5625;
        coverage = max(coverage, localBoxCoverage(origin, direction, inverseRay, edgeNormals, validEdges, a, b, start, finish, slope));
        if (coverage >= 0.999) return coverage;
    }
    return coverage;
}
// Exact post and rail bounds avoid the half-block widening caused by 4^3 quantization.
float localFenceCoverage(vec3 origin, vec3 direction, vec3 inverseRay, mat3 edgeNormals, vec3 validEdges, ivec3 cell, uint connections, float start, float finish, float radiusSlope) {
    vec3 base = vec3(cell);
    float cover = localBoxCoverage(origin, direction, inverseRay, edgeNormals, validEdges, base + vec3(0.375, 0.0, 0.375), base + vec3(0.625, 1.0, 0.625), start, finish, radiusSlope);
    if (cover >= 0.999) return 1.0;
    for (int level = 0; level < 2; level++) {
        float y = level == 0 ? 0.375 : 0.75;
        if ((connections & 1u) != 0u) cover = max(cover, localBoxCoverage(origin, direction, inverseRay, edgeNormals, validEdges, base + vec3(0.375, y, 0.0), base + vec3(0.625, y + 0.1875, 0.5), start, finish, radiusSlope));
        if ((connections & 2u) != 0u) cover = max(cover, localBoxCoverage(origin, direction, inverseRay, edgeNormals, validEdges, base + vec3(0.5, y, 0.375), base + vec3(1.0, y + 0.1875, 0.625), start, finish, radiusSlope));
        if ((connections & 4u) != 0u) cover = max(cover, localBoxCoverage(origin, direction, inverseRay, edgeNormals, validEdges, base + vec3(0.375, y, 0.5), base + vec3(0.625, y + 0.1875, 1.0), start, finish, radiusSlope));
        if ((connections & 8u) != 0u) cover = max(cover, localBoxCoverage(origin, direction, inverseRay, edgeNormals, validEdges, base + vec3(0.0, y, 0.375), base + vec3(0.5, y + 0.1875, 0.625), start, finish, radiusSlope));
        if (cover >= 0.999) break;
    }
    return cover;
}

// State-resolved fence gate: a CLOSED gate spans one horizontal axis and
// is thin along the other. An OPEN gate spans both axes, so its cross-opening
// is conservatively unobstructed rather than casting a false full doorway.
float localGateCoverage(vec3 origin, vec3 direction, vec3 inverseRay, mat3 edgeNormals, vec3 validEdges, ivec3 cell, uint features, float start, float finish, float radiusSlope) {
    uint edges = (features >> 9u) & 15u;
    bool eastWest = (edges & 10u) == 10u && (edges & 5u) == 0u;
    bool northSouth = (edges & 5u) == 5u && (edges & 10u) == 0u;
    if (!eastWest && !northSouth) return 0.0; // open gate
    vec3 lo = vec3(cell), hi = lo + 1.0;
    int across = eastWest ? 0 : 2, thickness = eastWest ? 2 : 0;
    lo[thickness] += 0.375; hi[thickness] -= 0.375;
    float result = 0.0;
    for (int part = 0; part < 4; part++) {
        vec3 a = lo, b = hi;
        if (part < 2) {
            if (part == 0) b[across] = lo[across] + 0.1875;
            else a[across] = hi[across] - 0.1875;
        } else {
            a.y = lo.y + (part == 2 ? 0.375 : 0.75);
            b.y = a.y + 0.1875;
        }
        result = max(result, localBoxCoverage(origin, direction, inverseRay, edgeNormals, validEdges, a, b, start, finish, radiusSlope));
        if (result >= 0.999) return result;
    }
    return result;
}

// Vanilla walls use a thick core plus low/wide connected arms. The core is
// retained even when the in-game 'up' bit would remove it (known approximation);
// it is much narrower and less harmful than a full 1x1x1 blocker.
float localWallCoverage(vec3 origin, vec3 direction, vec3 inverseRay, mat3 edgeNormals, vec3 validEdges, ivec3 cell, uint features, float start, float finish, float radiusSlope) {
    vec3 base = vec3(cell);
    float result = localBoxCoverage(origin, direction, inverseRay, edgeNormals, validEdges, base + vec3(0.25,0.0,0.25), base + vec3(0.75,1.0,0.75), start, finish, radiusSlope);
    uint edges = (features >> 9u) & 15u;
    for (int side = 0; side < 4; side++) {
        if ((edges & (1u << uint(side))) == 0u) continue;
        vec3 a = base + vec3(0.3125,0.0,0.3125), b = base + vec3(0.6875,0.8125,0.6875);
        if (side == 0) a.z = base.z;
        if (side == 1) b.x = base.x + 1.0;
        if (side == 2) b.z = base.z + 1.0;
        if (side == 3) a.x = base.x;
        result = max(result, localBoxCoverage(origin, direction, inverseRay, edgeNormals, validEdges, a, b, start, finish, radiusSlope));
        if (result >= 0.999) return result;
    }
    return result;
}

// Thin iron bars: a central 2/16 cross and up to four connected sheets.
float localBarsCoverage(vec3 origin, vec3 direction, vec3 inverseRay, mat3 edgeNormals, vec3 validEdges, ivec3 cell, uint features, float start, float finish, float radiusSlope) {
    vec3 base = vec3(cell);
    float result = localBoxCoverage(origin, direction, inverseRay, edgeNormals, validEdges, base + vec3(0.4375,0.0,0.4375), base + vec3(0.5625,1.0,0.5625), start, finish, radiusSlope);
    uint edges = (features >> 9u) & 15u;
    for (int side = 0; side < 4; side++) {
        if ((edges & (1u << uint(side))) == 0u) continue;
        vec3 a = base + vec3(0.4375,0.0,0.4375), b = base + vec3(0.5625,1.0,0.5625);
        if (side == 0) a.z = base.z;
        if (side == 1) b.x = base.x + 1.0;
        if (side == 2) b.z = base.z + 1.0;
        if (side == 3) a.x = base.x;
        result = max(result, localBoxCoverage(origin, direction, inverseRay, edgeNormals, validEdges, a, b, start, finish, radiusSlope));
        if (result >= 0.999) return result;
    }
    return result;
}

// Four quarter-block height bands approximate stalagmites without pixel-level voxels.
float localDripstoneCoverage(vec3 origin, vec3 direction, vec3 inverseRay, mat3 edgeNormals, vec3 validEdges, ivec3 cell, bool pointedUp, float start, float finish, float radiusSlope) {
    float cover = 0.0;
    for (int band = 0; band < 4; band++) {
        float level = pointedUp ? float(band) : float(3 - band);
        float radius = 0.375 - level * 0.075;
        vec3 low = vec3(0.5 - radius, float(band) * 0.25, 0.5 - radius);
        vec3 high = vec3(0.5 + radius, float(band + 1) * 0.25, 0.5 + radius);
        cover = max(cover, localBoxCoverage(origin, direction, inverseRay, edgeNormals, validEdges, vec3(cell) + low, vec3(cell) + high, start, finish, radiusSlope));
        if (cover >= 0.999) break;
    }
    return cover;
}

// Generic partial-model fallback: max 4x4x4, never pixel-sized microcells.
bool localMicroOccupied(uint shape, ivec3 cell) {
    if (shape == 2u) return (cell.x == 1 || cell.x == 2 || cell.z == 1 || cell.z == 2);
    if (shape == 40u) { // Copper grate: a coarse 12-edge open frame, not a solid cross.
        ivec3 edge = ivec3(equal(cell, ivec3(0))) + ivec3(equal(cell, ivec3(3)));
        return edge.x + edge.y + edge.z >= 2;
    }
    if (shape == 41u) { // Scaffolding: posts and top rim; braces remain approximate.
        ivec3 edge = ivec3(equal(cell, ivec3(0))) + ivec3(equal(cell, ivec3(3)));
        return (edge.x != 0 && edge.z != 0) || (cell.y == 3 && (edge.x != 0 || edge.z != 0));
    }
    return false;
}

// Trace a finite ray segment inside a 4^3/2^3 microcell volume,
// first clipping the segment to the actual macroblock AABB.
bool localMicroTrace(vec3 origin, vec3 ray, ivec3 macro, uint shape, float start, float finish, int cellsPerAxis) {
    // A neighbor-probe interval is not necessarily inside that neighbor.
    // Clamping an OUTSIDE ray to [0,3] produced false dark triangles on faces.
    vec3 inv = (vec3(greaterThanEqual(ray, vec3(0.0))) * 2.0 - 1.0) / max(abs(ray), vec3(0.000001));
    vec3 a = (vec3(macro) - origin) * inv, b = (vec3(macro) + 1.0 - origin) * inv;
    vec3 low = min(a, b), high = max(a, b);
    float tEnter = max(start, max(max(low.x, low.y), low.z));
    float tExit = min(finish, min(min(high.x, high.y), high.z));
    if (tExit - tEnter <= 0.0001) return false;
    float cellSize = 1.0 / float(cellsPerAxis);
    float t = tEnter + min(0.0005, (tExit - tEnter) * 0.25);
    vec3 current = (origin + ray * t - vec3(macro)) * float(cellsPerAxis);
    ivec3 subcell = clamp(ivec3(floor(current)), ivec3(0), ivec3(cellsPerAxis - 1));
    ivec3 stepDirection = ivec3(greaterThanEqual(ray, vec3(0.0))) * 2 - 1;
    vec3 inverse = 1.0 / max(abs(ray), vec3(0.000001));
    vec3 next = (vec3(subcell) + max(vec3(stepDirection), 0.0)) * cellSize + vec3(macro);
    vec3 sides = (next - origin) * vec3(stepDirection) * inverse;
    vec3 delta = cellSize * inverse;
    for (int i = 0; i < 20; i++) {
        // Map coarse 2^3 subcells back into the 4^3 occupancy model.
        ivec3 fine = subcell * (4 / cellsPerAxis) + ivec3((4 / cellsPerAxis) / 2);
        if (localMicroOccupied(shape, fine)) return true;
        float along = min(sides.x, min(sides.y, sides.z));
        if (along > tExit) break;
        if (sides.x <= sides.y && sides.x <= sides.z) { sides.x += delta.x; subcell.x += stepDirection.x; }
        else if (sides.y <= sides.z) { sides.y += delta.y; subcell.y += stepDirection.y; }
        else { sides.z += delta.z; subcell.z += stepDirection.z; }
        if (any(lessThan(subcell, ivec3(0))) || any(greaterThanEqual(subcell, ivec3(cellsPerAxis)))) break;
    }
    return false;
}

// Dispatch one captured shape family; special receiver-cell zero-radius rule
// avoids self-penumbra while retaining real through-block occlusion.
float localCellCoverage(vec3 origin, vec3 direction, vec3 inverseRay, mat3 edgeNormals, vec3 validEdges, ivec3 cell, ivec3 receiverSolid, ivec3 emitter, float start, float finish, float radiusSlope, bool adjacent) {
    if (finish - start <= 0.0001 || cell == emitter || any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, ivec3(voxelVolumeSize)))) return 0.0;
    uint occWord = texelFetch(directOccSampler, cell, 0).r;
    uint shape = localShapeId(occWord);
    if (shape == 0u || (adjacent && shape == 2u)) return 0.0;
    // The receiving voxel may contain substantial geometry (stair treads, wall backs).
    // Test only the EXACT center ray there: projecting the source disk onto the receiver
    // itself would create false self-shadows even for front-facing flat surfaces.
    float effectiveSlope = cell == receiverSolid ? 0.0 : radiusSlope;
    if (shape >= 50u && shape <= 52u) {
        vec3 panelMin, panelMax; int thinAxis;
        if (!localPanelBounds(occWord, cell, panelMin, panelMax, thinAxis)) return 0.0;
        if (shape == 52u) return localPerforatedPanelCoverage(origin, direction, inverseRay, edgeNormals, validEdges, panelMin, panelMax, thinAxis, start, finish, effectiveSlope);
        return localBoxCoverage(origin, direction, inverseRay, edgeNormals, validEdges, panelMin, panelMax, start, finish, effectiveSlope);
    }
    if (shape == 53u) return localGateCoverage(origin, direction, inverseRay, edgeNormals, validEdges, cell, occWord, start, finish, effectiveSlope);
    if (shape == 54u) return localWallCoverage(origin, direction, inverseRay, edgeNormals, validEdges, cell, occWord, start, finish, effectiveSlope);
    if (shape == 55u) return localBarsCoverage(origin, direction, inverseRay, edgeNormals, validEdges, cell, occWord, start, finish, effectiveSlope);
    if (shape == 1u) return localBoxCoverage(origin, direction, inverseRay, edgeNormals, validEdges, vec3(cell), vec3(cell) + 1.0, start, finish, effectiveSlope);
    if (shape == 34u || shape == 35u) {
        vec3 low = vec3(cell), high = vec3(cell) + 1.0;
        if (shape == 34u) high.y -= 0.5; else low.y += 0.5;
        return localBoxCoverage(origin, direction, inverseRay, edgeNormals, validEdges, low, high, start, finish, effectiveSlope);
    }
    if (shape >= 16u && shape <= 31u) return localFenceCoverage(origin, direction, inverseRay, edgeNormals, validEdges, cell, shape - 16u, start, finish, effectiveSlope);
    if (shape == 32u || shape == 33u) return localDripstoneCoverage(origin, direction, inverseRay, edgeNormals, validEdges, cell, shape == 32u, start, finish, effectiveSlope);
    // Unknown alpha-tested meshes retain the conservative 4^3/2^3 binary fallback.
    // They cannot reliably be softened without actual geometry or an opacity field.
    int resolution = (shape == 40u || shape == 41u || start < LOCAL_SHADOW_DETAIL_RANGE) ? 4 : 2;
    return float(localMicroTrace(origin, direction, cell, shape, start, finish, resolution));
}

// One bounded DDA walk per light, max 64 macrocell steps. Adjacent-cell
// probes apply only near voxel boundaries; repeated occlusion uses max not sum.
float localVisibility(vec3 surface, vec3 normal, vec3 source) {
    vec3 origin = surface + normal * localReceiverBias;
    vec3 segment = source - origin;
    float distanceRay = length(segment);
    if (distanceRay < 0.2) return 1.0;
    vec3 direction = segment / distanceRay;
    ivec3 signRay = ivec3(greaterThanEqual(direction, vec3(0.0))) * 2 - 1;
    vec3 invAbs = 1.0 / max(abs(direction), vec3(0.000001));
    vec3 inverseRay = vec3(signRay) * invAbs;
    vec3 edgeX = vec3(0.0, direction.z, -direction.y);
    vec3 edgeY = vec3(-direction.z, 0.0, direction.x);
    vec3 edgeZ = vec3(direction.y, -direction.x, 0.0);
    vec3 edgeLength2 = vec3(dot(edgeX, edgeX), dot(edgeY, edgeY), dot(edgeZ, edgeZ));
    mat3 edgeNormals = mat3(edgeX * inversesqrt(max(edgeLength2.x, 0.0000001)),
                            edgeY * inversesqrt(max(edgeLength2.y, 0.0000001)),
                            edgeZ * inversesqrt(max(edgeLength2.z, 0.0000001)));
    vec3 validEdges = vec3(greaterThan(edgeLength2, vec3(0.0000001)));
    float radiusSlope = LOCAL_SHADOW_SOURCE_RADIUS / distanceRay;
    ivec3 cell = ivec3(floor(origin));
    ivec3 receiverSolid = ivec3(floor(surface - normal * 0.04));
    ivec3 emitter = ivec3(floor(source));
    vec3 sides = (vec3(cell) + max(vec3(signRay), 0.0) - origin) * vec3(signRay) * invAbs;
    float entered = 0.0;
    float occlusion = 0.0;
    for (int i = 0; i < 64; i++) {
        if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, ivec3(voxelVolumeSize)))) break;
        if (cell == emitter || entered >= distanceRay - 0.05) break;
        float left = min(distanceRay - 0.05, min(sides.x, min(sides.y, sides.z)));
        occlusion = max(occlusion, localCellCoverage(origin, direction, inverseRay, edgeNormals, validEdges, cell, receiverSolid, emitter, entered, left, radiusSlope, false));
        if (occlusion >= 0.999) return 0.0;

        // The ray can skim a neighboring full voxel or thin occluder without entering
        // its macro cell. Inspect only the neighboring faces/edges within the source cone.
        // This also closes tiny light leaks at shared block corners.
        float middle = (entered + left) * 0.5;
        float margin = min(radiusSlope * middle + 0.012, 0.45);
        vec3 fracCell = fract(origin + direction * middle);
        ivec3 border = ivec3(fracCell.x < margin ? -1 : (fracCell.x > 1.0 - margin ? 1 : 0),
                             fracCell.y < margin ? -1 : (fracCell.y > 1.0 - margin ? 1 : 0),
                             fracCell.z < margin ? -1 : (fracCell.z > 1.0 - margin ? 1 : 0));
        if (any(notEqual(border, ivec3(0)))) {
            for (int mask = 1; mask < 8; mask++) {
                if (((mask & 1) != 0 && border.x == 0) || ((mask & 2) != 0 && border.y == 0) || ((mask & 4) != 0 && border.z == 0)) continue;
                ivec3 neighbor = cell + ivec3((mask & 1) != 0 ? border.x : 0, (mask & 2) != 0 ? border.y : 0, (mask & 4) != 0 ? border.z : 0);
                occlusion = max(occlusion, localCellCoverage(origin, direction, inverseRay, edgeNormals, validEdges, neighbor, receiverSolid, emitter, entered, left, radiusSlope, true));
                if (occlusion >= 0.999) return 0.0;
            }
        }
        if (left >= distanceRay - 0.05) break;
        if (sides.x <= sides.y && sides.x <= sides.z) { entered = sides.x; sides.x += invAbs.x; cell.x += signRay.x; }
        else if (sides.y <= sides.z) { entered = sides.y; sides.y += invAbs.y; cell.y += signRay.y; }
        else { entered = sides.z; sides.z += invAbs.z; cell.z += signRay.z; }
    }
    return 1.0 - occlusion;
}

// Up to four preselected emitters per 4-block receiver cell. Cheap distance,
// facing and attenuation checks run BEFORE the relatively expensive DDA walk.
vec3 getLocalDirectLighting(vec3 worldPos, vec3 worldNormal, float emission) {
    if (emission > 0.001) return vec3(0.0);
    vec3 receiver = worldToVoxel(worldPos);
    if (any(lessThan(receiver, vec3(1.0))) || any(greaterThanEqual(receiver, voxelVolumeSize - 1.0))) return vec3(0.0);
    #if LOCAL_LIGHT_DEBUG == 6
    ivec3 inner = ivec3(floor(receiver - worldNormal * 0.08));
    uint occ = localShapeId(texelFetch(directOccSampler, clamp(inner, ivec3(0), ivec3(voxelVolumeSize) - 1), 0).r);
    localLightDebugColor = occ == 0u ? vec3(1.0, 0.0, 0.0) : (occ == 1u ? vec3(0.0, 1.0, 0.0) : vec3(0.0, 0.5, 1.0));
    return vec3(0.0);
    #elif LOCAL_LIGHT_DEBUG == 5
    localLightDebugColor = texelFetch(directNearestSampler, ivec3(0), 0).r == 0xFFFFFFFFu ? vec3(0.0, 1.0, 1.0) : vec3(1.0, 0.0, 0.0);
    return vec3(0.0);
    #endif
    ivec3 origin = ivec3(floor(cameraPosition)) - ivec3(voxelVolumeSize) / 2;
    ivec3 grid = (ivec3(floor(worldPos + cameraPosition)) >> 2) - (origin >> 2);
    if (any(lessThan(grid, ivec3(0))) || any(greaterThanEqual(grid, ivec3(voxelVolumeSize * 0.25) + 1))) return vec3(0.0);
    #if LOCAL_LIGHT_DEBUG == 4
    ivec3 brick = (ivec3(floor(worldPos + cameraPosition)) >> 4) - (origin >> 4);
    ivec3 brickCount = ivec3(VOXEL_VOLUME_SIZE / 16 + 1, VOXEL_VOLUME_SIZE / 32 + 1, VOXEL_VOLUME_SIZE / 16 + 1);
    bool captured = false;
    for (int z = -1; z <= 1; z++) for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
        ivec3 entry = brick + ivec3(x, y, z);
        if (any(lessThan(entry, ivec3(0))) || any(greaterThanEqual(entry, brickCount))) continue;
        for (int rank = 0; rank < 4; rank++) captured = captured || texelFetch(directLightsSampler, ivec3(entry.x * 4 + rank, entry.yz), 0).r != 0u;
    }
    localLightDebugColor = captured ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    return vec3(0.0);
    #endif
    vec3 outputLight = vec3(0.0);
    #if LOCAL_LIGHT_DEBUG > 0
    vec3 unshadowedLight = vec3(0.0);
    int sourceCount = 0;
    #endif
    for (int i = 0; i < 4; i++) {
        uint word = texelFetch(directNearestSampler, ivec3(grid.x * 4 + i, grid.yz), 0).r;
        if (word == 0u) continue;
        #if LOCAL_LIGHT_DEBUG > 0
        sourceCount++;
        #endif
        ivec3 sourceCell = ivec3(int(word & 511u), int((word >> 9u) & 255u), int((word >> 17u) & 511u));
        if (any(lessThan(sourceCell, ivec3(0))) || any(greaterThanEqual(sourceCell, ivec3(voxelVolumeSize)))) continue;
        vec3 source = vec3(sourceCell) + 0.5;
        vec3 offset = source - receiver;
        float distance2 = dot(offset, offset);
        if (distance2 > LOCAL_LIGHT_RADIUS * LOCAL_LIGHT_RADIUS || distance2 < 0.06) continue;
        vec3 direction = offset * inversesqrt(distance2);
        float NoL = clamp(dot(worldNormal, direction), 0.0, 1.0);
        if (NoL <= 0.0) continue;
        uint material = texelFetch(voxelSampler, sourceCell, 0).r;
        vec3 lightColor = getBlocklightColor(int(material) + 1);
        float falloff = clamp(1.0 - sqrt(distance2) / LOCAL_LIGHT_RADIUS, 0.0, 1.0);
        float attenuation = LOCAL_LIGHT_STRENGTH * NoL * falloff * falloff / (1.0 + distance2 * 0.035);
        if (attenuation * max(lightColor.r, max(lightColor.g, lightColor.b)) < 0.002) continue;
        #if LOCAL_LIGHT_DEBUG > 0
        unshadowedLight += lightColor * attenuation;
        #endif
        outputLight += lightColor * attenuation * localVisibility(receiver, worldNormal, source);
    }
    #if LOCAL_LIGHT_DEBUG == 1
    localLightDebugColor = vec3(float(sourceCount) / 4.0, 0.0, 0.0);
    #elif LOCAL_LIGHT_DEBUG == 2
    localLightDebugColor = clamp(unshadowedLight, 0.0, 1.0);
    #elif LOCAL_LIGHT_DEBUG == 3
    localLightDebugColor = clamp(outputLight, 0.0, 1.0);
    #endif
    // A continuous source-domain fade avoids a hard colored-light cube edge.
    vec3 remaining = min(receiver, voxelVolumeSize - receiver);
    float edgeDistance = min(remaining.x, min(remaining.y, remaining.z));
    return outputLight * smoothstep(1.0, 9.0, edgeDistance);
}
#endif
