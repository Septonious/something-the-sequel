// Finite conservative supercover traversal; partial models are analytic.
uniform usampler3D voxelSampler, ddaMaskSampler;
#ifndef DDA_SHAPE_LOD_DISTANCE
#define DDA_SHAPE_LOD_DISTANCE 32
#endif
const ivec3 ddaSize = ivec3(VOXEL_VOLUME_SIZE, VOXEL_VOLUME_SIZE / 2, VOXEL_VOLUME_SIZE);
#include "/lib/vx/ddaShapes.glsl"
bool ddaValid(ivec3 p) {return all(greaterThanEqual(p,ivec3(0)))&&all(lessThan(p,ddaSize));}
int ddaCellBit(ivec3 p) {
    ivec3 c=p&3;ivec3 o=c>>1;ivec3 q=c&1;
    return 8*(o.x+2*o.y+4*o.z)+q.x+2*q.y+4*q.z;
}
uint ddaModelPacked(ivec3 p,uvec2 mask){
    int b=ddaCellBit(p);
    if ((mask[b>>5] & (1u<<(b&31)))==0u)return 0u;
    uint code=texelFetch(voxelSampler,p,0).r;
    if(code>=200u && code<=215u)return 1024u+code-200u;
    return code>=256u?code-256u:(code==254u?2u:1u);
}
uint ddaModelAt(ivec3 p){return ddaModelPacked(p,texelFetch(ddaMaskSampler,p>>2,0).ba);}
bool ddaBlocked(ivec3 p) {if(!ddaValid(p))return true;uint m=ddaModelAt(p);return m!=0u && m<1024u;}
bool ddaRayHit(uint model,ivec3 cell,vec3 start,vec3 inv,bvec3 parallel,float len) {
    if(model<=1u)return model==1u;
    vec3 cameraDelta=vec3(cell)+0.5-vec3(ddaSize)*0.5;
    // Distance selects an exact bounding hierarchy, not a coarser occluder.
    return ddaShapeHit(model,start-vec3(cell),inv,parallel,len,dot(cameraDelta,cameraDelta)>float(DDA_SHAPE_LOD_DISTANCE*DDA_SHAPE_LOD_DISTANCE));
}
// Linear RGB transmission: filter the existing spectrum, never replace it.
// Tint strength is configurable; repeated layers compound.
const vec3 ddaGlassTint[16]=vec3[](
    vec3(1.0,0.12,0.12),vec3(1.0,0.46,0.12),vec3(1.0,0.92,0.12),vec3(0.55,0.28,0.12),
    vec3(0.20,0.70,0.12),vec3(0.52,1.0,0.12),vec3(0.13,0.24,1.0),vec3(0.35,0.72,1.0),
    vec3(0.15,0.72,0.80),vec3(0.55,0.17,0.83),vec3(0.88,0.19,0.75),vec3(1.0,0.51,0.71),
    vec3(0.08),vec3(0.95),vec3(0.32),vec3(0.65));
#ifndef DDA_GLASS_STRENGTH
#define DDA_GLASS_STRENGTH 0.85
#endif
vec3 ddaGlassTransmission(uint model){return mix(vec3(1.0),ddaGlassTint[model-1024u],DDA_GLASS_STRENGTH);}
bool ddaTransmitSegment(vec3 start,ivec3 cell,ivec3 target,vec3 endpoint,uint startModel,out vec3 transmission,out ivec3 opaqueHit) {
    transmission=vec3(1.0);opaqueHit=ivec3(-1);
    if(all(equal(cell,target)))return true;
    vec3 delta=endpoint-start;float len=length(delta);
    if(len<=0.000001)return true;
    vec3 dir=delta/len;ivec3 stepCell=ivec3(sign(dir));bvec3 parallel=equal(stepCell,ivec3(0));
    vec3 inv=1.0/mix(dir,vec3(1.0),parallel);
    if(startModel>0u&&startModel<1024u&&ddaRayHit(startModel,cell,start,inv,parallel,len)){if(startModel==1u)opaqueHit=cell;return false;}
    vec3 nextPlane=vec3(cell)+max(vec3(stepCell),vec3(0));
    vec3 nextT=mix(max((nextPlane-start)*inv,vec3(0)),vec3(1e20),parallel);
    if(startModel>=1024u)transmission*=pow(ddaGlassTransmission(startModel),vec3(min(len,min(nextT.x,min(nextT.y,nextT.z)))));
    ivec3 span=abs(target-cell);int limit=span.x+span.y+span.z;
    ivec3 cachedBrick=cell>>2;
    uvec2 cachedMask=texelFetch(ddaMaskSampler,cachedBrick,0).ba;
    for(int i=0;i<limit;++i){
        float t=min(nextT.x,min(nextT.y,nextT.z));if(t>len)return false;
        bvec3 tied=lessThanEqual(abs(nextT-vec3(t)),vec3(0.000002));
        ivec3 step=ivec3(tied)*stepCell;
        int mask=int(tied.x)+2*int(tied.y)+4*int(tied.z);
        // A regular crossing only enters one cell. Reserve the supercover
        // subset loop for actual edge/corner ties, and handle the destination
        // once outside that loop. Empty brick masks never require decoding.
        if((mask & (mask-1))!=0){
            for(int subset=(mask-1)&mask;subset!=0;subset=(subset-1)&mask){
                ivec3 p=cell+step*ivec3(subset&1,(subset>>1)&1,(subset>>2)&1);
                if(all(equal(p,target)))continue;
                ivec3 brick=p>>2;
                if(any(notEqual(brick,cachedBrick))){cachedBrick=brick;cachedMask=texelFetch(ddaMaskSampler,brick,0).ba;}
                if((cachedMask.x|cachedMask.y)==0u)continue;
                uint model=ddaModelPacked(p,cachedMask);
                if(model==1u){opaqueHit=p;return false;}
                if(model>1u&&model<1024u&&ddaRayHit(model,p,start,inv,parallel,len))return false;
            }
        }
        cell+=step;if(all(equal(cell,target)))return true;
        ivec3 brick=cell>>2;
        if(any(notEqual(brick,cachedBrick))){cachedBrick=brick;cachedMask=texelFetch(ddaMaskSampler,brick,0).ba;}
        if((cachedMask.x|cachedMask.y)!=0u){
            uint model=ddaModelPacked(cell,cachedMask);
            if(model==1u){opaqueHit=cell;return false;}
            if(model>=1024u){
                // Optical depth is proportional to path length, not voxel count.
                vec3 exitPlane=(vec3(cell)+max(vec3(stepCell),vec3(0))-start)*inv;
                vec3 exitT=mix(exitPlane,vec3(1e20),parallel);
                transmission*=pow(ddaGlassTransmission(model),vec3(max(min(len,min(exitT.x,min(exitT.y,exitT.z)))-t,0.0)));
            }else if(model>1u&&ddaRayHit(model,cell,start,inv,parallel,len))return false;
        }
        vec3 crossing=(vec3(cell)+max(vec3(stepCell),vec3(0))-start)*inv;
        nextT=mix(nextT,crossing,tied);
    }
    return false;
}
bool ddaTransmitOpen(vec3 start,ivec3 cell,ivec3 target,uint startModel,out vec3 transmission){
    ivec3 hit;return ddaTransmitSegment(start,cell,target,vec3(target)+0.5,startModel,transmission,hit);
}
#ifndef DDA_SOFT_SAMPLES
#define DDA_SOFT_SAMPLES 0
#endif
#ifndef DDA_SOFT_RADIUS
#define DDA_SOFT_RADIUS 0.42
#endif
#if DDA_SOFT_SAMPLES > 0 && defined DDA_CONTINUOUS_SOFT
#include "/lib/vx/ddaContinuous.glsl"
#endif
#if DDA_SOFT_SAMPLES > 0
// Fixed world-space stratified cube quadrature; all endpoints lie inside
// the emitter. Each sample tests the complete blocker union, not a resettable penumbra.
#if DDA_SOFT_SAMPLES == 4
const ivec3 ddaSamplePattern[4]=ivec3[](ivec3(0,1,1),ivec3(1,3,3),ivec3(2,2,0),ivec3(3,0,2));
#elif DDA_SOFT_SAMPLES == 8
const ivec3 ddaSamplePattern[8]=ivec3[](ivec3(0,4,4),ivec3(1,7,6),ivec3(2,0,2),ivec3(3,2,0),ivec3(4,6,3),ivec3(5,3,7),ivec3(6,5,1),ivec3(7,1,5));
#elif DDA_SOFT_SAMPLES == 16
const ivec3 ddaSamplePattern[16]=ivec3[](ivec3(0,12,4),ivec3(1,8,13),ivec3(2,3,9),ivec3(3,15,6),ivec3(4,4,14),ivec3(5,2,0),ivec3(6,7,5),ivec3(7,5,8),ivec3(8,14,15),ivec3(9,10,10),ivec3(10,9,2),ivec3(11,13,11),ivec3(12,1,12),ivec3(13,0,3),ivec3(14,11,1),ivec3(15,6,7));
#endif
vec3 ddaAreaEndpoint(ivec3 target,int i){
    vec3 q=(vec3(ddaSamplePattern[i])+0.5)/float(DDA_SOFT_SAMPLES);
    return vec3(target)+0.5+(q*2.0-1.0)*DDA_SOFT_RADIUS;
}
#endif
#if DDA_SOFT_SAMPLES > 0
// A strictly interior segment intersection with an already confirmed full
// opaque cell is a proof of occlusion. Touches/ties still use the normal DDA.
bool ddaKnownBlocker(vec3 start,vec3 endpoint,ivec3 blocker){
    vec3 d=endpoint-start;
    bvec3 parallel=equal(d,vec3(0.0));
    vec3 local=start-vec3(blocker);
    if(any(bvec3(parallel.x&&(local.x<=0.0||local.x>=1.0),parallel.y&&(local.y<=0.0||local.y>=1.0),parallel.z&&(local.z<=0.0||local.z>=1.0))))return false;
    vec3 inv=1.0/mix(d,vec3(1.0),parallel);
    float enter,leave;
    return ddaBoxInterval(start-vec3(blocker),inv,parallel,1.0,vec3(0.0),vec3(16.0),enter,leave)
        && leave-enter>0.00001;
}
#endif
vec3 ddaAreaTransmission(vec3 start,ivec3 cell,ivec3 target,uint startModel,bool shareBlockers){
    #if DDA_SOFT_SAMPLES > 0
    if(all(equal(cell,target)))return vec3(1.0);
    #ifdef DDA_CONTINUOUS_SOFT
    vec3 continuous;
    if(ddaContinuousTransmission(start,cell,target,continuous))return continuous;
    #endif
    vec3 sum=vec3(0.0);ivec3 blocker=ivec3(-1);
    for(int i=0;i<DDA_SOFT_SAMPLES;++i){
        vec3 endpoint=ddaAreaEndpoint(target,i);
        if(shareBlockers&&blocker.x>=0&&ddaKnownBlocker(start,endpoint,blocker))continue;
        vec3 t;ivec3 hit;
        if(ddaTransmitSegment(start,cell,target,endpoint,startModel,t,hit))sum+=t;
        else if(shareBlockers&&hit.x>=0)blocker=hit;
    }
    return sum/float(DDA_SOFT_SAMPLES);
    #else
    vec3 t;return ddaTransmitOpen(start,cell,target,startModel,t)?t:vec3(0.0);
    #endif
}
vec3 ddaAreaTransmission(vec3 start,ivec3 cell,ivec3 target,uint startModel){return ddaAreaTransmission(start,cell,target,startModel,true);}
bool ddaVisibleOpen(vec3 start,ivec3 cell,ivec3 target,uint startModel){vec3 transmission;return ddaTransmitOpen(start,cell,target,startModel,transmission);}
bool ddaVisible(vec3 start,ivec3 target){
    ivec3 cell=ivec3(floor(start));if(!ddaValid(cell)||!ddaValid(target))return false;
    return ddaVisibleOpen(start,cell,target,ddaModelAt(cell));
}
