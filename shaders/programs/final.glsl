#include "/lib/common.glsl"

#ifdef FSH

// VSH Data //
in vec2 texCoord;

// Uniforms //
uniform sampler2D colortex1;

uniform float viewWidth, viewHeight;

// Pipeline Options //
const bool shadowHardwareFiltering0 = true;
const int noiseTextureResolution = 512;
const float shadowDistanceRenderMul = 1.0;
const float wetnessHalflife = 128.0;

#ifdef GI
/*
const int colortex0Format = RGB16F;
const int colortex11Format = RGBA16;
const int colortex13Format = RGBA8;
const int colortex14Format = RGBA16F;
const int colortex15Format = RGBA16F;
*/
#else
/*
const int colortex0Format = R11F_G11F_B10F; //Main HDR scene
const int colortex11Format = R8;
*/
#endif

/*
const int colortex1Format = R11F_G11F_B10F; //Tonemapped / final scene
const int colortex2Format = RGBA16F; //HDR TAA history
const int colortex3Format = R11F_G11F_B10F; //HDR TAA-resolved scene
const int colortex4Format = R11F_G11F_B10F; //Reflections / auxiliary HDR
const int colortex5Format = RGBA16F;
const int colortex6Format = RG16F;
const int colortex7Format = RGBA16;
const int colortex9Format = R11F_G11F_B10F;
const int colortex10Format = R11F_G11F_B10F;
*/

#ifdef WORLD_SPACE_REFLECTIONS
/*
const int colortex12Format = RGBA32F;
*/
#else
/*
const int colortex12Format = RG16F;
*/
#endif

// Includes //
#if MC_VERSION >= 11200
#include "/lib/post/sharpenFilter.glsl"
#endif

// Main //
void main() {
    vec3 color = texture2D(colortex1, texCoord).rgb;

	#if MC_VERSION >= 11200
	sharpenFilter(color, texCoord);
	#endif

    gl_FragColor.rgb = color;
}

#endif


//**//**//**//**//**//**//**//**//**//**//**//**//**//**//


#ifdef VSH

// VSH Data //
out vec2 texCoord;

// Main //
void main() {
    texCoord = gl_MultiTexCoord0.xy;
	
	gl_Position = ftransform();
}

#endif