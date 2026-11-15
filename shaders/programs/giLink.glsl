#include "/lib/common.glsl"

layout (local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

const ivec3 workGroups = ivec3(16, 8, 4);

uniform usampler3D quadHashSampler;

layout(r32ui) uniform uimage3D voxel_box_img;
layout(rgba32ui) uniform uimage3D quad_pool_img;

void main() {
	ivec3 slot = ivec3(gl_GlobalInvocationID);
	ivec3 base = ivec3(slot.x * 5, slot.yz);

	if (texelFetch(quadHashSampler, base, 0).r == 0u) return;

	uint corner = texelFetch(quadHashSampler, base + ivec3(2, 0, 0), 0).r;
	uint edgeA = texelFetch(quadHashSampler, base + ivec3(3, 0, 0), 0).r;
	uint edgeB = texelFetch(quadHashSampler, base + ivec3(4, 0, 0), 0).r;
	int cellIndex = int((corner >> 18u) | ((edgeA >> 18u) << 14u));
	ivec3 cell = ivec3(cellIndex % VOXEL_VOLUME_SIZE, (cellIndex / VOXEL_VOLUME_SIZE) % (VOXEL_VOLUME_SIZE / 2), cellIndex / (VOXEL_VOLUME_SIZE * (VOXEL_VOLUME_SIZE / 2)));
	uint index = uint(slot.x + slot.y * 128 + slot.z * 8192);
	uint previous = imageAtomicExchange(voxel_box_img, ivec3(cell.x * 2, cell.yz), index + 1u);
	ivec3 pointA = ivec3(corner & 63u, (corner >> 6u) & 63u, (corner >> 12u) & 63u);
	ivec3 pointB = ivec3(edgeA & 63u, (edgeA >> 6u) & 63u, (edgeA >> 12u) & 63u);
	ivec3 pointC = ivec3(edgeB & 63u, (edgeB >> 6u) & 63u, (edgeB >> 12u) & 63u);
	ivec3 spanA = pointB - pointA;
	ivec3 spanB = pointC - pointA;
	ivec3 facing = spanA.yzx * spanB.zxy - spanA.zxy * spanB.yzx;
	ivec3 low = min(min(pointA, pointB), min(pointC, pointB + spanB));
	ivec3 high = max(max(pointA, pointB), max(pointC, pointB + spanB));
	uvec3 boundLow = uvec3(low >> 2);
	uvec3 boundHigh = uvec3((high + 3) >> 2);
	uvec4 quad = uvec4(corner & 262143u, edgeA & 262143u, edgeB & 262143u, previous);

	imageAtomicOr(voxel_box_img, ivec3(cell.x * 2 + 1, cell.yz), (1u << boundLow.x) | (1u << boundHigh.x) | (512u << boundLow.y) | (512u << boundHigh.y) | (262144u << boundLow.z) | (262144u << boundHigh.z));

	if (int(spanA.x != 0) + int(spanA.y != 0) + int(spanA.z != 0) == 1 && int(spanB.x != 0) + int(spanB.y != 0) + int(spanB.z != 0) == 1 && facing != ivec3(0)) {
		int axis = facing.x != 0 ? 0 : (facing.y != 0 ? 1 : 2);
		uint face = uint(axis * 2 + int(facing[axis] > 0));

		quad.r = uint(low.x) | (uint(low.y) << 6u) | (uint(low.z) << 12u) | (face << 18u) | 0x80000000u;
		quad.g = uint(high.x) | (uint(high.y) << 6u) | (uint(high.z) << 12u);
	}

	imageStore(quad_pool_img, ivec3(index & 63u, (index >> 6u) & 63u, index >> 12u), quad);
}
