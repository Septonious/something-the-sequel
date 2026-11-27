// Continuous visibility of two finite diagonal line emitters. This is a
// deterministic approximation to a cube area light, not a Monte Carlo count.
// Project each blocker onto the emitter parameter s in [-1,1]. In homogeneous
// coordinates r=1/t, the box inequalities are linear in (r,s). Eliminating r
// gives the exact covered interval of the finite source line.
bool ddaClipLinear(float a,float b,inout vec2 span){
    if(abs(a)<1e-8)return b>=0.0;
    float q=b/a;
    if(a>0.0)span.y=min(span.y,q);else span.x=max(span.x,q);
    return span.y>span.x;
}
bool ddaProjectedInterval(vec3 origin,vec3 delta,vec3 axis,vec3 lo,vec3 hi,out vec2 span){
    span=vec2(-1.0,1.0);
    vec3 l=lo-origin,h=hi-origin;
    // At r=1/t >= 1, every face defines either a lower or upper
    // bound on r. Compare each upper bound with all lower bounds.
    for(int j=0;j<3;++j){
        if(abs(l[j])<1e-7&&!ddaClipLinear(-axis[j],delta[j],span))return false;
        if(abs(h[j])<1e-7&&!ddaClipLinear(axis[j],-delta[j],span))return false;
    }
    for(int i=0;i<3;++i){
        float nearPlane=l[i]>1e-7?l[i]:(h[i]<-1e-7?h[i]:0.0);
        if(nearPlane==0.0)continue;
        float q=delta[i]/nearPlane,m=axis[i]/nearPlane;
        if(!ddaClipLinear(-m,q-1.0,span))return false;
        for(int j=0;j<3;++j){
            if(l[j]<-1e-7&&!ddaClipLinear(m*l[j]-axis[j],delta[j]-q*l[j],span))return false;
            if(h[j]>1e-7&&!ddaClipLinear(axis[j]-m*h[j],q*h[j]-delta[j],span))return false;
        }
    }
    return span.y>span.x;
}
// Sorted disjoint union of opaque intervals. Overflow is handled by the
// existing finite-ray path, not by dropping blockers.
#ifndef DDA_CONTINUOUS_LINES
#define DDA_CONTINUOUS_LINES 1
#endif
const int ddaIntervalLimit=8;
bool ddaAddInterval(vec2 span,inout vec2 intervals[ddaIntervalLimit],inout int n){
    int first=0;while(first<n&&intervals[first].y<span.x)++first;
    int last=first;
    while(last<n&&intervals[last].x<=span.y){span=vec2(min(span.x,intervals[last].x),max(span.y,intervals[last].y));++last;}
    int next=n-(last-first)+1;if(next>ddaIntervalLimit)return false;
    if(last==first){for(int i=n;i>first;--i)intervals[i]=intervals[i-1];}
    else {for(int i=last;i<n;++i)intervals[first+1+i-last]=intervals[i];}
    intervals[first]=span;n=next;return true;
}
float ddaGlassLength(vec3 start,vec3 endpoint,vec3 lo,vec3 hi){
    vec3 d=endpoint-start;float len=length(d);if(len<1e-7)return 0.0;
    bvec3 par=equal(d,vec3(0.0));vec3 inv=1.0/mix(d,vec3(1.0),par);
    if(any(bvec3(par.x&&(start.x<lo.x||start.x>hi.x),par.y&&(start.y<lo.y||start.y>hi.y),par.z&&(start.z<lo.z||start.z>hi.z))))return 0.0;
    vec3 a=(lo-start)*inv,b=(hi-start)*inv;
    a=mix(min(a,b),vec3(-1e20),par); // recompute far separately (a was overwritten)
    vec3 farT=mix(max((lo-start)*inv,(hi-start)*inv),vec3(1e20),par);
    return len*max(0.0,min(1.0,min(farT.x,min(farT.y,farT.z)))-max(0.0,max(a.x,max(a.y,a.z))));
}
// Integrate over the disjoint visibility and transmission events.
// Two-point Gaussian quadrature integrates optical length over each visible
// interval, including overlapping stained-glass layers. Opaque union is exact.
vec3 ddaIntegrateLine(vec2 opaque[ddaIntervalLimit],int no,vec2 glass[ddaIntervalLimit],ivec3 glassCells[ddaIntervalLimit],uint glassModels[ddaIntervalLimit],int ng,vec3 start,vec3 center,vec3 axis){
    if(ng==0){float open=2.0;for(int i=0;i<no;++i)open-=opaque[i].y-opaque[i].x;return vec3(clamp(open*0.5,0.0,1.0));}
    vec3 sum=vec3(0.0);float pos=-1.0;
    for(int step=0;step<4*ddaIntervalLimit+1&&pos<1.0;++step){
        float next=1.0;bool blocked=false;uint glassMask=0u;
        for(int i=0;i<no;++i){vec2 v=opaque[i];if(v.x>pos)next=min(next,v.x);else if(v.y>pos){next=min(next,v.y);blocked=true;}}
        for(int i=0;i<ng;++i){vec2 v=glass[i];if(v.x>pos)next=min(next,v.x);else if(v.y>pos){next=min(next,v.y);glassMask|=1u<<i;}}
        if(!blocked){
            vec3 tr=vec3(1.0);
            if(glassMask!=0u){
                float mid=0.5*(pos+next),width=(next-pos)*0.2886751346;
                vec3 ea=center+axis*(mid-width),eb=center+axis*(mid+width);
                vec3 ta=vec3(1.0),tb=vec3(1.0);
                while(glassMask!=0u){
                    int i=findLSB(glassMask);glassMask&=glassMask-1u;
                    vec3 lo=vec3(glassCells[i]),hi=lo+1.0;
                    vec3 glassFilter=ddaGlassTransmission(glassModels[i]);
                    ta*=pow(glassFilter,vec3(ddaGlassLength(start,ea,lo,hi)));
                    tb*=pow(glassFilter,vec3(ddaGlassLength(start,eb,lo,hi)));
                }
                tr=0.5*(ta+tb);
            }
            sum+=tr*(next-pos);
        }
        pos=next;
    }
    return sum*0.5;
}
bool ddaContinuousLine(vec3 start,ivec3 cell,ivec3 target,vec3 axis,out vec3 result){
    result=vec3(1.0);vec3 center=vec3(target)+0.5,delta=center-start;
    vec3 ad=abs(delta);int major=ad.x>=ad.y&&ad.x>=ad.z?0:(ad.y>=ad.z?1:2);
    int u=(major+1)%3,v=(major+2)%3;
    if(ad[major]<=abs(axis[major])+1e-5)return false;
    int direction=delta[major]>0.0?1:-1;
    vec2 opaque[ddaIntervalLimit],glass[ddaIntervalLimit];ivec3 glassCells[ddaIntervalLimit];uint glassModels[ddaIntervalLimit];int no=0,ng=0;
    ivec3 cachedBrick=ivec3(-1);uvec2 cachedMask=uvec2(0u);
    float minD=ad[major]-abs(axis[major]),maxD=ad[major]+abs(axis[major]);
    // Ratios of linear functions are monotone on this finite source line.
    // Exact extreme slopes at its endpoints tightly enclose every ray.
    vec3 slopeA=(delta-axis)/(ad[major]-float(direction)*axis[major]);
    vec3 slopeB=(delta+axis)/(ad[major]+float(direction)*axis[major]);
    vec3 slopeLo=min(slopeA,slopeB),slopeHi=max(slopeA,slopeB);
    // Sweep the major-axis slabs of the complete finite beam. Other-axis
    // bounds are conservative for every source parameter and ray time.
    for(int k=cell[major];;k+=direction){
        float nearD=direction>0?float(k)-start[major]:start[major]-float(k+1);
        float farD=nearD+1.0;
        float d0=clamp(nearD,0.0,maxD),d1=clamp(farD,0.0,maxD);
        vec3 low=start+min(slopeLo*d0,slopeLo*d1),high=start+max(slopeHi*d0,slopeHi*d1);
        ivec3 il=clamp(ivec3(floor(low-0.0001)),ivec3(0),ddaSize-1),ih=clamp(ivec3(floor(high+0.0001)),ivec3(0),ddaSize-1);
        ivec3 p=ivec3(0);p[major]=k;
        for(int j=il[u];j<=ih[u];++j)for(int l=il[v];l<=ih[v];++l){
            p[u]=j;p[v]=l;if(all(equal(p,target)))continue;
            ivec3 brick=p>>2;
            if(any(notEqual(brick,cachedBrick))){cachedBrick=brick;cachedMask=texelFetch(ddaMaskSampler,brick,0).ba;}
            if((cachedMask.x|cachedMask.y)==0u)continue;
            uint model=ddaModelPacked(p,cachedMask);if(model==0u)continue;
            vec3 base=vec3(p),upper=base+1.0;vec2 span;
            // Adjacent opaque cells along this slab row form one exact AABB.
            // Restrict merging to this brick so the mask stays valid.
            if(model==1u){
                int end=min(ih[v],l|(3));
                while(l<end){ivec3 next=p;next[v]=l+1;
                    if(all(equal(next,target))||ddaModelPacked(next,cachedMask)!=1u)break;
                    ++l;upper[v]+=1.0;
                }
            }
            if(!ddaProjectedInterval(start,delta,axis,base,upper,span))continue;
            if(model>=1024u){
                if(ng==ddaIntervalLimit)return false;
                glass[ng]=span;glassCells[ng]=p;glassModels[ng++]=model;
            }else if(model==1u){if(!ddaAddInterval(span,opaque,no))return false;}
            else{
                if(model==288u)return false; // alpha lattice: use finite rays
                int count=int(texelFetch(ddaShapeSampler,ivec3(0,int(model),0),0).w);
                for(int i=0;i<count;++i){
                    vec3 blo=base+texelFetch(ddaShapeSampler,ivec3(2+i*2,int(model),0),0).xyz*0.0625;
                    vec3 bhi=base+texelFetch(ddaShapeSampler,ivec3(3+i*2,int(model),0),0).xyz*0.0625;
                    if(ddaProjectedInterval(start,delta,axis,blo,bhi,span)&&!ddaAddInterval(span,opaque,no))return false;
                }
            }
            if(no==1&&opaque[0].x<=-1.0&&opaque[0].y>=1.0){result=vec3(0.0);return true;}
        }
        if(k==target[major])break;
    }
    result=ddaIntegrateLine(opaque,no,glass,glassCells,glassModels,ng,start,center,axis);return true;
}
#if DDA_CONTINUOUS_LINES == 3
#include "/lib/vx/ddaArea.glsl"
#endif
#if DDA_CONTINUOUS_LINES == 4
// When an axis-aligned blocker edge projects through the center of the
// emitter, its projection plane normal is cross(rayDirection, edgeAxis).
// A source line parallel to that plane has nearly zero projected width.
// Fade that line's weight BEFORE evaluating geometry. The weights depend
// only on the receiver and emitter, preserving monotonic blocker unions.
float ddaLineWeight(vec3 direction,vec3 axis){
    vec3 x=vec3(0.0,direction.z,-direction.y);
    vec3 y=vec3(-direction.z,0.0,direction.x);
    vec3 z=vec3(direction.y,-direction.x,0.0);
    vec3 norms=vec3(length(x),length(y),length(z));
    vec3 alignment=abs(vec3(dot(x,axis),dot(y,axis),dot(z,axis)))/max(norms,vec3(1e-6));
    vec3 safe=mix(vec3(1.0),smoothstep(vec3(0.015),vec3(0.36),alignment),smoothstep(vec3(0.005),vec3(0.08),norms));
    return min(safe.x,min(safe.y,safe.z));
}
#endif
bool ddaContinuousTransmission(vec3 start,ivec3 cell,ivec3 target,out vec3 result){
    if(all(equal(cell,target))){result=vec3(1.0);return true;}
    #if DDA_CONTINUOUS_LINES == 3
    uint areaMaterial=texelFetch(voxelSampler,target,0).r;
    // Lava and portals keep the inexpensive line path. If a lamp has
    // adjacent stained glass, use colored line integration consistently
    // from all viewing directions; do not switch by receiver orientation.
    if(areaMaterial!=11u && areaMaterial!=30u){
        bool adjacentGlass=false;
        for(int j=0;j<3&&!adjacentGlass;++j)for(int d=-1;d<=1;d+=2){
            ivec3 neighbor=target;neighbor[j]+=d;
            uint nc=ddaValid(neighbor)?texelFetch(voxelSampler,neighbor,0).r:0u;
            if(nc>=200u&&nc<=215u){adjacentGlass=true;break;}
        }
        if(!adjacentGlass&&ddaDiskTransmission(start,cell,target,result))return true;
    }
    #endif
    #if DDA_CONTINUOUS_LINES == 4
    uint mat=texelFetch(voxelSampler,target,0).r;
    bool cheap=mat==11u||mat==30u;

    const vec3 axes[3]=vec3[](vec3(1.0,0.71,-0.83),vec3(0.63,-1.0,0.91),vec3(0.73,0.86,1.0));
    vec3 weights=vec3(1.0,0.0,0.0);
    if(!cheap){
        vec3 direction=normalize(vec3(target)+0.5-start);
        weights=vec3(ddaLineWeight(direction,axes[0]),ddaLineWeight(direction,axes[1]),ddaLineWeight(direction,axes[2]));
        weights.z*=1.0-smoothstep(0.30,0.85,weights.x+weights.y);
        float total=weights.x+weights.y+weights.z;
        if(total<1e-5)weights=vec3(1.0/3.0);else weights/=total;
    }
    vec3 sum=vec3(0.0);
    for(int j=0;j<3;++j){
        if(weights[j]<=0.0)continue;
        vec3 value;
        if(!ddaContinuousLine(start,cell,target,(cheap?vec3(1.0):axes[j])*DDA_SOFT_RADIUS,value))return false;
        sum+=value*weights[j];
    }
    result=sum;return true;
    #else
    vec3 a,b;
    if(!ddaContinuousLine(start,cell,target,vec3(1.0,1.0,1.0)*DDA_SOFT_RADIUS,a))return false;
    #if DDA_CONTINUOUS_LINES == 0
    result=a;return true;
    #elif DDA_CONTINUOUS_LINES == 1 || DDA_CONTINUOUS_LINES >= 3
    // Liquid/portal sheets use one source line, other block emitters two.
    // Do not select the method by receiver-cache occupancy: that would
    // change the same light's shadow when a regional list is refreshed.
    uint material=texelFetch(voxelSampler,target,0).r;
    if(material==11u || material==30u){result=a;return true;}
    #endif
    if(!ddaContinuousLine(start,cell,target,vec3(1.0,-1.0,1.0)*DDA_SOFT_RADIUS,b))return false;
    result=0.5*(a+b);return true;
    #endif
}
