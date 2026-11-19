#include "/lib/common.glsl"

#ifdef FSH

uniform float viewWidth, viewHeight;

uniform vec3 cameraPosition, previousCameraPosition;

uniform sampler2D colortex4, colortex12;
uniform sampler2D depthtex0;

uniform mat4 gbufferProjection, gbufferProjectionInverse;
uniform mat4 gbufferModelView, gbufferModelViewInverse;

const bool colortex12Clear = false;

#include "/lib/util/ToView.glsl"
#include "/lib/util/ToWorld.glsl"
#include "/lib/util/ToScreen.glsl"
#include "/lib/pbr/farProbe.glsl"

void main() {
	ivec2 texel = ivec2(gl_FragCoord.xy);
	vec2 angle = (vec2(texel) + 0.5) / vec2(farProbeSize) * vec2(6.2831853, 3.1415927);
	vec3 direction = vec3(cos(angle.x) * sin(angle.y), cos(angle.y), sin(angle.x) * sin(angle.y));
	vec3 viewDirection = mat3(gbufferModelView) * direction;
	vec2 screen = ToScreen(viewDirection).xy;
	ivec2 pixel = ivec2(screen * vec2(viewWidth, viewHeight));
	float depth = viewDirection.z < 0.0 && clamp(screen, 0.0, 1.0) == screen ? texelFetch(depthtex0, pixel, 0).r : 0.0;
	vec4 probe = vec4(0.0);

	if (depth > 0.56) {
		if (depth < 1.0) {
			vec3 colour = min(floor(texelFetch(colortex4, pixel, 0).rgb * 255.0 + 0.5), 255.0);

			probe = vec4(colour.r * 65536.0 + colour.g * 256.0 + colour.b + 1.0, ToWorld(ToView(vec3((vec2(pixel) + 0.5) / vec2(viewWidth, viewHeight), depth))) + cameraPosition);
		}
	} else {
		float nearest = 1.0e30;

		for (int i = 0; i < 9; i++) {
			ivec2 source = ivec2((texel.x + i % 3 - 1 + farProbeSize.x) % farProbeSize.x, texel.y + i / 3 - 1);

			if (source.y < 0 || source.y >= farProbeSize.y) continue;

			vec4 entry = texelFetch(colortex12, source, 0);
			vec3 offset = entry.yzw - cameraPosition;
			float entryDistance = length(offset);

			if (entry.x > 0.5 && entryDistance < nearest && farProbeTexel(offset / entryDistance) == texel) {
				nearest = entryDistance;
				probe = entry;
			}
		}

		if (probe.x < 0.5 && length(cameraPosition - previousCameraPosition) < 4.0) {
			probe = texelFetch(colortex12, texel, 0);

			for (int i = 0; i < 2 && probe.x > 0.5; i++) {
				probe = texelFetch(colortex12, farProbeTexel(normalize(direction * length(probe.yzw - cameraPosition) + (cameraPosition - previousCameraPosition))), 0);
			}
		}
	}

	/* RENDERTARGETS: 12 */
	gl_FragData[0] = probe;
}

#endif

#ifdef VSH

void main() {
	gl_Position = ftransform();
}

#endif
