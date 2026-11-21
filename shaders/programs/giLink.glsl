#include "/lib/common.glsl"

layout (local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

#if VOXEL_VOLUME_SIZE == 256
const ivec3 workGroups = ivec3(16, 8, 16);
#elif VOXEL_VOLUME_SIZE == 192
const ivec3 workGroups = ivec3(16, 8, 8);
#else
const ivec3 workGroups = ivec3(16, 8, 4);
#endif

uniform usampler3D quadHashSampler;

layout(r32ui) uniform uimage3D voxel_box_img;
layout(rgba32ui) uniform uimage3D quad_pool_img;

layout(std430, binding = 0) buffer giSurfaceList {
	uvec4 surfaceDispatch;
	uvec2 surfaceCells[];
};

void main() {
	ivec3 slot = ivec3(gl_GlobalInvocationID);
	ivec3 base = ivec3(slot.x * 8, slot.yz);

	if (slot == ivec3(0)) surfaceDispatch = uvec4(0u, 1u, 1u, 0u);

	if (texelFetch(quadHashSampler, base, 0).r == 0u) return;

	uint corner = texelFetch(quadHashSampler, base + ivec3(2, 0, 0), 0).r;
	uint edgeA = texelFetch(quadHashSampler, base + ivec3(3, 0, 0), 0).r;
	uint edgeB = texelFetch(quadHashSampler, base + ivec3(4, 0, 0), 0).r;
	uvec2 alphaMask = uvec2(texelFetch(quadHashSampler, base + ivec3(5, 0, 0), 0).r, texelFetch(quadHashSampler, base + ivec3(6, 0, 0), 0).r);
	uint uvFlags = texelFetch(quadHashSampler, base + ivec3(7, 0, 0), 0).r;
	int cellIndex = int((corner >> 18u) | (((edgeA >> 18u) & 511u) << 14u));
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
	bool aligned = int(spanA.x != 0) + int(spanA.y != 0) + int(spanA.z != 0) == 1 && int(spanB.x != 0) + int(spanB.y != 0) + int(spanB.z != 0) == 1 && facing != ivec3(0);
	int axis = facing.x != 0 ? 0 : (facing.y != 0 ? 1 : 2);
	ivec2 plane = ivec2(axis == 0 ? 1 : 0, axis == 2 ? 1 : 2);
	ivec2 uvCorner = ivec2(uvFlags, uvFlags >> 1u) & 1;
	ivec2 uvSpanA = (ivec2(edgeA >> 27u, edgeA >> 28u) & 1) - uvCorner;
	ivec2 uvSpanB = (ivec2(edgeB >> 18u, edgeB >> 19u) & 1) - uvCorner;
	uvec2 cutout = uvec2(0xFFFFFFFFu);

	imageAtomicOr(voxel_box_img, ivec3(cell.x * 2 + 1, cell.yz), (1u << boundLow.x) | (1u << boundHigh.x) | (512u << boundLow.y) | (512u << boundHigh.y) | (262144u << boundLow.z) | (262144u << boundHigh.z));

	if (aligned && alphaMask != cutout && abs(uvSpanA.x) + abs(uvSpanA.y) == 1 && abs(uvSpanB.x) + abs(uvSpanB.y) == 1 && abs(uvSpanA.x) != abs(uvSpanB.x)) {
		cutout = uvec2(0u);

		for (int i = 0; i < 64; i++) {
			vec2 coord = (vec2(i % 8, i / 8) + 0.5) / 8.0;

			coord = spanA[plane.x] != 0 ? vec2(spanA[plane.x] > 0 ? coord.x : 1.0 - coord.x, spanB[plane.y] > 0 ? coord.y : 1.0 - coord.y) : vec2(spanA[plane.y] > 0 ? coord.y : 1.0 - coord.y, spanB[plane.x] > 0 ? coord.x : 1.0 - coord.x);

			ivec2 uvCell = clamp(ivec2((vec2(uvCorner) + coord.x * vec2(uvSpanA) + coord.y * vec2(uvSpanB)) * 8.0), ivec2(0), ivec2(7));
			int uvBit = uvCell.x + uvCell.y * 8;
			uint texelBit = (((uvBit < 32 ? alphaMask.x : alphaMask.y) >> uint(uvBit & 31)) & 1u) << uint(i & 31);

			if (i < 32) cutout.x |= texelBit; else cutout.y |= texelBit;
		}
	}

	if (aligned) {
		uint face = uint(axis * 2 + int(facing[axis] > 0));

		quad.r = uint(low.x) | (uint(low.y) << 6u) | (uint(low.z) << 12u) | (face << 18u) | (((cutout.y >> 14u) & 1023u) << 21u) | 0x80000000u;
		quad.g = uint(high.x) | (uint(high.y) << 6u) | (uint(high.z) << 12u) | ((cutout.y & 16383u) << 18u);
		quad.b = cutout.x;
		quad.a |= (cutout.y >> 24u) << 21u;
	}

	imageStore(quad_pool_img, ivec3(index & 63u, (index >> 6u) & 63u, index >> 12u), quad);
}
