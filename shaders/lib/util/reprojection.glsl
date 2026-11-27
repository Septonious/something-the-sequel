vec2 Reprojection(vec3 pos) {
	// World geometry uses the same jitter sequence as its vertex programs.
	// Sky and the near hand depth range are not jittered.
	bool worldSample=pos.z>0.56 && pos.z<1.0;
	if(worldSample)pos.xy-=TAAJitterUV(frameCounter);
	pos = pos * 2.0 - 1.0;

	vec4 viewPosPrev = gbufferProjectionInverse * vec4(pos, 1.0);
		 viewPosPrev /= viewPosPrev.w;
		 viewPosPrev = gbufferModelViewInverse * viewPosPrev;

	vec3 cameraOffset = cameraPosition - previousCameraPosition;
		 // worldSample is computed from unremapped depth; using pos.z here
		 // would apply a different threshold after NDC conversion.
		 cameraOffset *= float(worldSample);

	vec4 previousPosition = viewPosPrev + vec4(cameraOffset, 0.0);
		 previousPosition = gbufferPreviousModelView * previousPosition;
		 previousPosition = gbufferPreviousProjection * previousPosition;

	vec2 uv=previousPosition.xy / previousPosition.w * 0.5 + 0.5;
	if(worldSample)uv+=TAAJitterUV(frameCounter-1);
	return uv;
}