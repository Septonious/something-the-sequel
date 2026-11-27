// Analytic model coordinates are in sixteenths of a block. These are optical
// models, not collision boxes (fences do not extend 1.5 blocks upwards).
// The coarse LOD is an enclosing AABB: a miss proves every detailed box misses.
// Refinement on ambiguous hits preserves hard visibility at any camera distance.
bool ddaBoxInterval(vec3 o, vec3 inv, bvec3 parallel, float len, vec3 lo, vec3 hi, out float enter, out float leave) {
    lo *= 0.0625; hi *= 0.0625;
    if (any(bvec3(parallel.x && (o.x < lo.x || o.x > hi.x),
                  parallel.y && (o.y < lo.y || o.y > hi.y),
                  parallel.z && (o.z < lo.z || o.z > hi.z)))) return false;
    vec3 a = (lo-o)*inv, b = (hi-o)*inv;
    vec3 nearT = mix(min(a,b),vec3(-1e20),parallel);
    vec3 farT = mix(max(a,b),vec3(1e20),parallel);
    enter = max(0.0,max(nearT.x,max(nearT.y,nearT.z)));
    leave = min(len,min(farT.x,min(farT.y,farT.z)));
    return leave >= enter - 0.000002 && leave > 0.000001;
}
bool ddaBox(vec3 o, vec3 inv, bvec3 parallel, float len, vec3 lo, vec3 hi) {
    float a,b; return ddaBoxInterval(o,inv,parallel,len,lo,hi,a,b);
}
// Grates are alpha-cutout cubes, approximated by a periodic face lattice.
// Test the six face planes directly, rather than filling the interior.
bool ddaGrateHit(vec3 o,vec3 inv,bvec3 parallel,float len) {
    for(int axis=0;axis<3;++axis) {
        if(parallel[axis])continue;
        int u=(axis+1)%3,v=(axis+2)%3;
        for(int side=0;side<2;++side) {
            float t=(float(side)-o[axis])*inv[axis];
            if(t<=0.000001||t>len)continue;
            // inv is finite (1 for a parallel axis), but parallel displacement is zero.
            float a=o[u]+(parallel[u]?0.0:t/inv[u]);
            float b=o[v]+(parallel[v]?0.0:t/inv[v]);
            if(a<0.0||a>1.0||b<0.0||b>1.0)continue;
            vec2 q=fract(vec2(a,b)*4.0);
            if(any(lessThanEqual(min(q,1.0-q),vec2(0.25))))return true;
        }
    }
    return false;
}
uniform sampler3D ddaShapeSampler;
bool ddaShapeHit(uint s,vec3 o,vec3 inv,bvec3 parallel,float len,bool distant) {
    if(s==288u)return ddaGrateHit(o,inv,parallel,len);
    if(s>=289u)return false;
    vec4 bounds=texelFetch(ddaShapeSampler,ivec3(0,int(s),0),0);
    int count=int(bounds.w);
    if(count==0)return false;
    // Exact broad phase, used for distant multi-box models.
    if(count>1 && distant && !ddaBox(o,inv,parallel,len,bounds.xyz,texelFetch(ddaShapeSampler,ivec3(1,int(s),0),0).xyz))return false;
    for(int i=0;i<count;++i){
        vec3 lo=texelFetch(ddaShapeSampler,ivec3(2+2*i,int(s),0),0).xyz;
        vec3 hi=texelFetch(ddaShapeSampler,ivec3(3+2*i,int(s),0),0).xyz;
        if(ddaBox(o,inv,parallel,len,lo,hi))return true;
    }
    return false;
}
