#include "/lib/common.glsl"

#define SHADOW

#ifdef FSH

// VSH Data //
in vec4 color;
in vec3 worldPos;
in vec2 texCoord, lmCoord;
flat in int mat;

// Uniforms //
#ifdef WATER_CAUSTICS
uniform float frameTimeCounter;

uniform ivec2 eyeBrightnessSmooth;
uniform vec3 cameraPosition;

uniform sampler2D noisetex;
#endif

uniform sampler2D tex;

// Global Variables //
#ifdef WATER_CAUSTICS
float eBS = eyeBrightnessSmooth.y / 240.0;
#endif

// Includes //
#ifdef WATER_CAUSTICS
#include "/lib/water/waterCaustics.glsl"
#endif

// Main //
void main() {
    vec4 albedo = texture2D(tex, texCoord) * color;

	float tintedGlass = float(mat >= 10201 && mat <= 10216);
	float skyLightMap = lmCoord.y;

	if (albedo.a < 0.01) discard;

    #ifdef SHADOW_COLOR
	albedo.rgb = mix(vec3(1.0), albedo.rgb, albedo.a);
	albedo.rgb *= albedo.rgb;
	albedo.rgb *= 1.0 - pow32(albedo.a);

	#ifdef WATER_CAUSTICS
	if (mat == 10001 && lmCoord.y >= 0.99){
		float caustics = getWaterCaustics(worldPos + cameraPosition);
        albedo.rgb = mix(vec3(1.0), pow(waterColorSqrt, vec3(0.75)), 0.25 + 0.75 * caustics);
		albedo.rgb *= 0.75 + caustics * WATER_CAUSTICS_STRENGTH;
	}
	#endif

	if (tintedGlass > 0.5 && albedo.a < 0.35) discard;
	#endif
	
	gl_FragData[0] = albedo;
}

#endif

/////////////////////////////////////////////////////////////////////////////////////

#ifdef VSH

// VSH Data //
out vec4 color;
out vec3 worldPos;
out vec2 texCoord, lmCoord;
flat out int mat;

// Uniforms //
#ifdef VX_SUPPORT
uniform int renderStage;

writeonly uniform uimage3D voxel_img;

#if AO_TYPE == 0
layout(r32ui) uniform uimage3D ao_lattice_img;
#endif
#endif

#ifdef GI
uniform int frameCounter;
uniform int blockEntityId;

uniform vec3 previousCameraPosition;

uniform sampler2D tex;

uniform usampler3D voxelShapeSampler, voxelShapeSamplerCopy;

writeonly uniform uimage3D voxel_shape_img, voxel_shape_img_copy;

layout(r32ui) uniform uimage3D voxel_gi_img;
layout(r32ui) uniform uimage3D quad_hash_img;

#ifdef WORLD_SPACE_REFLECTIONS
layout(r32ui) uniform uimage3D voxel_sprite_img;
#endif
#endif

#if defined WAVING_LEAVES || defined WAVING_PLANTS
uniform float frameTimeCounter, rainStrength;

uniform mat4 shadowProjection;
uniform mat4 shadowModelView;
#endif

uniform vec3 cameraPosition;

uniform mat4 shadowProjectionInverse;
uniform mat4 shadowModelViewInverse;

// Attributes //
attribute vec3 at_midBlock;
attribute vec4 mc_midTexCoord;
attribute vec4 mc_Entity;
attribute vec4 at_tangent;

// Includes //
#ifdef VX_SUPPORT
#include "/lib/vx/voxelization.glsl"

#if AO_TYPE == 0
#include "/lib/lighting/aoLattice.glsl"
#endif
#endif

#ifdef GI
#include "/lib/vx/giVoxel.glsl"
#endif

#if defined WAVING_LEAVES || defined WAVING_PLANTS
#include "/lib/pbr/waving.glsl"
#endif

// Main //
void main() {
	texCoord = gl_MultiTexCoord0.xy;

	lmCoord = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
	lmCoord = clamp((lmCoord - 0.03125) * 1.06667, vec2(0.0), vec2(0.9333, 1.0));
	
	mat = int(mc_Entity.x);
	
    // Voxelization //
	#ifdef VX_SUPPORT
    if (gl_VertexID % 4 == 0) updateVoxelMap(int(max(mc_Entity.x - 10000, 0)));

	#if AO_TYPE == 0
	updateAoLattice();
	#endif
	#endif

	#ifdef GI
	updateVoxelGi(mat, lmCoord.y);
	#endif

	//Color & Position //
	color = gl_Color;

	gl_Position = ftransform();

	worldPos = (shadowModelViewInverse * (shadowProjectionInverse * gl_Position)).xyz;

	#if defined WAVING_PLANTS || defined WAVING_LEAVES
	float istopv = gl_MultiTexCoord0.t < mc_midTexCoord.t ? 1.0 : 0.0;
	worldPos = getWavingBlocks(worldPos, istopv, lmCoord.y);
	gl_Position = shadowProjection * (shadowModelView * vec4(worldPos, 1.0));
	#endif

	float dist = sqrt(gl_Position.x * gl_Position.x + gl_Position.y * gl_Position.y);
	float distortFactor = dist * shadowMapBias + (1.0 - shadowMapBias);
	
	gl_Position.xy *= 1.0 / distortFactor;
	gl_Position.z = gl_Position.z * 0.2;

	#ifdef GI
	if (renderStage == MC_RENDER_STAGE_ENTITIES && blockEntityId != 0) gl_Position = vec4(-10.0, -10.0, -10.0, 1.0);
	#endif
}

#endif