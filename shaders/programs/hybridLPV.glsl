#include "/lib/common.glsl"
layout(local_size_x=8,local_size_y=4,local_size_z=4) in;
#if DDA_LPV_STRIDE == 1
#if VOXEL_VOLUME_SIZE == 128
const ivec3 workGroups=ivec3(16,16,32);
#elif VOXEL_VOLUME_SIZE == 192
const ivec3 workGroups=ivec3(24,24,48);
#elif VOXEL_VOLUME_SIZE == 256
const ivec3 workGroups=ivec3(32,32,64);
#elif VOXEL_VOLUME_SIZE == 384
const ivec3 workGroups=ivec3(48,48,96);
#elif VOXEL_VOLUME_SIZE == 512
const ivec3 workGroups=ivec3(64,64,128);
#endif
#else
#if VOXEL_VOLUME_SIZE == 128
const ivec3 workGroups=ivec3(8,8,16);
#elif VOXEL_VOLUME_SIZE == 192
const ivec3 workGroups=ivec3(12,12,24);
#elif VOXEL_VOLUME_SIZE == 256
const ivec3 workGroups=ivec3(16,16,32);
#elif VOXEL_VOLUME_SIZE == 384
const ivec3 workGroups=ivec3(24,24,48);
#elif VOXEL_VOLUME_SIZE == 512
const ivec3 workGroups=ivec3(32,32,64);
#endif
#endif
#if DDA_TRACE_VOLUME < 100 && DDA_DEBUG < 6
uniform int frameCounter;
uniform vec3 cameraPosition,previousCameraPosition;
uniform usampler3D voxelSampler,ddaMaskSampler;
#ifndef DDA_LPV_GROUP_SKIP
#define DDA_LPV_GROUP_SKIP 1
#endif
#if DDA_LPV_SPARSE == 1 && DDA_LPV_STRIDE == 2 && DDA_LPV_GROUP_SKIP == 1
uniform usampler3D ddaCoarseSampler;
#endif
uniform sampler3D hybridLpvSampler,hybridLpvSamplerCopy;
layout(rgba16f) writeonly uniform image3D hybridLpv_img,hybridLpv_img_copy;
#include "/lib/vx/ddaMaterial.glsl"
const ivec3 lpvSize=ivec3(VOXEL_VOLUME_SIZE,VOXEL_VOLUME_SIZE/2,VOXEL_VOLUME_SIZE)/DDA_LPV_STRIDE;
const ivec3 lpvOffsets[6]=ivec3[](ivec3(1,0,0),ivec3(-1,0,0),ivec3(0,1,0),ivec3(0,-1,0),ivec3(0,0,1),ivec3(0,0,-1));
const vec3 lpvTint[16]=vec3[](vec3(1,.12,.12),vec3(1,.46,.12),vec3(1,.92,.12),vec3(.55,.28,.12),vec3(.2,.7,.12),vec3(.52,1,.12),vec3(.13,.24,1),vec3(.35,.72,1),vec3(.15,.72,.8),vec3(.55,.17,.83),vec3(.88,.19,.75),vec3(1,.51,.71),vec3(.08),vec3(.95),vec3(.32),vec3(.65));
bool lpvValid(ivec3 p){return all(greaterThanEqual(p,ivec3(0)))&&all(lessThan(p,lpvSize));}
vec3 lpvRead(sampler3D s,ivec3 p){return lpvValid(p)?texelFetch(s,p,0).rgb:vec3(0);}
#if DDA_LPV_SPARSE == 1
// Metadata occupies alpha only at each 4^3 cell origin. RGB is unchanged.
// Two independent 4^3 groups fit in the existing 8x4x4 workgroup.
shared uint lpvActive[2],lpvOutput[2];
#if DDA_LPV_STRIDE == 2 && DDA_LPV_GROUP_SKIP == 1
shared uint lpvNeedsWork[2];
#endif
bool lpvGroupActive(sampler3D s,ivec3 p){return lpvValid(p)&&texelFetch(s,p,0).a>0.0;}
bool lpvGroupNeighborhood(sampler3D s,ivec3 p){
    if(lpvGroupActive(s,p))return true;
    for(int i=0;i<6;++i)if(lpvGroupActive(s,p+lpvOffsets[i]*4))return true;
    return false;
}
#endif
vec3 lpvPropagate(sampler3D s,ivec3 p){vec3 sum=lpvRead(s,p);for(int i=0;i<6;++i)sum+=lpvRead(s,p+lpvOffsets[i]);return sum/7.01;}
#endif
void main(){
#if DDA_TRACE_VOLUME < 100 && DDA_DEBUG < 6
    ivec3 p=ivec3(gl_GlobalInvocationID);
    ivec3 shift=ivec3(floor((cameraPosition+4.0)/8.0)-floor((previousCameraPosition+4.0)/8.0))*(8/DDA_LPV_STRIDE);
    bool historyValid=frameCounter>0 && all(lessThan(abs(shift),lpvSize));
    #if DDA_LPV_SPARSE == 1
    uint group=gl_LocalInvocationID.x>>2u;
    bool leader=all(equal(p&3,ivec3(0)));
    if(leader){
        lpvOutput[group]=0u;
        lpvActive[group]=0u;
        if(historyValid){
            ivec3 prevGroup=p+shift;
            lpvActive[group]=uint((frameCounter&1)==0?lpvGroupNeighborhood(hybridLpvSampler,prevGroup):lpvGroupNeighborhood(hybridLpvSamplerCopy,prevGroup));
        }
        #if DDA_LPV_STRIDE == 2 && DDA_LPV_GROUP_SKIP == 1
        // A 4^3 group of two-block LPV cells covers exactly one 8^3
        // voxel summary. If both previous light and current emission are
        // absent, all RGB output and activity metadata are known to be zero.
        lpvNeedsWork[group]=lpvActive[group]|(texelFetch(ddaCoarseSampler,p>>2,0).r&255u);
        #endif
    }
    barrier();
    #if DDA_LPV_STRIDE == 2 && DDA_LPV_GROUP_SKIP == 1
    // Uniform across the entire workgroup, so no lane misses a barrier.
    if((lpvNeedsWork[0]|lpvNeedsWork[1])==0u){
        if((frameCounter&1)==0)imageStore(hybridLpv_img_copy,p,vec4(0.0));
        else imageStore(hybridLpv_img,p,vec4(0.0));
        return;
    }
    #endif
    historyValid=historyValid && lpvActive[group]!=0u;
    #endif
    vec3 light=vec3(0),emission=vec3(0),tint=vec3(1.0);
    bool opaque=false;
    #if DDA_LPV_STRIDE == 2
    // Eight child cells occupy one byte in the existing brick masks. Empty
    // coarse cells need no individual material reads. Mixed opaque cells
    // conservatively stop diffusion; emitters still inject averaged energy.
    ivec3 child=p*2;
    ivec3 o=p&1;int oct=o.x+2*o.y+4*o.z;
    uvec4 masks=texelFetch(ddaMaskSampler,p>>1,0);
    int shiftBits=(oct&3)*8;
    uint em=(masks[oct>>2]>>shiftBits)&255u;
    uint oc=(masks[2+(oct>>2)]>>shiftBits)&255u;
    // Emission overrides occupancy and tint in this coarse cell. No need to
    // classify opaque children in that case. Otherwise a single opaque child
    // makes the cell black, so stop as soon as one is found.
    uint mask=em;
    while(mask!=0u){
        int bit=findLSB(mask);mask&=mask-1u;
        ivec3 c=child+ivec3(bit&1,(bit>>1)&1,bit>>2);
        emission+=pow(ddaEmission(texelFetch(voxelSampler,c,0).r),vec3(1.2))*0.125;
    }
    if(em==0u && historyValid){
        mask=oc;
        while(mask!=0u){
            int bit=findLSB(mask);mask&=mask-1u;
            ivec3 c=child+ivec3(bit&1,(bit>>1)&1,bit>>2);
            uint code=texelFetch(voxelSampler,c,0).r;
            if(code>=200u&&code<=215u)tint*=pow(mix(vec3(1),lpvTint[code-200u],DDA_GLASS_STRENGTH),vec3(0.3));
            else {opaque=true;break;}
        }
    }
    #else
    uint code=texelFetch(voxelSampler,p,0).r;
    emission=pow(ddaEmission(code),vec3(1.2));
    if(historyValid){
        opaque=!(ddaPassThrough(code)||code==256u);
        if(code>=200u&&code<=215u)tint=pow(mix(vec3(1),lpvTint[code-200u],DDA_GLASS_STRENGTH),vec3(1.2));
    }
    #endif
    if(maxOf(emission)>0.0)light=emission;
    else if(!opaque){
        // New origin minus old origin, in whole world-aligned brick steps.
        if(historyValid) {
            ivec3 q=p+shift;
            if((frameCounter&1)==0)light=lpvPropagate(hybridLpvSampler,q);
            else light=lpvPropagate(hybridLpvSamplerCopy,q);
        }
        light*=tint;
    }
    float activity=0.0;
    #if DDA_LPV_SPARSE == 1
    if(maxOf(light)>0.0)atomicOr(lpvOutput[group],1u);
    barrier();
    if(leader)activity=float(lpvOutput[group]);
    #endif
    if((frameCounter&1)==0)imageStore(hybridLpv_img_copy,p,vec4(light,activity));
    else imageStore(hybridLpv_img,p,vec4(light,activity));
#endif
}
