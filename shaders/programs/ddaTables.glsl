#include "/lib/common.glsl"
layout(local_size_x=128) in;
const ivec3 workGroups=ivec3(1,1,1);
uniform float frameTimeCounter;
#ifdef OVERWORLD
uniform float wetness;
#endif
#include "/lib/vx/blocklightColor.glsl"
#define DDA_BUILD_PALETTE
#include "/lib/vx/ddaMaterial.glsl"
#include "/lib/vx/ddaShapeBuild.glsl"
layout(rgba32f) writeonly uniform image3D ddaShape_img,ddaPalette_img;
void writeModel(uint s){
    vec3 boundsLo=vec3(16),boundsHi=vec3(0);int count=0;
    for(int i=0;i<ddaPrimitiveCount(s);++i){
        vec3 lo,hi;if(!ddaPrimitive(s,i,lo,hi))continue;
        boundsLo=min(boundsLo,lo);boundsHi=max(boundsHi,hi);
        imageStore(ddaShape_img,ivec3(2+2*count,int(s),0),vec4(lo,0));
        imageStore(ddaShape_img,ivec3(3+2*count,int(s),0),vec4(hi,0));++count;
    }
    imageStore(ddaShape_img,ivec3(0,int(s),0),vec4(boundsLo,float(count)));
    imageStore(ddaShape_img,ivec3(1,int(s),0),vec4(boundsHi,0));
}
void main(){
    #if DDA_DEBUG >= 6
    return;
    #endif
    uint lane=gl_LocalInvocationIndex;
    for(uint s=lane;s<289u;s+=128u)writeModel(s);
    for(uint c=lane;c<200u;c+=128u)imageStore(ddaPalette_img,ivec3(int(c),0,0),vec4(ddaEmission(c),0));
}
