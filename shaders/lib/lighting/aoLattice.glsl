// Shadow vertex stage writes available face-corner AO; GBuffers samples four
// neighboring lattice cells to smoothly interpolate the cached AO values.
// Input: shadow-pass normals/vertex alpha. Output: material AO multiplier.
const ivec3 aoLatticeSize = ivec3(96, 64, 96);

#ifdef SHADOW
// Only axis-aligned terrain corners contribute; atomicMax makes overlapping writes safe.
void updateAoLattice() {
	vec3 normalAbs = abs(gl_Normal);
	bool terrain = any(equal(ivec3(renderStage), ivec3(MC_RENDER_STAGE_TERRAIN_SOLID, MC_RENDER_STAGE_TERRAIN_CUTOUT, MC_RENDER_STAGE_TERRAIN_CUTOUT_MIPPED)));
	bool corner = all(greaterThanEqual(abs(at_midBlock), vec3(31.0)));

	if (!terrain || !corner || maxOf(normalAbs) < 0.99) return;

	vec3 viewPos = mat3(gl_ModelViewMatrix) * gl_Vertex.xyz + gl_ModelViewMatrix[3].xyz;
	vec3 shadowPos = mat3(shadowModelViewInverse) * viewPos + shadowModelViewInverse[3].xyz;
	ivec3 latticePos = ivec3(floor(shadowPos + fract(cameraPosition) + vec3(aoLatticeSize) * 0.5 + 0.5));

	if (any(lessThan(latticePos, ivec3(0))) || any(greaterThanEqual(latticePos, aoLatticeSize))) return;

	int axis = normalAbs.x > 0.5 ? 0 : (normalAbs.y > 0.5 ? 1 : 2);
	int dir = axis * 2 + int(gl_Normal[axis] < 0.0);

	imageAtomicMax(ao_lattice_img, ivec3(latticePos.x + dir * aoLatticeSize.x, latticePos.yz), uint((1.0 - gl_Color.a) * 254.0 + 0.5) + 1u);
}
#else
// Bilinear AO in the tangent plane of the receiving face; fall back to alpha if incomplete.
float getAoLattice(vec3 worldPos) {
	vec3 faceNormal = mat3(gbufferModelViewInverse) * normal;
	vec3 normalAbs = abs(faceNormal);

	if (aoFull < 0.999 || maxOf(normalAbs) < 0.99) return color.a;

	int axis = normalAbs.x > 0.5 ? 0 : (normalAbs.y > 0.5 ? 1 : 2);
	int axisU = (axis + 1) % 3;
	int axisV = (axis + 2) % 3;
	int dir = axis * 2 + int(faceNormal[axis] < 0.0);

	vec3 latticePos = worldPos + fract(cameraPosition) + vec3(aoLatticeSize) * 0.5;
	     latticePos[axis] += 0.5;
	ivec3 cell = ivec3(floor(latticePos));

	if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell + 1, aoLatticeSize))) return color.a;

	vec3 cellPos = latticePos - vec3(cell);
	ivec3 stepU = ivec3(0);
	ivec3 stepV = ivec3(0);
	stepU[axisU] = 1;
	stepV[axisV] = 1;
	cell.x += dir * aoLatticeSize.x;

	uvec4 occlusion = uvec4(texelFetch(aoLatticeSampler, cell, 0).r,
	                        texelFetch(aoLatticeSampler, cell + stepU, 0).r,
	                        texelFetch(aoLatticeSampler, cell + stepV, 0).r,
	                        texelFetch(aoLatticeSampler, cell + stepU + stepV, 0).r);

	if (any(equal(occlusion, uvec4(0u)))) return color.a;

	vec4 ao = 1.0 - (vec4(occlusion) - 1.0) / 254.0;

	return mix(mix(ao.x, ao.y, cellPos[axisU]), mix(ao.z, ao.w, cellPos[axisU]), cellPos[axisV]);
}
#endif
