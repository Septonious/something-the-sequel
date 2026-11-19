void getReflection(inout vec4 albedo, in vec3 worldPos, in vec3 viewPos, in vec3 nViewPos, in vec3 newNormal, in float fresnel, in float skyLightMap) {
	float border = 0.0;
	float dither = Bayer8(gl_FragCoord.xy);

	#ifdef TAA
	dither = fract(dither + frameTimeCounter * 16.0);
	#endif

	#if WATER_NORMALS > 0
	vec4 reflectPos = rayTrace(depthtex1, viewPos, newNormal, dither, fresnel, border, 6, 6, 0.1, 2.0);
	#else
	vec4 reflectPos = rayTrace(depthtex1, viewPos, newNormal, dither, fresnel, border, 6, 30, 0.1, 2.0);
	#endif

	border = clamp(13.333 * (1.0 - border), 0.0, 1.0);

	vec4 reflection = texture2D(gaux1, reflectPos.xy);
	     reflection.rgb = pow8(reflection.rgb) * 256.0;
         reflection.rgb *= float(reflection.a > 0.0);
		 reflection.a *= border;

	#ifdef WORLD_SPACE_REFLECTIONS
	float reflectDepth = texture2D(depthtex1, reflectPos.xy).r;
	vec3 reflectEnd = ToView(reflectPos.xyz);
	float reflectBehind = ToView(vec3(reflectPos.xy, reflectDepth)).z - reflectEnd.z;

	reflection.a *= float(reflectDepth < 1.0 && reflectBehind > -0.25 && reflectBehind < 0.25 + 0.5 * length(reflectEnd - viewPos));
	#endif

	#ifdef OVERWORLD
	vec3 falloff = albedo.rgb;
	#elif defined NETHER
	vec3 falloff = netherColSqrt.rgb * 0.25;
	#elif defined END
	vec3 falloff = endAmbientColSqrt * 0.25;
	#endif

	if (reflection.a < 1.0 && isEyeInWater == 0) {
		#ifdef WORLD_SPACE_REFLECTIONS
		vec3 surfaceNormal = mat3(gbufferModelViewInverse) * normal;
		vec3 viewReflection = normalize(reflect(nViewPos, newNormal));
		vec3 worldReflection = mat3(gbufferModelViewInverse) * viewReflection;
		vec4 voxelReflection = vec4(0.0, 0.0, 0.0, 1.0);
		float traceDistance = 0.0;

		if (dot(worldReflection, surfaceNormal) > 0.0) {
			giLeafPass = 0.0;
			voxelReflection = voxelReflectionTrace(texture, worldToVoxel(worldPos) + surfaceNormal * 0.05, worldReflection, mat3(gbufferModelViewInverse) * lightVec, length(viewPos), traceDistance);
		}

		if (voxelReflection.a < 0.5) falloff = pow(voxelReflection.rgb, vec3(1.0 / 2.2));
		else
		#endif
		if (skyLightMap > 0.95) {
			#ifdef OVERWORLD
			vec3 viewPosRef = reflect(normalize(viewPos), newNormal);
			vec3 worldPosRef = ToWorld(viewPosRef);
            float atmosphereHardMixFactor = 0.0;
			vec3 reflectedAtmosphere = getAtmosphere(viewPosRef.xyz, worldPosRef.xyz, atmosphereHardMixFactor);

			float waterSkyOcclusion = skyLightMap;
				  waterSkyOcclusion *= waterSkyOcclusion;

			falloff = mix(falloff, reflectedAtmosphere, waterSkyOcclusion);
			#endif
		}

		#ifdef WORLD_SPACE_REFLECTIONS
		if (voxelReflection.a > 0.5 && dot(worldReflection, surfaceNormal) > 0.0) {
			vec3 farHit = farReflectionTrace(depthtex1, viewPos, viewReflection, max(traceDistance, 4.0), dither);
			falloff = mix(falloff, pow8(texture2D(gaux1, farHit.xy).rgb) * 256.0, farHit.z);

			if (farHit.z == 0.0 || texture2D(depthtex1, farHit.xy).r >= 1.0) {
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

	vec3 finalReflection = max(mix(falloff, reflection.rgb, reflection.a), vec3(0.0));

	albedo.rgb = mix(albedo.rgb, finalReflection, fresnel);
}