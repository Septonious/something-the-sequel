#include "/lib/common.glsl"
// Rebuild the direct-light index from this frame's material capture.
// One workgroup covers 8^3 cells; eight 4^3 bricks have four 32-bit masks each.
layout(local_size_x = 64) in;
#if VOXEL_VOLUME_SIZE == 128
const ivec3 workGroups = ivec3(16, 8, 16);
#elif VOXEL_VOLUME_SIZE == 192
const ivec3 workGroups = ivec3(24, 12, 24);
#elif VOXEL_VOLUME_SIZE == 256
const ivec3 workGroups = ivec3(32, 16, 32);
#elif VOXEL_VOLUME_SIZE == 384
const ivec3 workGroups = ivec3(48, 24, 48);
#elif VOXEL_VOLUME_SIZE == 512
const ivec3 workGroups = ivec3(64, 32, 64);
#endif
uniform float frameTimeCounter;
#ifdef OVERWORLD
uniform float wetness;
#endif
uniform usampler3D voxelSampler;
#if DDA_CAPTURE_INDEX == 1
uniform usampler3D ddaCaptureIndexSampler;
#endif
layout(rgba32ui) writeonly uniform uimage3D ddaMask_img;
layout(r16ui) writeonly uniform uimage3D ddaCoarse_img;
#include "/lib/vx/ddaMaterial.glsl"
shared uint laneMasks[64];
#ifdef DDA_GROUP_LIGHTS
layout(r32ui) writeonly uniform uimage3D ddaGroup_img;
shared uint laneCodes[64];
ivec3 groupBits(int b){return ivec3(b&1,(b>>1)&1,b>>2);}
uint groupPack(ivec3 v){return uint(v.x|(v.y<<2)|(v.z<<4));}
#endif
void main() {
    #if DDA_DEBUG >= 6
    return;
    #endif
    uint lane = gl_LocalInvocationIndex;
    uint brick=lane>>3u, oct=lane&7u;
    #if DDA_CAPTURE_INDEX == 1
    uint present=texelFetch(ddaCaptureIndexSampler,ivec3(gl_WorkGroupID),0).r;
    if(present==0u){
        if(lane<8u){
            ivec3 b=ivec3(int(lane&1u),int((lane>>1u)&1u),int(lane>>2u));
            imageStore(ddaMask_img,ivec3(gl_WorkGroupID)*2+b,uvec4(0u));
            #ifdef DDA_GROUP_LIGHTS
            imageStore(ddaGroup_img,ivec3(gl_WorkGroupID)*2+b,uvec4(0u));
            #endif
        }
        if(lane==0u)imageStore(ddaCoarse_img,ivec3(gl_WorkGroupID),uvec4(0u));
        return;
    }
    bool activeBrick=(present&(1u<<brick))!=0u;
    #else
    bool activeBrick=true;
    #endif
    ivec3 offset=ivec3(int(brick&1u),int((brick>>1u)&1u),int(brick>>2u));
    ivec3 base=ivec3(gl_WorkGroupID)*8+offset*4;
    ivec3 child=base+ivec3(int(oct&1u),int((oct>>1u)&1u),int(oct>>2u))*2;
    uint em=0u,oc=0u;
    #ifdef DDA_GROUP_LIGHTS
    uint loCode=255u,hiCode=0u;
    #endif
    if(activeBrick)for(uint j=0u;j<8u;++j){
        ivec3 p=child+ivec3(int(j&1u),int((j>>1u)&1u),int(j>>2u));
        uint code=texelFetch(voxelSampler,p,0).r;
        if(code<=1u)continue;
        // Full solids, partial geometry and stained glass need no palette lookup.
        // Code 256 is the only pass-through model in this range.
        if(code>=200u){if(code!=256u)oc|=1u<<j;continue;}
        bool emits=maxOf(ddaEmission(code))>0.0;
        if(emits){em|=1u<<j;
            #ifdef DDA_GROUP_LIGHTS
            loCode=min(loCode,code);hiCode=max(hiCode,code);
            #endif
        }
        else if(!ddaPassThrough(code))oc|=1u<<j;
    }
    laneMasks[lane]=em|(oc<<8u);
    #ifdef DDA_GROUP_LIGHTS
    laneCodes[lane]=loCode|(hiCode<<8u);
    #endif
    barrier();
    // Eight independent brick leaders reduce their own words directly.
    // The coarse summary reads the same immutable lane data, removing
    // one workgroup-wide barrier and a second shared-memory round trip.
    if (lane < 8u) {
        ivec3 offset = ivec3(int(lane & 1u), int((lane >> 1u) & 1u), int(lane >> 2u));
        uvec4 brickWords=uvec4(0u);
        #ifdef DDA_GROUP_LIGHTS
        uint loCode=255u,hiCode=0u;
        #endif
        for(uint j=0u;j<8u;++j){
            uint v=laneMasks[lane*8u+j];uint word=j>>2u,shift=(j&3u)*8u;
            brickWords[word]|=(v&255u)<<shift;brickWords[word+2u]|=(v>>8u)<<shift;
            #ifdef DDA_GROUP_LIGHTS
            uint c=laneCodes[lane*8u+j];loCode=min(loCode,c&255u);hiCode=max(hiCode,c>>8u);
            #endif
        }
        imageStore(ddaMask_img, ivec3(gl_WorkGroupID)*2+offset,brickWords);
        #ifdef DDA_GROUP_LIGHTS
        uvec2 bits=brickWords.rg;
        int n=bitCount(bits.x)+bitCount(bits.y);uint groupMeta=0u;
        if(n>=4 && loCode==hiCode){
            // Project the 64-bit occupancy onto each axis in constant time.
            // Each bit of the four-bit projection denotes one coordinate plane.
            uint xy=bits.x|bits.y;
            uint px=uint((xy&0x00550055u)!=0u)|uint((xy&0x00aa00aau)!=0u)<<1u|uint((xy&0x55005500u)!=0u)<<2u|uint((xy&0xaa00aa00u)!=0u)<<3u;
            uint py=uint((xy&0x00003333u)!=0u)|uint((xy&0x0000ccccu)!=0u)<<1u|uint((xy&0x33330000u)!=0u)<<2u|uint((xy&0xcccc0000u)!=0u)<<3u;
            uint pz=uint((bits.x&0x0f0f0f0fu)!=0u)|uint((bits.x&0xf0f0f0f0u)!=0u)<<1u|uint((bits.y&0x0f0f0f0fu)!=0u)<<2u|uint((bits.y&0xf0f0f0f0u)!=0u)<<3u;
            ivec3 lo=ivec3(findLSB(px),findLSB(py),findLSB(pz)),hi=ivec3(findMSB(px),findMSB(py),findMSB(pz));
            ivec3 extent=hi-lo+1;
            // A full rectangular cuboid is connected and contains no holes.
            if(extent.x*extent.y*extent.z==n)groupMeta=groupPack(lo)|(groupPack(hi)<<6u)|(uint(n)<<12u);
        }
        imageStore(ddaGroup_img,ivec3(gl_WorkGroupID)*2+offset,uvec4(groupMeta));
        #endif
    }
    if (lane == 0u) {
        uint summary = 0u;
        uint blockers = 0u;
        for(uint i=0u;i<8u;++i){uint combined=0u;for(uint j=0u;j<8u;++j)combined|=laneMasks[i*8u+j];if((combined&255u)!=0u)summary|=1u<<i;if((combined>>8u)!=0u)blockers|=1u<<i;}
        imageStore(ddaCoarse_img, ivec3(gl_WorkGroupID), uvec4(summary | (blockers << 8u)));
    }
}
