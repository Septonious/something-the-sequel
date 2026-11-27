#if DDA_TRACE_VOLUME < 100
uniform sampler3D hybridLpvSampler, hybridLpvSamplerCopy;
vec3 hybridLPV(vec3 p, vec3 n) {
    vec3 uv = clamp((p+n)/voxelVolumeSize,0.0,1.0);
    vec3 light = (frameCounter & 1)==0 ? texture3D(hybridLpvSamplerCopy,uv).rgb : texture3D(hybridLpvSampler,uv).rgb;
    return pow(max(light,vec3(0.0)),vec3(1.0/1.2));
}
float hybridLPVWeight(vec3 p) {
    float edge = maxOf(abs(p-voxelVolumeSize*0.5)/(voxelVolumeSize*0.5));
    return 0.95 * clamp(1.0-edge*edge,0.0,1.0);
}
#endif
