#include "/lib/vx/ddaMaterial.glsl"
#include "/lib/vx/ddaTrace.glsl"
uniform usampler3D ddaCoarseSampler, ddaLocalSampler;
#ifdef DDA_GROUP_LIGHTS
uniform usampler3D ddaGroupSampler;
#endif

// Exact lower distance bound and upper facing bound over possible cell centers.
// Rejecting a brick here cannot discard an eligible nearest-K source.
bool ddaBrickEligible(vec3 p, ivec3 base, int width, float cutoff,
                      vec3 normal, bool oneSided) {
    vec3 lo = vec3(base) + 0.5;
    vec3 hi = lo + float(width - 1);
    vec3 d = max(max(lo - p, p - hi), vec3(0.0));
    if (dot(d,d) > cutoff) return false;
    if (oneSided) {
        vec3 farthest = mix(lo, hi, greaterThanEqual(normal, vec3(0.0)));
        if (dot(farthest - p, normal) <= 0.0) return false;
    }
    return true;
}
// 9 bits per coordinate support every configured volume, including 512.
// Positive IEEE float bits preserve ordering; packed xyz preserves tie ordering.
uint ddaPackCell(ivec3 c) { return (uint(c.x) << 18u) | (uint(c.y) << 9u) | uint(c.z); }
ivec3 ddaUnpackCell(uint k) { return ivec3((k >> 18u)&511u, (k >> 9u) & 511u, k & 511u); }
int ddaWeight(uvec2 a){return int(a.y>>27u)+1;}

bool ddaBefore(uvec2 a, uvec2 b) { return a.x < b.x || (a.x == b.x && (a.y&0x7ffffffu) < (b.y&0x7ffffffu)); }
// Max heap retains exactly the K nearest eligible sources, with logarithmic
// insertion/replacement and the same deterministic tie order as DDA03.
void ddaSiftDown(inout uvec2 nearest[DDA_LIGHT_BUDGET],int count,uvec2 value){
    int pos=0;
    while(pos*2+1<count){
        int child=pos*2+1;
        if(child+1<count&&ddaBefore(nearest[child],nearest[child+1]))++child;
        if(!ddaBefore(value,nearest[child]))break;
        nearest[pos]=nearest[child];pos=child;
    }
    nearest[pos]=value;
}
void ddaInsertRanked(uvec2 candidate,inout uvec2 nearest[DDA_LIGHT_BUDGET],inout int count,inout int represented,inout float cutoff){
    if(count==DDA_LIGHT_BUDGET){
        if(!ddaBefore(candidate,nearest[0]))return;
        represented-=ddaWeight(nearest[0]);
        ddaSiftDown(nearest,count,candidate);
    }else{
        int pos=count++;
        while(pos>0){int parent=(pos-1)/2;if(!ddaBefore(nearest[parent],candidate))break;nearest[pos]=nearest[parent];pos=parent;}
        nearest[pos]=candidate;
    }
    represented+=ddaWeight(candidate);
    // A weighted group consumes the same approximate emitter budget as its
    // constituent blocks. Remove the farthest group only if enough remain.
    while(count>1 && represented-ddaWeight(nearest[0])>=DDA_LIGHT_BUDGET){
        represented-=ddaWeight(nearest[0]);uvec2 last=nearest[--count];ddaSiftDown(nearest,count,last);
    }
    if(represented>=DDA_LIGHT_BUDGET)cutoff=uintBitsToFloat(nearest[0].x);
}
void ddaInsert(ivec3 cell, vec3 p, vec3 normal, bool oneSided, float radius2,
               inout uvec2 nearest[DDA_LIGHT_BUDGET], inout int count, inout int represented,inout float cutoff) {
    vec3 v=vec3(cell)+0.5-p;float d2=dot(v,v);
    if(d2>=radius2||d2>cutoff)return;
    if(oneSided&&dot(v,normal)<=0.0)return;
    ddaInsertRanked(uvec2(floatBitsToUint(d2),ddaPackCell(cell)),nearest,count,represented,cutoff);
}
#ifdef DDA_GROUP_LIGHTS
ivec3 ddaGroupCoord(uint v){return ivec3(v&3u,(v>>2u)&3u,(v>>4u)&3u);}
bool ddaTryGroup(ivec3 base,vec3 p,vec3 normal,bool oneSided,float radius2,inout uvec2 nearest[DDA_LIGHT_BUDGET],inout int count,inout int represented,inout float cutoff){
    uint group=texelFetch(ddaGroupSampler,base/4,0).r;
    if(group==0u)return false;
    ivec3 lo=base+ddaGroupCoord(group),hi=base+ddaGroupCoord(group>>6u);
    ivec3 closeCell=clamp(ivec3(floor(p)),lo,hi);
    vec3 closeV=vec3(closeCell)+0.5-p;float d2=dot(closeV,closeV);
    // Nearby emitters stay exact; groups are never clipped across the range or hemisphere.
    if(d2<float(DDA_GROUP_DISTANCE*DDA_GROUP_DISTANCE))return false;
    vec3 a=vec3(lo)+0.5-p,b=vec3(hi)+0.5-p,farV=max(abs(a),abs(b));
    if(dot(farV,farV)>=radius2)return false;
    if(oneSided&&dot(mix(b,a,greaterThanEqual(normal,vec3(0.0))),normal)<=0.0)return false;
    if(d2>cutoff)return true;
    // Fixed actual emitter cell; never move the representative with the camera.
    ivec3 representative=(lo+hi)/2;
    vec3 repV=vec3(representative)+0.5-p;
    if(dot(repV,repV)>=radius2)return false;
    uint weight=uint(min(int(group>>12u),DDA_LIGHT_BUDGET));
    ddaInsertRanked(uvec2(floatBitsToUint(d2),ddaPackCell(representative)|((weight-1u)<<27u)),nearest,count,represented,cutoff);
    return true;
}
#endif
void ddaSort(inout uvec2 nearest[DDA_LIGHT_BUDGET],int count){
    for(int end=count-1;end>0;--end){
        uvec2 last=nearest[end];nearest[end]=nearest[0];
        ddaSiftDown(nearest,end,last);
    }
}
void ddaInsertSparse(ivec3 cell, vec3 p, vec3 normal, bool oneSided, float radius2,
               inout uvec2 nearest[DDA_LIGHT_BUDGET], inout int count, inout float cutoff) {
    vec3 v = vec3(cell) + 0.5 - p;
    float d2 = dot(v,v);
    if (d2 >= radius2 || d2 > cutoff) return;
    if (oneSided && dot(v, normal) <= 0.0) return;
    uvec2 candidate = uvec2(floatBitsToUint(d2), ddaPackCell(cell));
    int pos = count;
    if (count == DDA_LIGHT_BUDGET) {
        pos = count - 1;
        if (!ddaBefore(candidate, nearest[pos])) return;
    } else ++count;
    while (pos > 0 && ddaBefore(candidate, nearest[pos-1])) {
        nearest[pos] = nearest[pos-1]; --pos;
    }
    nearest[pos] = candidate;
    if (count == DDA_LIGHT_BUDGET) cutoff = uintBitsToFloat(nearest[count-1].x);
}
ivec3 ddaOctantOffset(int b) { return ivec3(b & 1, (b >> 1) & 1, b >> 2); }
// Local cache masks are partitioned into Chebyshev shells, preserving the
// near-to-far cutoff and tie-breaking of the exhaustive search.
#if DDA_LIGHT_RANGE == 8
const int ddaCacheRing=1, ddaCacheWidth=3;
const uvec4 ddaShellMasks[2]=uvec4[](uvec4(0x00002000u,0x00000000u,0x00000000u,0x00000000u),uvec4(0x07ffdfffu,0x00000000u,0x00000000u,0x00000000u));
#else
const int ddaCacheRing=2, ddaCacheWidth=5;
const uvec4 ddaShellMasks[3]=uvec4[](uvec4(0x00000000u,0x40000000u,0x00000000u,0x00000000u),uvec4(0x80000000u,0xa7000e73u,0x39ce001cu,0x00000000u),uvec4(0x7fffffffu,0x18fff18cu,0xc631ffe3u,0x1fffffffu));
#endif
// Masks for the four local coordinates on each axis; use only the
// cells in the union AABB instead of rejecting whole occupied bricks.
const uvec2 ddaSliceX[4]=uvec2[](uvec2(0x00550055u,0x00550055u),uvec2(0x00aa00aau,0x00aa00aau),uvec2(0x55005500u,0x55005500u),uvec2(0xaa00aa00u,0xaa00aa00u));
const uvec2 ddaSliceY[4]=uvec2[](uvec2(0x00003333u,0x00003333u),uvec2(0x0000ccccu,0x0000ccccu),uvec2(0x33330000u,0x33330000u),uvec2(0xcccc0000u,0xcccc0000u));
const uvec2 ddaSliceZ[4]=uvec2[](uvec2(0x0f0f0f0fu,0x00000000u),uvec2(0xf0f0f0f0u,0x00000000u),uvec2(0x00000000u,0x0f0f0f0fu),uvec2(0x00000000u,0xf0f0f0f0u));
bool ddaBrickHasBlocker(ivec3 brick,ivec3 lo,ivec3 hi){
    ivec3 a=max(lo-brick*4,ivec3(0)), b=min(hi-brick*4,ivec3(3));
    uvec2 m=texelFetch(ddaMaskSampler,brick,0).ba;
    if(a.x>0||b.x<3){uvec2 k=uvec2(0);for(int i=a.x;i<=b.x;++i)k|=ddaSliceX[i];m&=k;}
    if(a.y>0||b.y<3){uvec2 k=uvec2(0);for(int i=a.y;i<=b.y;++i)k|=ddaSliceY[i];m&=k;}
    if(a.z>0||b.z<3){uvec2 k=uvec2(0);for(int i=a.z;i<=b.z;++i)k|=ddaSliceZ[i];m&=k;}
    return (m.x|m.y)!=0u;
}
void ddaSearchBrick(ivec3 base,vec3 p,vec3 geometryNormal,bool oneSided,float radius2,inout uvec2 nearest[DDA_LIGHT_BUDGET],inout int count,inout int represented,inout float cutoff){
uvec2 masks = texelFetch(ddaMaskSampler, base / 4, 0).rg;
int population = bitCount(masks.x) + bitCount(masks.y);
#ifdef DDA_GROUP_LIGHTS
if(population>=4&&ddaTryGroup(base,p,geometryNormal,oneSided,radius2,nearest,count,represented,cutoff))return;
#endif
if (population <= 8) {
    // Sparse bricks: enumerate only actual sources, no child loops.
    for (int word = 0; word < 2; ++word) {
        uint bits = masks[word];
        while (bits != 0u) {
            int bit = findLSB(bits) + word * 32;
            bits &= bits - 1u;
            ivec3 cell = base + ddaOctantOffset(bit >> 3) * 2 + ddaOctantOffset(bit & 7);
            ddaInsert(cell, p, geometryNormal, oneSided, radius2, nearest, count, represented, cutoff);
        }
    }
} else {
    // Dense bricks: prune complete 2^3 octants before visiting sources.
    int nearOctant = int(p.x >= float(base.x+2)) + 2*int(p.y >= float(base.y+2)) + 4*int(p.z >= float(base.z+2));
    for (int octVisit = 0; octVisit < 8; ++octVisit) {
        int octant = octVisit ^ nearOctant;
        uint bits = (masks[octant >> 2] >> ((octant & 3) * 8)) & 255u;
        if (bits == 0u) continue;
        ivec3 child = base + ddaOctantOffset(octant) * 2;
        if (!ddaBrickEligible(p, child, 2, cutoff, geometryNormal, oneSided)) continue;
        while (bits != 0u) {
            int bit = findLSB(bits);
            bits &= bits - 1u;
            ddaInsert(child + ddaOctantOffset(bit), p, geometryNormal, oneSided, radius2, nearest, count, represented, cutoff);
        }
    }
}
}

bool ddaEmptyUnion(ivec3 rayLo,ivec3 rayHi){
    ivec3 brickLo = rayLo / 4, brickHi = rayHi / 4;
    bool emptyUnion = true;
    for (int z=brickLo.z/2; z<=brickHi.z/2 && emptyUnion; ++z)
    for (int y=brickLo.y/2; y<=brickHi.y/2 && emptyUnion; ++y)
    for (int x=brickLo.x/2; x<=brickHi.x/2 && emptyUnion; ++x) {
        ivec3 coarse=ivec3(x,y,z);
        uint blockers=texelFetch(ddaCoarseSampler,coarse,0).r >> 8u;
        while(blockers!=0u) {
            int b=findLSB(blockers); blockers &= blockers-1u;
            ivec3 brick=coarse*2+ddaOctantOffset(b);
            if(all(greaterThanEqual(brick,brickLo))&&all(lessThanEqual(brick,brickHi)) && ddaBrickHasBlocker(brick,rayLo,rayHi)) {emptyUnion=false;break;}
        }
    }
    return emptyUnion;
}
vec3 ddaLightContribution(ivec3 cell,vec3 p,vec3 geometryNormal,float twoSided,bool surface,float radius){
    vec3 v=vec3(cell)+0.5-p;float d2=dot(v,v);float distance=sqrt(d2);
    float cosine=dot(v,geometryNormal)/max(distance,0.0001);
    float facing=surface?mix(max(cosine,0.0),abs(cosine),twoSided):1.0;
    float window=max(1.0-distance/radius,0.0);
    return ddaEmission(texelFetch(voxelSampler,cell,0).r)*facing*(window*window/(1.0+0.25*d2));
}
#if DDA_REGIONAL_LIGHTS == 1
ivec3 ddaRegionBase(ivec3 region){ivec3 c=region>>1;return ivec3(c.x,c.y*33,c.z);}
vec3 ddaRegionalList(ivec3 region,uint cached,vec3 p,vec3 start,ivec3 startCell,uint solid,vec3 geometryNormal,float twoSided,bool surface,float radius){
    if(cached==0u)return vec3(0.0);
    ivec3 base=ddaRegionBase(region),sub=region&1;
    bool sparse=cached<=8u;
    int offset=sparse?1:1+4*(sub.x+2*sub.y+4*sub.z);
    int count=sparse?int(cached):4;
    bool oneSided=surface&&twoSided<0.5;
    float radius2=radius*radius;
    uint eligible=(1u<<count)-1u;bool emptyUnion=false;
    if(sparse){
        eligible=0u;ivec3 rayLo=startCell,rayHi=startCell;
        for(int i=0;i<count;++i){
            ivec3 c=ddaUnpackCell(texelFetch(ddaLocalSampler,base+ivec3(0,offset+i,0),0).r);
            vec3 v=vec3(c)+0.5-p;
            if(maxOf(ddaEmission(texelFetch(voxelSampler,c,0).r))<=0.0||dot(v,v)>=radius2||(oneSided&&dot(v,geometryNormal)<=0.0))continue;
            eligible|=1u<<i;rayLo=min(rayLo,c);rayHi=max(rayHi,c);
        }
        if(eligible==0u)return vec3(0.0);
        #if DDA_DEBUG != 4
        emptyUnion=ddaEmptyUnion(rayLo,rayHi);
        #endif
    }
    vec3 light=vec3(0.0);
    while(eligible!=0u){
        int i=findLSB(eligible);eligible&=eligible-1u;
        uint key=texelFetch(ddaLocalSampler,base+ivec3(0,offset+i,0),0).r;
        if(key==0xffffffffu)break;
        ivec3 c=ddaUnpackCell(key);
        if(!sparse){vec3 v=vec3(c)+0.5-p;if(dot(v,v)>=radius2||(oneSided&&dot(v,geometryNormal)<=0.0))continue;}
        vec3 contribution=ddaLightContribution(c,p,geometryNormal,twoSided,surface,radius);
        uint weight=sparse?1u:(key>>27u)+1u;
        if(maxOf(contribution)<=0.0||maxOf(contribution)*DDA_BRIGHTNESS*float(weight)<DDA_MIN_CONTRIBUTION)continue;
        vec3 transmission=vec3(1.0);
        #if DDA_DEBUG != 4
        bool clear=emptyUnion;
        #if DDA_SOFT_SAMPLES > 0
        if(!sparse)clear=ddaEmptyUnion(min(startCell,c),max(startCell,c));
        #endif
        if(!clear)transmission=ddaAreaTransmission(start,startCell,c,solid,!sparse);
        #endif
        #ifdef DDA_GROUP_LIGHTS
        if(weight>1u){
            uint group=texelFetch(ddaGroupSampler,c/4,0).r;
            ivec3 low=(c/4)*4+ivec3(group&3u,(group>>2u)&3u,(group>>4u)&3u);
            ivec3 high=(c/4)*4+ivec3((group>>6u)&3u,(group>>8u)&3u,(group>>10u)&3u);
            weight=group!=0u && all(equal(c,(low+high)/2)) ? min(weight,group>>12u) : 1u;
        }
        #endif
        light+=contribution*transmission*float(weight);
    }
    return light;
}
#endif
vec3 ddaLighting(vec3 p, vec3 geometryNormal, float twoSided, bool surface) {
    #if DDA_DEBUG >= 5
    return vec3(0.0);
    #endif
    if (!isInsideVoxelVolume(p)) return vec3(0.0);
    float radius = float(DDA_LIGHT_RANGE);
    float radius2 = radius * radius;
    vec3 start = p + (surface ? geometryNormal * 0.002 : vec3(0.0));
    if (!isInsideVoxelVolume(start)) return vec3(0.0);
    // Select the cache on the same side of the surface as the ray origin.
    // Raw surface coordinates can round to either side of an integer plane.
    ivec3 startCell = ivec3(floor(start));
    ivec3 coarseCenter = startCell >> 3;
    ivec3 cacheBase=ivec3(coarseCenter.x,coarseCenter.y*33,coarseCenter.z);
    uint cached=texelFetch(ddaLocalSampler,cacheBase,0).r;
    #if DDA_REGIONAL_LIGHTS != 1 || !defined DDA_REGION_BLEND
    if(cached==0u)return vec3(0.0);
    #endif
    uint solid = ddaModelAt(startCell);
    if (solid == 1u) return vec3(0.0);
    bool oneSided = surface && twoSided < 0.5;
    #if DDA_REGIONAL_LIGHTS == 1
    ivec3 region=startCell>>2;
    #ifdef DDA_REGION_BLEND
    // Crossfade cached lists in a narrow world-space band around their
    // shared planes. No new spatial emitter discovery is performed.
    // A receiver on a geometric face cannot cross its normal-axis plane;
    // exclude that axis to avoid tracing both sides of an entire wall.
    vec3 f=fract(start*0.25);
    ivec3 side=ivec3(greaterThanEqual(f,vec3(0.5)))*2-1;
    vec3 blend=0.5*(1.0-smoothstep(vec3(0.0),vec3(0.0625),min(f,1.0-f)));
    if(surface)blend=mix(blend,vec3(0.0),greaterThan(abs(geometryNormal),vec3(0.9)));
    ivec3 neighbor=region+side;
    blend=mix(blend,vec3(0.0),bvec3(neighbor.x<0||neighbor.x>=ddaSize.x/4,neighbor.y<0||neighbor.y>=ddaSize.y/4,neighbor.z<0||neighbor.z>=ddaSize.z/4));
    // Sparse lists already contain all relevant lights. Only crossfade
    // if at least one participating list has actually been truncated.
    bool dense=cached>8u;
    if(!dense&&any(greaterThan(blend,vec3(0.0)))){
        for(int j=1;j<8&&!dense;++j){
            ivec3 q=ivec3(j&1,(j>>1)&1,j>>2);
            if(any(bvec3(q.x!=0&&blend.x==0.0,q.y!=0&&blend.y==0.0,q.z!=0&&blend.z==0.0)))continue;
            dense=texelFetch(ddaLocalSampler,ddaRegionBase(region+q*side),0).r>8u;
        }
    }
    if(!dense)blend=vec3(0.0);
    vec3 light=vec3(0.0);
    int count=any(greaterThan(blend,vec3(0.0)))?8:1;
    for(int j=0;j<count;++j){
        ivec3 q=ivec3(j&1,(j>>1)&1,j>>2);
        vec3 w=mix(1.0-blend,blend,notEqual(q,ivec3(0)));
        float weight=w.x*w.y*w.z;if(weight<=0.0)continue;
        ivec3 r=region+q*side;
        uint header=j==0?cached:texelFetch(ddaLocalSampler,ddaRegionBase(r),0).r;
        light+=weight*ddaRegionalList(r,header,p,start,startCell,solid,geometryNormal,twoSided,surface,radius);
    }
    return light;
    #else
    return ddaRegionalList(region,cached,p,start,startCell,solid,geometryNormal,twoSided,surface,radius);
    #endif
    #else
    // Every eligible light fits in the budget. Do not build or sort a
    // per-fragment nearest-K array just to select all of its members.
    if(cached<=uint(DDA_LIGHT_BUDGET)){
        uint eligible=0u;ivec3 rayLo=startCell,rayHi=startCell;
        for(uint i=0u;i<cached;++i){
            ivec3 c=ddaUnpackCell(texelFetch(ddaLocalSampler,cacheBase+ivec3(0,int(i)+1,0),0).r);
            vec3 v=vec3(c)+0.5-p;
            if(dot(v,v)>=radius2||(oneSided&&dot(v,geometryNormal)<=0.0))continue;
            eligible|=1u<<i;rayLo=min(rayLo,c);rayHi=max(rayHi,c);
        }
        if(eligible==0u)return vec3(0.0);
        #if DDA_DEBUG != 4
        bool emptyUnion=ddaEmptyUnion(rayLo,rayHi);
        #endif
        vec3 light=vec3(0.0);
        while(eligible!=0u){
            int i=findLSB(eligible);eligible&=eligible-1u;
            ivec3 c=ddaUnpackCell(texelFetch(ddaLocalSampler,cacheBase+ivec3(0,i+1,0),0).r);
            vec3 contribution=ddaLightContribution(c,p,geometryNormal,twoSided,surface,radius);
            vec3 transmission=vec3(1.0);
            #if DDA_DEBUG != 4
            if(!emptyUnion)transmission=ddaAreaTransmission(start,startCell,c,solid,false);
            #endif
            light+=contribution*transmission;
        }
        return light;
    }
    uvec2 nearest[DDA_LIGHT_BUDGET];
    int count = 0, represented = 0;
    float cutoff = radius2;
    if(cached<=32u){
        for(uint i=0u;i<cached;++i){
            ivec3 c=ddaUnpackCell(texelFetch(ddaLocalSampler,cacheBase+ivec3(0,int(i)+1,0),0).r);
            ddaInsertSparse(c,p,geometryNormal,oneSided,radius2,nearest,count,cutoff);
        }
    }
    else {
    uvec4 activeMask=uvec4(texelFetch(ddaLocalSampler,cacheBase+ivec3(0,1,0),0).r,
        texelFetch(ddaLocalSampler,cacheBase+ivec3(0,2,0),0).r,
        texelFetch(ddaLocalSampler,cacheBase+ivec3(0,3,0),0).r,
        texelFetch(ddaLocalSampler,cacheBase+ivec3(0,4,0),0).r);
    for (int shell = 0; shell <= ddaCacheRing; ++shell) {
        if (shell > 0) {
            vec3 center = vec3(coarseCenter * 8) + 4.0;
            vec3 d = max(vec3(0.0), vec3(float(shell * 8) - 3.5) - abs(p - center));
            float bound = min(d.x, min(d.y,d.z));
            if (bound * bound > cutoff) break;
        }
        uvec4 shellBits=activeMask&ddaShellMasks[shell];
        for(int word=0;word<4;++word){
            uint activeWord=shellBits[word];
            while(activeWord!=0u){
                int idx=findLSB(activeWord)+word*32;activeWord&=activeWord-1u;
                ivec3 coarse=coarseCenter+ivec3(idx%ddaCacheWidth,(idx/ddaCacheWidth)%ddaCacheWidth,idx/(ddaCacheWidth*ddaCacheWidth))-ddaCacheRing;
                if (!ddaBrickEligible(p, coarse * 8, 8, cutoff, geometryNormal, oneSided)) continue;
                uint summary = texelFetch(ddaCoarseSampler, coarse, 0).r & 255u;
                // Visit the child containing/nearest the receiver first, to tighten cutoff.
                int nearBrick = int(p.x >= float(coarse.x*8+4)) + 2*int(p.y >= float(coarse.y*8+4)) + 4*int(p.z >= float(coarse.z*8+4));
                // A sparse summary is cheapest to enumerate directly. Dense summaries
                // are permuted by XOR so the nearest child is visited first.
                uint remaining = summary;
                for (int visit = 0; remaining != 0u && visit < 8; ++visit) {
                    int b = bitCount(summary) <= 2 ? findLSB(remaining) : (visit ^ nearBrick);
                    if ((remaining & (1u << b)) == 0u) continue;
                    remaining &= ~(1u << b);
                    ivec3 base = coarse * 8 + ddaOctantOffset(b) * 4;
                    if (!ddaBrickEligible(p, base, 4, cutoff, geometryNormal, oneSided)) continue;
                    ddaSearchBrick(base,p,geometryNormal,oneSided,radius2,nearest,count,represented,cutoff);
                }
            }
        }
    }
    }
    if (count == 0) return vec3(0.0);
    if(cached>32u)ddaSort(nearest,count);
    #if DDA_DEBUG != 4
    // A common case (open rooms or emissive terrain): all selected segments
    // fit inside an empty axis-aligned union of 4^3 bricks. The coarse upper
    // bits prove this without any per-ray tracing. No optimistic assumptions.
    ivec3 rayLo = startCell, rayHi = startCell;
    for (int i = 0; i < count; ++i) {
        ivec3 c = ddaUnpackCell(nearest[i].y);
        rayLo = min(rayLo,c); rayHi = max(rayHi,c);
    }
    bool emptyUnion=ddaEmptyUnion(rayLo,rayHi);
    #endif
    vec3 light = vec3(0.0);
    int budgetRemaining=DDA_LIGHT_BUDGET;
    for (int i = 0; i < count; ++i) {
        ivec3 cell = ddaUnpackCell(nearest[i].y);
        int weight=min(ddaWeight(nearest[i]),budgetRemaining);
        budgetRemaining-=weight;
        if(weight<=0)break;
        // Origin and target already validated by the caller/index; no repeated start fetch.
        vec3 transmission=vec3(1.0);
        #if DDA_DEBUG != 4
        if (!emptyUnion) transmission=ddaAreaTransmission(start,startCell,cell,solid);
        #endif
        light += ddaLightContribution(cell,p,geometryNormal,twoSided,surface,radius)*float(weight)*transmission;
    }
    return light;
    #endif
}
