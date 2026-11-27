#include "/lib/common.glsl"
layout(local_size_x=32) in;
#if DDA_REGIONAL_LIGHTS == 1 && DDA_CACHE_INTERVAL == 8
// Nine contiguous horizontal columns (full height). Dispatch only the
// largest column footprint; each workgroup handles center + active outer.
// Literal directives are required by Iris, not arithmetic expressions.
#if VOXEL_VOLUME_SIZE == 128
const ivec3 workGroups = ivec3(6, 8, 6);
#elif VOXEL_VOLUME_SIZE == 192
const ivec3 workGroups = ivec3(8, 12, 8);
#elif VOXEL_VOLUME_SIZE == 256
const ivec3 workGroups = ivec3(11, 16, 11);
#elif VOXEL_VOLUME_SIZE == 384
const ivec3 workGroups = ivec3(16, 24, 16);
#elif VOXEL_VOLUME_SIZE == 512
const ivec3 workGroups = ivec3(22, 32, 22);
#endif
#elif DDA_REGIONAL_LIGHTS == 1 && DDA_CACHE_INTERVAL == 4
#if VOXEL_VOLUME_SIZE == 128
const ivec3 workGroups = ivec3(8, 8, 8);
#elif VOXEL_VOLUME_SIZE == 192
const ivec3 workGroups = ivec3(12, 12, 12);
#elif VOXEL_VOLUME_SIZE == 256
const ivec3 workGroups = ivec3(16, 16, 16);
#elif VOXEL_VOLUME_SIZE == 384
const ivec3 workGroups = ivec3(24, 24, 24);
#elif VOXEL_VOLUME_SIZE == 512
const ivec3 workGroups = ivec3(32, 32, 32);
#endif
#elif DDA_REGIONAL_LIGHTS == 1 && DDA_CACHE_INTERVAL == 2
#if VOXEL_VOLUME_SIZE == 128
const ivec3 workGroups = ivec3(8, 8, 16);
#elif VOXEL_VOLUME_SIZE == 192
const ivec3 workGroups = ivec3(12, 12, 24);
#elif VOXEL_VOLUME_SIZE == 256
const ivec3 workGroups = ivec3(16, 16, 32);
#elif VOXEL_VOLUME_SIZE == 384
const ivec3 workGroups = ivec3(24, 24, 48);
#elif VOXEL_VOLUME_SIZE == 512
const ivec3 workGroups = ivec3(32, 32, 64);
#endif
#else
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
#endif
uniform usampler3D ddaMaskSampler,ddaCoarseSampler;
#if DDA_REGIONAL_LIGHTS == 1 && DDA_CACHE_INTERVAL > 1
uniform int frameCounter;
uniform ivec3 cameraPositionInt,previousCameraPositionInt;
uniform vec3 cameraPositionFract,previousCameraPositionFract;
// Use integer camera coordinates to match voxelization even far from spawn.
ivec3 cacheAnchor(ivec3 i, vec3 f){return (i+ivec3(floor(f))+4)&~ivec3(7);}
#endif
layout(r32ui) writeonly uniform uimage3D ddaLocal_img;
const int CACHE_CAP=32;
const int RING=(DDA_LIGHT_RANGE+7)/8;
const int WIDTH=2*RING+1;
shared uint total;
shared uint cells[CACHE_CAP];
shared uint activeBricks[4];

ivec3 bits3(int b){return ivec3(b&1,(b>>1)&1,(b>>2)&1);}
uint packCell(ivec3 c){return (uint(c.x)<<18u)|(uint(c.y)<<9u)|uint(c.z);}
#if DDA_REGIONAL_LIGHTS == 1
// Four nearest actual emitters at a fixed 4-block receiver region center.
// No pixel-level ranking. World-aligned voxel origin is a multiple of eight.
// Each lane produces an independent list; all 32 entries reuse the old cache.
#ifdef DDA_GROUP_LIGHTS
uniform usampler3D ddaGroupSampler;
ivec3 groupCoord(uint v){return ivec3(v&3u,(v>>2u)&3u,(v>>4u)&3u);}
#endif
void insertRegional(uint key,float d2,inout uint nearest[4],inout float distances[4],inout float cutoff){
    if(d2>cutoff || (d2==distances[3]&&(key&0x7ffffffu)>=(nearest[3]&0x7ffffffu)))return;
    int pos=3;
    while(pos>0&&(d2<distances[pos-1]||(d2==distances[pos-1]&&(key&0x7ffffffu)<(nearest[pos-1]&0x7ffffffu)))){
        distances[pos]=distances[pos-1];nearest[pos]=nearest[pos-1];--pos;
    }
    nearest[pos]=key;distances[pos]=d2;cutoff=min(cutoff,distances[3]);
}
void selectRegion(ivec3 center, uint lane, ivec3 base){
    vec3 receiver=vec3(center*8+bits3(int(lane))*4)+2.0;
    uint nearest[4]; float distances[4];
    for(int j=0;j<4;++j){nearest[j]=0xffffffffu; distances[j]=1e20;}
    ivec3 size=textureSize(ddaCoarseSampler,0);
    // A center outside a light's range does not prove that all receivers
    // in the four-block cell are outside. Include the cell's half diagonal.
    float reach=float(DDA_LIGHT_RANGE)+3.464102;
    float cutoff=reach*reach;
    for(int shell=0;shell<=RING;++shell){
        for(int z=-shell;z<=shell;++z)for(int y=-shell;y<=shell;++y)for(int x=-shell;x<=shell;++x){
            if(max(abs(x),max(abs(y),abs(z)))!=shell)continue;
            ivec3 c=center+ivec3(x,y,z);
            if(any(lessThan(c,ivec3(0)))||any(greaterThanEqual(c,size)))continue;
            vec3 lo=vec3(c*8)+0.5, hi=lo+7.0;
            vec3 gap=max(max(lo-receiver,receiver-hi),vec3(0));
            if(dot(gap,gap)>cutoff)continue;
            int slot=(x+RING)+WIDTH*((y+RING)+WIDTH*(z+RING));
            if((activeBricks[slot>>5]&(1u<<(slot&31)))==0u)continue;
            uint summary=texelFetch(ddaCoarseSampler,c,0).r&255u;
            while(summary!=0u){
                int b=findLSB(summary);summary&=summary-1u;
                ivec3 brick=c*2+bits3(b);lo=vec3(brick*4)+0.5;hi=lo+3.0;
                gap=max(max(lo-receiver,receiver-hi),vec3(0));
                if(dot(gap,gap)>cutoff)continue;
                #ifdef DDA_GROUP_LIGHTS
                uint group=texelFetch(ddaGroupSampler,brick,0).r;
                if(group!=0u && (group>>12u)>=4u){
                    ivec3 low=brick*4+groupCoord(group),high=brick*4+groupCoord(group>>6u);
                    vec3 a=vec3(low)+0.5-receiver,bv=vec3(high)+0.5-receiver;
                    vec3 nearV=max(max(a,-bv),vec3(0.0));
                    float gd=dot(nearV,nearV);
                    if(gd>=float(DDA_GROUP_DISTANCE*DDA_GROUP_DISTANCE)){
                        uint weight=min(group>>12u,4u);
                        insertRegional(packCell((low+high)/2)|((weight-1u)<<27u),gd,nearest,distances,cutoff);
                        continue;
                    }
                }
                #endif
                uvec2 masks=texelFetch(ddaMaskSampler,brick,0).rg;
                for(int w=0;w<2;++w){
                    uint bits=masks[w];
                    while(bits!=0u){
                        int bit=findLSB(bits)+w*32;bits&=bits-1u;
                        ivec3 cell=brick*4+bits3(bit>>3)*2+bits3(bit&7);
                        vec3 d=vec3(cell)+0.5-receiver;float d2=dot(d,d);uint key=packCell(cell);
                        insertRegional(key,d2,nearest,distances,cutoff);
                    }
                }
            }
        }
    }
    for(int j=0;j<4;++j)imageStore(ddaLocal_img,base+ivec3(0,1+int(lane)*4+j,0),uvec4(nearest[j]));
}
#endif
void buildRegion(ivec3 center){
    uint lane=gl_LocalInvocationIndex;
    #if DDA_TRACE_VOLUME < 100 && (DDA_DEBUG == 0 || DDA_DEBUG == 4)
    vec3 halfSize=vec3(VOXEL_VOLUME_SIZE,VOXEL_VOLUME_SIZE/2,VOXEL_VOLUME_SIZE)*0.5;
    vec3 nearHalf=halfSize*pow(float(DDA_TRACE_VOLUME)*0.01,1.0/3.0);
    // 4 blocks for world-lattice phase and 4 for the receiver brick half-size.
    if(any(greaterThan(abs(vec3(center)*8.0+4.0-halfSize),nearHalf+8.0))){
        if(lane==0u)imageStore(ddaLocal_img,ivec3(center.x,center.y*(CACHE_CAP+1),center.z),uvec4(0u));
        return;
    }
    #endif
    if(lane==0u)total=0u;

    if(lane<4u)activeBricks[lane]=0u;
    barrier();
    ivec3 size=textureSize(ddaCoarseSampler,0);
    for(int i=int(lane);i<WIDTH*WIDTH*WIDTH;i+=32){
        ivec3 c=center+ivec3(i%WIDTH,(i/WIDTH)%WIDTH,i/(WIDTH*WIDTH))-RING;
        if(any(lessThan(c,ivec3(0)))||any(greaterThanEqual(c,size)))continue;
        // Minimum separation between every receiver in this 8-cell region
        // and every possible emitter center in the candidate region.
        vec3 gap=max(abs(vec3(c-center)*8.0)-7.5,vec3(0.0));
        if(dot(gap,gap)>=float(DDA_LIGHT_RANGE*DDA_LIGHT_RANGE))continue;
        uint summary=texelFetch(ddaCoarseSampler,c,0).r&255u;
        if(summary!=0u)atomicOr(activeBricks[i>>5],1u<<(i&31));
        while(summary!=0u){
            if(atomicAdd(total,0u)>uint(CACHE_CAP))break;
            int b=findLSB(summary);summary&=summary-1u;
            ivec3 brick=c*2+bits3(b);uvec2 mask=texelFetch(ddaMaskSampler,brick,0).rg;
            for(int w=0;w<2;++w){
                uint bits=mask[w];if(bits==0u)continue;
                uint pos=atomicAdd(total,uint(bitCount(bits)));
                while(bits!=0u&&pos<uint(CACHE_CAP)){
                    int bit=findLSB(bits)+w*32;bits&=bits-1u;
                    cells[pos++]=packCell(brick*4+bits3(bit>>3)*2+bits3(bit&7));
                }
            }
        }
    }
    barrier();
    ivec3 base=ivec3(center.x,center.y*(CACHE_CAP+1),center.z);
    #if DDA_REGIONAL_LIGHTS == 1
    // Keep all sparse lights. Only crowded regions need a reduced list.
    if(total<=8u){
        // Atomic reservation order is not guaranteed across frames. Sort by
        // packed world-aligned coordinate before summing floating-point light.
        if(lane==0u){
            for(uint j=1u;j<total;++j){
                uint key=cells[j];int k=int(j)-1;
                while(k>=0){if(cells[k]<=key)break;cells[k+1]=cells[k];--k;}
                cells[k+1]=key;
            }
            imageStore(ddaLocal_img,base,uvec4(total));
        }
        barrier();
        if(lane<total)imageStore(ddaLocal_img,base+ivec3(0,int(lane)+1,0),uvec4(cells[lane]));
    }else{
        if(lane<8u)selectRegion(center,lane,base);
        if(lane==0u)imageStore(ddaLocal_img,base,uvec4(0x80000000u));
    }
    #else
    if(lane==0u)imageStore(ddaLocal_img,base,uvec4(total));
    // Overflow regions store the complete active coarse-region mask instead
    // of an unusable truncated emitter list. Four words cover all 125 cells.
    if(total<=uint(CACHE_CAP)){
        if(lane<total)imageStore(ddaLocal_img,base+ivec3(0,int(lane)+1,0),uvec4(cells[lane]));
    }else if(lane<4u)imageStore(ddaLocal_img,base+ivec3(0,int(lane)+1,0),uvec4(activeBricks[lane]));
    #endif
}

#if DDA_REGIONAL_LIGHTS == 1 && DDA_CACHE_INTERVAL == 8
// Symmetric outer widths, center absorbs any rounding remainder. The
// cache is camera-centered and world-aligned in 8-block increments.
// Every column covers the complete Y extent, matching a top-down 3x3 map.
void buildSection(ivec3 id,int section){
    ivec3 size=textureSize(ddaCoarseSampler,0);
    ivec2 n=size.xz;
    ivec2 outer=(n+1)/3;
    ivec2 middle=n-2*outer;
    ivec2 tile=ivec2(section%3,section/3);
    ivec2 lo=ivec2(tile.x==0?0:tile.x==1?outer.x:outer.x+middle.x,
                    tile.y==0?0:tile.y==1?outer.y:outer.y+middle.y);
    ivec2 extent=ivec2(tile.x==1?middle.x:outer.x,tile.y==1?middle.y:outer.y);
    if(any(greaterThanEqual(id.xz,extent))||id.y>=size.y)return;
    buildRegion(id+ivec3(lo.x,0,lo.y));
}
#endif

void main(){
    #if DDA_DEBUG >= 6
    return;
    #endif
    ivec3 id=ivec3(gl_WorkGroupID);
    #if DDA_REGIONAL_LIGHTS == 1 && DDA_CACHE_INTERVAL > 1
    bool rebuildAll=frameCounter<4 || any(notEqual(cacheAnchor(cameraPositionInt,cameraPositionFract),
                                                 cacheAnchor(previousCameraPositionInt,previousCameraPositionFract)));
    #if DDA_CACHE_INTERVAL == 8
    if(rebuildAll){
        for(int section=0;section<9;++section){
            buildSection(id,section);
            barrier();
        }
    }else{
        buildSection(id,4);
        barrier();
        // Walk the ring clockwise from north-west, skipping the center.
        const int ring[8]=int[8](0,1,2,5,8,7,6,3);
        buildSection(id,ring[frameCounter%8]);
    }
    #else
    #if DDA_CACHE_INTERVAL == 4
    ivec3 stride=ivec3(2,1,2);
    #else
    ivec3 stride=ivec3(2,1,1);
    #endif
    ivec3 base=id*stride;
    if(any(greaterThanEqual(base,textureSize(ddaCoarseSampler,0))))return;
    int phase=frameCounter % DDA_CACHE_INTERVAL;
    if(rebuildAll){
        for(int section=0;section<DDA_CACHE_INTERVAL;++section){
            buildRegion(base+ivec3(section&1,0,section>>1));
            // Each invocation finishes consuming shared storage before it is reused.
            barrier();
        }
    }else buildRegion(base+ivec3(phase&1,0,phase>>1));
    #endif
    #else
    buildRegion(id);
    #endif
}
