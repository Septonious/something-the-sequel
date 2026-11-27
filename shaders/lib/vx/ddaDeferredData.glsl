// 11-bit signed octahedral coordinates and one two-sided bit, exactly stored in float32.
// Axis-aligned terrain normals remain exact. Zero is reserved for no receiver.
vec2 ddaSignNotZero(vec2 v){return mix(vec2(-1.0),vec2(1.0),greaterThanEqual(v,vec2(0.0)));}
float ddaEncodeNormal(vec3 n,bool twoSided){
    vec2 o=n.xy/(abs(n.x)+abs(n.y)+abs(n.z));
    if(n.z<0.0)o=(1.0-abs(o.yx))*ddaSignNotZero(o);
    uvec2 q=uvec2(ivec2(round(o*1023.0))+1023);
    return float(1u+q.x+(q.y<<11u)+(uint(twoSided)<<22u));
}
vec3 ddaDecodeNormal(float encoded,out float twoSided){
    uint v=uint(encoded)-1u;
    twoSided=float((v>>22u)&1u);
    vec2 o=(vec2(v&2047u,(v>>11u)&2047u)-1023.0)/1023.0;
    vec3 n=vec3(o,1.0-abs(o.x)-abs(o.y));
    if(n.z<0.0)n.xy=(1.0-abs(n.yx))*ddaSignNotZero(n.xy);
    return normalize(n);
}
