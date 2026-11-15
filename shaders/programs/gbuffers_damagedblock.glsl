#define GBUFFERS_DAMAGEDBLOCK

//Settings//
#include "/lib/common.glsl"

#ifdef FSH

// VSH Data //
in vec4 color;
in vec2 texCoord;

// Uniforms //
uniform sampler2D texture;

// Main //
void main() {
	vec4 albedo = texture2D(texture, texCoord) * color;

	/* DRAWBUFFERS:0 */
	gl_FragData[0] = albedo;

	#ifdef GI
	/* RENDERTARGETS: 0,13 */
	gl_FragData[1] = albedo;
	#endif
}

#endif

//**//**//**//**//**//**//**//**//**//**//**//**//**//**//

#ifdef VSH

// VSH Data //
out vec4 color;
out vec2 texCoord;

// Main //
void main() {
	texCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;

	color = gl_Color;

	gl_Position = ftransform();
}

#endif