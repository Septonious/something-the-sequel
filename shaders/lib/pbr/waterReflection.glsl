vec3 getUnderwaterReflectionFog(vec3 colour, vec3 direction, float pathLength) {
	vec3 colorMult = vec3(1.0);
	vec4 waterFog = getWaterFog(colorMult, direction * pathLength);
	vec3 fogged = mix(sqrt(pow(colour, vec3(2.2)) * colorMult), sqrt(waterFog.rgb), waterFog.a);

	return pow(fogged * fogged, vec3(1.0 / 2.2));
}

vec3 getSnellWindow(vec3 worldPos, vec3 viewPos, vec3 nViewPos, vec3 newNormal, float skyLightMap) {
	vec3 viewRefraction = refract(nViewPos, newNormal, 1.33);
	vec3 worldRefraction = mat3(gbufferModelViewInverse) * viewRefraction;
	vec3 transmitted = getSkyCapture(worldRefraction) * skyLightMap * skyLightMap;

	#ifdef WORLD_SPACE_REFLECTIONS
	float dither = Bayer8(gl_FragCoord.xy);

	#ifdef TAA
	dither = fract(dither + frameTimeCounter * 16.0);
	#endif

	float traceDistance = 0.0;
	vec4 voxelHit = voxelReflectionTrace(texture, worldToVoxel(worldPos) - mat3(gbufferModelViewInverse) * normal * 0.05, worldRefraction, mat3(gbufferModelViewInverse) * lightVec, length(viewPos), traceDistance);

	if (voxelHit.a < 0.5) return pow(voxelHit.rgb, vec3(1.0 / 2.2));

	bool farGeometry;
	vec3 farHit = farReflectionTrace(depthtex1, viewPos, viewRefraction, max(traceDistance, 4.0), dither, farGeometry);

	if (farGeometry) transmitted = mix(transmitted, pow8(texture2D(gaux1, farHit.xy).rgb) * 256.0, farHit.z);

	if (farHit.z == 0.0 || !farGeometry) {
		vec4 probeHit = farProbeTrace(worldPos, worldRefraction, max(traceDistance, 4.0), dither);
		transmitted = mix(transmitted, probeHit.rgb, probeHit.a);
	}
	#endif

	return transmitted;
}

void getReflection(inout vec4 albedo, in vec3 worldPos, in vec3 viewPos, in vec3 nViewPos, in vec3 newNormal, in float fresnel, in float skyLightMap) {
	float border = 0.0;
	float dither = Bayer8(gl_FragCoord.xy);

	#ifdef TAA
	dither = fract(dither + frameTimeCounter * 16.0);
	#endif

	vec4 reflectPos = rayTrace(depthtex1, viewPos, newNormal, dither, fresnel, border, 6, 30, 0.1, 2.0);

	border = clamp(13.333 * (1.0 - border), 0.0, 1.0);

	vec4 reflection = texture2D(gaux1, reflectPos.xy);
	     reflection.rgb = pow8(reflection.rgb) * 256.0;
         reflection.rgb *= float(reflection.a > 0.0);
		 reflection.a *= border;

	#ifdef WORLD_SPACE_REFLECTIONS
	if (reflection.a > 0.0) {
		float reflectDepth = texture2D(depthtex1, reflectPos.xy).r;
		vec3 reflectEnd = ToView(reflectPos.xyz);
		float reflectBehind = ToView(vec3(reflectPos.xy, reflectDepth)).z - reflectEnd.z;

		reflection.a *= float(reflectDepth < 1.0 && reflectBehind > -0.25 && reflectBehind < 0.25 + 0.5 * length(reflectEnd - viewPos));
	}
	#endif

	#ifdef OVERWORLD
	vec3 falloff = albedo.rgb;
	#elif defined NETHER
	vec3 falloff = netherColSqrt.rgb * 0.25;
	#elif defined END
	vec3 falloff = endAmbientColSqrt * 0.25;
	#endif

	float falloffDistance = far;

	#ifdef WORLD_SPACE_REFLECTIONS
	if (reflection.a < 1.0 && isEyeInWater < 2) {
	#else
	if (reflection.a < 1.0 && isEyeInWater == 0) {
	#endif
		#ifdef WORLD_SPACE_REFLECTIONS
		vec3 surfaceNormal = mat3(gbufferModelViewInverse) * normal;
		vec3 viewReflection = normalize(reflect(nViewPos, newNormal));
		vec3 worldReflection = mat3(gbufferModelViewInverse) * viewReflection;
		vec4 voxelReflection = vec4(0.0, 0.0, 0.0, 1.0);
		float traceDistance = 0.0;

		if (dot(worldReflection, surfaceNormal) > 0.0) {
			voxelReflection = voxelReflectionTrace(texture, worldToVoxel(worldPos) + surfaceNormal * 0.05, worldReflection, mat3(gbufferModelViewInverse) * lightVec, length(viewPos), traceDistance);
		}

		if (voxelReflection.a < 0.5) {
			falloff = pow(voxelReflection.rgb, vec3(1.0 / 2.2));
			falloffDistance = traceDistance;
		} else
		#endif
		if (skyLightMap > 0.95 && isEyeInWater == 0) {
			#ifdef OVERWORLD
			vec3 viewPosRef = reflect(normalize(viewPos), newNormal);
			vec3 worldPosRef = mat3(gbufferModelViewInverse) * viewPosRef;
            float atmosphereHardMixFactor = 0.0;
			vec3 reflectedAtmosphere = worldPosRef.y > 0.0 ? getSkyCapture(worldPosRef) : getAtmosphere(viewPosRef.xyz, worldPosRef.xyz, atmosphereHardMixFactor);

			float waterSkyOcclusion = skyLightMap;
				  waterSkyOcclusion *= waterSkyOcclusion;

			falloff = mix(falloff, reflectedAtmosphere, waterSkyOcclusion);
			#endif
		}

		#ifdef WORLD_SPACE_REFLECTIONS
		if (voxelReflection.a > 0.5 && dot(worldReflection, surfaceNormal) > 0.0 && isEyeInWater == 0) {
			bool farGeometry;
			vec3 farHit = farReflectionTrace(depthtex1, viewPos, viewReflection, max(traceDistance, 4.0), dither, farGeometry);

			if (farHit.z > 0.0) falloff = mix(falloff, pow8(texture2D(gaux1, farHit.xy).rgb) * 256.0, farHit.z);

			if (farHit.z == 0.0 || !farGeometry) {
				vec4 probeHit = farProbeTrace(worldPos, worldReflection, max(traceDistance, 4.0), dither);
				falloff = mix(falloff, probeHit.rgb, probeHit.a);
			}
		}
		#endif

		#if MC_VERSION >= 11900
		falloff *= 1.0 - darknessFactor;
		#endif

		falloff *= 1.0 - blindFactor;
	}

	if (isEyeInWater == 1) {
		vec3 underwaterReflection = reflect(nViewPos, newNormal);

		falloff = getUnderwaterReflectionFog(falloff, underwaterReflection, falloffDistance);
		reflection.rgb = getUnderwaterReflectionFog(reflection.rgb, underwaterReflection, length(ToNDC(reflectPos.xyz) - viewPos));
	}

	vec3 finalReflection = max(mix(falloff, reflection.rgb, reflection.a), vec3(0.0));

	albedo.rgb = mix(albedo.rgb, finalReflection, fresnel);
}