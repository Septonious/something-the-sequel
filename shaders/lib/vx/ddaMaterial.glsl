#ifdef DDA_BUILD_PALETTE
// The existing Solas material palette is independent of the traversal.
vec3 ddaEmission(uint code) {
    if (code < 2u || code >= 200u) return vec3(0.0);
    vec3 e = max(getBlocklightColor(int(code) + 1), vec3(0.0));
    #ifdef OVERWORLD
    if (code >= 34u && code <= 39u) e *= 1.0 - wetness;
    #endif
    return e;
}
#else
uniform sampler3D ddaPaletteSampler;
vec3 ddaEmission(uint code) {return code<200u ? texelFetch(ddaPaletteSampler,ivec3(int(code),0,0),0).rgb : vec3(0.0);}
#endif
bool ddaPassThrough(uint code) {
    return code <= 1u || (code >= 200u && code <= 215u) ||
           (code >= 34u && code <= 39u) || (code >= 73u && code <= 78u);
}
